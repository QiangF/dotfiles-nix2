{ lib
, stdenv
, requireFile
, autoPatchelfHook
, fetchurl
, pkg-config
, libgpg-error
, libassuan
, dbus
, dbus-glib
, glib
, libpcap
}:

# Zscaler Client Connector (ZCC) for Linux — ZTNA client.
#
# Fully closed-source. Upstream ships a BitRock InstallBuilder `.run` that
# hardcodes an FHS install to /opt/zscaler and is only available from your
# organization's Zscaler portal (not publicly fetchable). Rather than run that
# installer at build time (it needs writable system paths + namespaces that
# fight the Nix sandbox), we consume a *pre-extracted* payload tarball supplied
# locally via `requireFile`, and patchelf the binaries onto the Nix store.
#
# The proprietary payload is NEVER committed: only its hash lives here; the
# file itself stays on the machine (added with `nix-store --add-fixed`). See
# ./README.md for how to produce the tarball from your `.run` installer.
#
# The three ELF daemons (`zsaservice`, `zstunnel`, `zsupdater`) plus the
# bundled `libpacparser.so` are patched here. The `ZSTray` GUI is NOT shipped
# in the installer — `zsaservice` fetches it from the Zscaler cloud at runtime
# into a *mutable* /opt/zscaler, which the NixOS module provisions.

let
  version = "3.7.1.71";

  # The daemons NEED the old gpgme soname (libgpgme.so.11); nixpkgs has moved
  # to gpgme 2.0 (libgpgme.so.45), a real ABI break — so we build the last
  # 1.x release from source. It compiles cleanly against current libassuan /
  # libgpg-error and yields libgpgme.so.11.
  gpgme11 = stdenv.mkDerivation rec {
    pname = "gpgme";
    version = "1.24.2";
    src = fetchurl {
      url = "mirror://gnupg/gpgme/gpgme-${version}.tar.bz2";
      sha256 = "10cmcc3cw7gygh0vg11xqq4byakf164kv828bzjyjxqp6q71l6z1";
    };
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ libgpg-error libassuan ];
    configureFlags = [ "--enable-languages=cpp" "--disable-gpg-test" ];
    doCheck = false;
  };

  # The daemons link against the old libpcap soname (libpcap.so.0.8); nixpkgs
  # ships libpcap.so.1, which is ABI-compatible for the calls ZCC uses.
  libpcapCompat = stdenv.mkDerivation {
    pname = "libpcap-compat-0_8";
    inherit version;
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/lib"
      ln -s ${lib.getLib libpcap}/lib/libpcap.so.1 "$out/lib/libpcap.so.0.8"
    '';
  };
in
stdenv.mkDerivation {
  pname = "zscaler-client";
  inherit version;

  src = requireFile {
    name = "zscaler-client-${version}.tar.gz";
    sha256 = "cb3a5a81c2d652d6c7b21b5b28aff2caf0338c2ef1ba97e45f6d17cad3182dd4";
    message = ''
      The proprietary Zscaler Client Connector payload is required but cannot
      be fetched automatically (obtain the `.run` from your org's Zscaler
      portal). Produce the pre-extracted tarball as described in
      nix/pkgs/zscaler-client/README.md, then register it locally:

        nix-store --add-fixed sha256 zscaler-client-${version}.tar.gz
    '';
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  # Shared-lib deps discovered via `patchelf --print-needed` on the daemons:
  #   stdc++/gcc_s (stdenv.cc.cc.lib), gpgme (so.11), dbus, dbus-glib,
  #   glib/gio/gobject, libpcap (zstunnel only). glibc comes from stdenv.
  buildInputs = [
    stdenv.cc.cc.lib
    gpgme11
    dbus
    dbus-glib
    glib
    libpcap
    libpcapCompat
  ];

  # The bundled libpacparser.so (a NEEDED of every daemon) lives in the payload
  # itself; make autoPatchelf look there so the daemons resolve it.
  appendRunpaths = [ "${placeholder "out"}/opt/zscaler/lib" ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack
    tar xzf "$src"
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a opt "$out/opt"
    chmod -R u+w "$out/opt/zscaler"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Zscaler Client Connector (ZTNA) for Linux";
    homepage = "https://www.zscaler.com/products-and-solutions/zscaler-client-connector";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
