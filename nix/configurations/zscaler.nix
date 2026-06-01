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
    # Patched daemons (rpath points into the store).
    for b in zsaservice zstunnel zsupdater; do
      install -m 0755 ${zscaler}/opt/zscaler/bin/$b ${opt}/bin/$b
    done
  '';

  # ZSTray is a Qt5/QtWebEngine app fetched at runtime; run it inside an FHS
  # sandbox so the dynamically-linked binary finds Qt + X/Wayland libs.
  zstrayFHS = pkgs.buildFHSEnv {
    name = "zscaler-zstray";
    runScript = "${opt}/bin/ZSTray";
    targetPkgs = p: (with p; [
      # Qt 5 base set. NOTE: qtwebengine5 was dropped from nixpkgs (EOL). Igor
      # reported ZSTray needs LibQt5WebEngineWidgets; if this version does too,
      # we'll pull qtwebengine from the `stable` pin once we have the real
      # runtime-fetched ZSTray binary to inspect (handled during login testing).
      qt5.qtbase qt5.qtsvg qt5.qtdeclarative qt5.qtwayland
      # Chromium/Qt runtime deps
      glib dbus nss nspr fontconfig freetype expat libGL libdrm
      alsa-lib libpulseaudio cups pango cairo gdk-pixbuf gtk3
      at-spi2-core libxkbcommon
    ]) ++ (with p; [
      libx11 libxcb libxcomposite libxdamage libxext libxfixes libxrandr
      libxrender libxtst libxi libxcursor libxscrnsaver libxshmfence
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
