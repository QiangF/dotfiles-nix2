{ config, lib, pkgs, ... }:

# Zscaler Client Connector (ZTNA) — NixOS module.
#
# Provides a gpclient-style on-demand toggle: services are installed but NOT
# started at boot; `zscaler up` connects, `zscaler down` disconnects and
# restores DNS. Only the proprietary payload stays local (see pkgs/zscaler-
# client, supplied via requireFile); everything here is generic and versioned.
#
# Architecture (see pkgs/zscaler-client for the binary details):
#   * zsaservice  — root daemon, supervises the tunnel + tray, fetches ZSTray
#   * zstunnel    — root daemon, the actual ZTNA tunnel
#   * ZSTray      — per-user Qt GUI for Okta login (fetched at runtime by
#                   zsaservice into the mutable /opt/zscaler/bin)
#   * /opt/zscaler is mutable state, seeded from the Nix package on each start.

let
  zscaler = pkgs.zscaler-client;

  opt = "/opt/zscaler";

  # Runtime tools the daemons shell out to (DNS/route/NetworkManager glue).
  daemonPath = with pkgs; [
    networkmanager iproute2 iptables systemd procps
    gnugrep gnused gawk coreutils util-linux
  ];

  # The daemons also invoke some tools by *absolute* FHS path (e.g.
  # `/usr/bin/awk` for /etc/os-release parsing), which PATH can't satisfy on
  # NixOS. Bundle the tools and bind them over /usr/bin, /sbin, /usr/sbin in
  # each daemon's private mount namespace (contained — no host-wide change).
  fhsTools = pkgs.buildEnv {
    name = "zscaler-fhs-tools";
    paths = daemonPath ++ (with pkgs; [ bash ]);
  };
  fhsBinds = [
    "${fhsTools}/bin:/usr/bin"
    "${fhsTools}/bin:/sbin"
    "${fhsTools}/bin:/usr/sbin"
  ];

  # ── D-Bus system-bus policy ───────────────────────────────────────────────
  # The Zscaler components rendezvous over the *system* bus: zsaservice,
  # zstunnel and ZSTray each *own* a well-known name (com.zscaler.{zsaservice,
  # ztunnel,ztray}.service) and call one another over it. dbus refuses name
  # ownership unless a policy explicitly grants it, so without these files
  # zsaservice can never own com.zscaler.zsaservice.service — and ZSTray then
  # aborts on launch (SIGABRT) the moment it calls the service:
  #   GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: ... not activatable
  # These are the vendor's own policy files from the .deb (generic XML, no
  # secrets); shipped under share/dbus-1/system.d for services.dbus.packages.
  dbusPolicy = pkgs.runCommandLocal "zscaler-dbus-policy" { } ''
    d="$out/share/dbus-1/system.d"
    install -d "$d"
    install -m0644 ${pkgs.writeText "com.zscaler.zsaservice.service.conf" ''
      <!DOCTYPE busconfig PUBLIC
       "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
       "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy user="root">
          <allow own="com.zscaler.zsaservice.service"/>
          <allow send_destination="com.zscaler.zsaservice.service"/>
        </policy>
        <policy context="default">
          <allow send_interface="com.zscaler.zsaservice.Interface" send_destination="com.zscaler.zsaservice.service"/>
        </policy>
      </busconfig>
    ''} "$d/com.zscaler.zsaservice.service.conf"
    install -m0644 ${pkgs.writeText "com.zscaler.ztray.service.conf" ''
      <!DOCTYPE busconfig PUBLIC
       "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
       "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy context="default">
          <allow send_interface="com.zscaler.ztray.Interface" send_destination="com.zscaler.ztray.service"/>
          <allow own="com.zscaler.ztray.service"/>
          <allow user="*"/>
        </policy>
      </busconfig>
    ''} "$d/com.zscaler.ztray.service.conf"
    install -m0644 ${pkgs.writeText "com.zscaler.ztunnel.service.conf" ''
      <!DOCTYPE busconfig PUBLIC
       "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
       "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy user="root">
          <allow own="com.zscaler.ztunnel.service"/>
          <allow send_destination="com.zscaler.ztunnel.service"/>
        </policy>
        <policy context="default">
          <allow send_interface="com.zscaler.ztunnel.Interface" send_destination="com.zscaler.ztunnel.service"/>
        </policy>
      </busconfig>
    ''} "$d/com.zscaler.ztunnel.service.conf"
  '';

  # Seed the mutable /opt/zscaler from the immutable store package. Idempotent.
  # Keeps bin/ writable and preserves the runtime-fetched ZSTray + session.
  provision = pkgs.writeShellScript "zscaler-provision" ''
    set -eu
    install -d -m 0755 ${opt} ${opt}/bin ${opt}/.config /var/log/zscaler
    # Immutable assets — refresh from the store every start.
    for d in Images scripts lib licenses secure; do
      rm -rf ${opt}/$d
      cp -a ${zscaler}/opt/zscaler/$d ${opt}/$d
      chmod -R u+w ${opt}/$d
    done
    install -m 0644 ${zscaler}/opt/zscaler/.config.ini ${opt}/.config.ini
    # Patched daemons (rpath points into the store) + the raw ZSTray GUI
    # binary (run via the FHS sandbox, so it stays unpatched).
    for b in zsaservice zstunnel zsupdater ZSTray; do
      install -m 0755 ${zscaler}/opt/zscaler/bin/$b ${opt}/bin/$b
    done
  '';

  # ZSTray is a Qt5 + QtWebEngine app (libQt5WebEngine{Widgets,Core}.so.5,
  # libgpgme.so.11). qtwebengine5 was dropped from current nixpkgs and gpgme
  # moved to so.45 — but the `stable` (25.11) pin still has qtwebengine 5.15.x
  # and gpgme 1.24 (so.11). So build the whole FHS sandbox from `stable` for a
  # consistent Qt5 userland. LD_LIBRARY_PATH points at the bundled libpacparser.
  zstrayFHS = pkgs.stable.buildFHSEnv {
    name = "zscaler-zstray";
    runScript = pkgs.writeShellScript "zstray-run" ''
      export LD_LIBRARY_PATH="${opt}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      # ZSTray bundles OpenSSL 1.0.2 with a compiled-in OPENSSLDIR of
      # /usr/local/ssl (absent on NixOS). Point the standard SSL envs at
      # NixOS' CA bundle so TLS has a trust store regardless of that path.
      export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      export SSL_CERT_DIR=/etc/ssl/certs
      export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
      exec ${opt}/bin/ZSTray "$@"
    '';
    # Recreate the binary's compiled-in /usr/local/ssl tree, pointing at the
    # host CA bundle (resolved inside the sandbox via the /etc/ssl/certs bind).
    # NB: extraBuildCommands runs in the build tmpdir, so target $out/... .
    extraBuildCommands = ''
      mkdir -p "$out/usr/local/ssl"
      ln -s /etc/ssl/certs                     "$out/usr/local/ssl/certs"
      ln -s /etc/ssl/certs/ca-certificates.crt "$out/usr/local/ssl/cert.pem"
      printf '[ default ]\n' > "$out/usr/local/ssl/openssl.cnf"
    '';
    targetPkgs = p: (with p; [
      qt5.qtbase qt5.qtsvg qt5.qtdeclarative qt5.qtwayland
      qt5.qtwebengine qt5.qtwebchannel
      gpgme              # libgpgme.so.11
      openssl            # libssl.so.3 / libcrypto.so.3 for Qt5 Network TLS
      glib dbus dbus-glib nss nspr fontconfig freetype expat libGL libdrm
      alsa-lib libpulseaudio cups pango cairo gdk-pixbuf gtk3
      at-spi2-core libxkbcommon
    ]) ++ (with p.xorg; [
      libX11 libxcb libXcomposite libXdamage libXext libXfixes libXrandr
      libXrender libXtst libXi libXcursor libXScrnSaver libxshmfence
    ]);
  };

  # gpclient-style control. System units need root; greg has passwordless sudo.
  zscalerCtl = pkgs.writeShellApplication {
    name = "zscaler";
    runtimeInputs = with pkgs; [ systemd ];
    text = ''
      units=(zsaservice.service zstunnel.service)

      _up() {
        sudo systemctl start zscaler-provision.service
        sudo systemctl start "''${units[@]}"
        # bring the tray up for Okta login under the graphical session
        systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR 2>/dev/null || true
        systemctl --user start zscaler-tray.service 2>/dev/null || true
        echo "Zscaler: connecting — finish the Okta login in the tray window."
      }

      _down() {
        systemctl --user stop zscaler-tray.service 2>/dev/null || true
        sudo systemctl stop "''${units[@]}" || true
        sudo systemctl reset-failed "''${units[@]}" 2>/dev/null || true
        # Restore default (no-VPN) DNS: drop Zscaler's resolver overrides.
        sudo systemctl restart systemd-resolved.service || true
        sudo resolvectl flush-caches 2>/dev/null || true
        echo "Zscaler: disconnected — DNS restored to default."
      }

      case "''${1:-status}" in
        up) _up ;;
        down) _down ;;
        toggle) if systemctl is-active --quiet zsaservice.service; then _down; else _up; fi ;;
        status)
          if systemctl is-active --quiet zsaservice.service; then
            echo "Zscaler: UP"; resolvectl status 2>/dev/null | sed -n '1,12p' || true
          else echo "Zscaler: DOWN"; fi ;;
        json) # for waybar custom module
          if systemctl is-active --quiet zsaservice.service; then
            echo '{"class":"on","tooltip":"Zscaler connected"}'
          else echo '{"class":"off","tooltip":"Zscaler disconnected"}'; fi ;;
        *) echo "usage: zscaler {up|down|toggle|status|json}" >&2; exit 1 ;;
      esac
    '';
  };
in
{
  ##: DNS — Zscaler hard-requires systemd-resolved (its docs are explicit).
  ## Switching NetworkManager off dnsmasq onto resolved is the one change to
  ## normal networking; it is the *default* (no-VPN) state and fully reversible.
  services.resolved.enable = true;
  networking.networkmanager.dns = lib.mkForce "systemd-resolved";

  ##: D-Bus — install the vendor system-bus policy so the components may own
  ## their well-known names. Without it ZSTray aborts on launch (see dbusPolicy).
  services.dbus.packages = [ dbusPolicy ];

  ##: Provision the mutable /opt/zscaler before the daemons.
  systemd.services.zscaler-provision = {
    description = "Provision /opt/zscaler from the Nix store";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = provision;
    };
  };

  ##: Core daemons — installed but on-demand (NOT wantedBy any target).
  systemd.services.zsaservice = {
    description = "Zscaler Service (monitors tunnel and tray)";
    after = [ "zscaler-provision.service" "network-online.target" "NetworkManager.service" "systemd-resolved.service" "dbus.service" ];
    wants = [ "network-online.target" ];
    requires = [ "zscaler-provision.service" ];
    path = daemonPath;
    serviceConfig = {
      ExecStart = "${opt}/bin/zsaservice";
      Type = "simple";
      KillMode = "process";
      Restart = "always";
      RestartSec = "2s";
      BindReadOnlyPaths = fhsBinds;
    };
  };

  systemd.services.zstunnel = {
    description = "Zscaler ZCC Tunnel";
    after = [ "zscaler-provision.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "zscaler-provision.service" ];
    path = daemonPath;
    serviceConfig = {
      ExecStart = "${opt}/bin/zstunnel";
      Type = "simple";
      KillMode = "mixed";
      BindReadOnlyPaths = fhsBinds;
    };
  };

  ##: ZSTray — per-user Qt login GUI, on-demand, run via the FHS wrapper.
  systemd.user.services.zscaler-tray = {
    description = "Zscaler Client Connector Tray (Okta login)";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${zstrayFHS}/bin/zscaler-zstray";
      Restart = "on-abnormal";
      RestartPreventExitStatus = "SIGABRT";
    };
  };

  ##: CLI toggle + the FHS-wrapped tray binary on PATH.
  environment.systemPackages = [ zscalerCtl zstrayFHS ];
}
