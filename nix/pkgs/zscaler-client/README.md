# zscaler-client

Nix packaging of the closed-source **Zscaler Client Connector (ZCC)** for Linux.

The proprietary payload is **never committed** — only its `sha256` lives in
`default.nix`. You supply the file locally and register it in the Nix store
with `requireFile`, so the build stays pure (no `--impure`, no env vars).

## 1. Obtain the installer

Download the `Zscaler-linux-<version>-installer.run` from your organization's
Zscaler Client Connector portal (App Store → Linux). This module pins
`3.7.1.71`; bump `version` + the hashes in `default.nix` for other releases.

## 2. Extract the payload to a tarball

The `.run` is a BitRock InstallBuilder self-extractor that hardcodes
`/opt/zscaler` and only needs glibc. Extract it without touching the host by
running it under `bwrap` with the system paths redirected to tmpfs, using
`--prefix` to capture the program files:

```bash
RUN=/path/to/Zscaler-linux-3.7.1.71-installer.run
WORK=$(mktemp -d)
cp "$RUN" "$WORK/installer.run"; chmod +x "$WORK/installer.run"
GLIBC=$(nix eval --raw nixpkgs#glibc); SW=/run/current-system/sw

nix shell nixpkgs#bubblewrap -c bwrap \
  --ro-bind /nix /nix --ro-bind "$SW" "$SW" \
  --ro-bind "$SW/bin" /bin --ro-bind "$SW/bin" /usr/bin \
  --ro-bind "$GLIBC/lib/ld-linux-x86-64.so.2" /lib64/ld-linux-x86-64.so.2 \
  --ro-bind /etc/passwd /etc/passwd --ro-bind /etc/group /etc/group \
  --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --bind "$WORK" /work --proc /proc --dev /dev --tmpfs /tmp \
  --tmpfs /opt --tmpfs /usr/share --dir /usr/share/applications \
  --setenv TMPDIR /work/tmp --setenv HOME /work/home --setenv PATH "$SW/bin" \
  --setenv LD_LIBRARY_PATH "$GLIBC/lib" \
  bash -c 'mkdir -p /work/{out,tmp,home}; \
    /work/installer.run --mode unattended --unattendedmodeui none \
      --prefix /work/out --debuglevel 4 --wait false || true'

# Stage only the immutable client payload and make a deterministic tarball.
STAGE=$(mktemp -d); mkdir -p "$STAGE/opt/zscaler"
cp -a "$WORK"/out/{bin,lib,Images,scripts,secure,licenses,.config.ini} "$STAGE/opt/zscaler/"
tar --numeric-owner --owner=0 --group=0 --mtime='2025-02-07 00:00:00 UTC' --sort=name \
    -C "$STAGE" -czf zscaler-client-3.7.1.71.tar.gz opt
```

> The post-install step failing on `/etc/ld.so.conf` is expected and harmless —
> all client files are copied before it. `ZSTray` (the Qt login GUI) is *not*
> in the installer; `zsaservice` fetches it at runtime into `/opt/zscaler`.

## 3. Register it locally

```bash
sha256sum zscaler-client-3.7.1.71.tar.gz   # must match `sha256` in default.nix
nix-store --add-fixed sha256 zscaler-client-3.7.1.71.tar.gz
```

Now `nixos-rebuild` can build the package. Keep the tarball somewhere stable
(e.g. `~/.local/share/`) in case you need to re-register it on a fresh machine.
