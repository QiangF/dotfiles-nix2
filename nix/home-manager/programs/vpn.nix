{ config, lib, inputs, system, pkgs, ... }:

# GlobalProtect VPN client, CLI-only.
#
# Provides the `gpclient` CLI (plus its `gpservice` daemon and `gpauth`
# helper). The package comes from the `gp-openconnect` flake input
# (a personal fork of yuezk/GlobalProtect-openconnect) — see
# configurations/overlays.nix and the fork's package.nix.
#
# Use from a terminal: `gpclient connect <portal>` (auth pops a browser
# window for SAML; that's intrinsic to the protocol, not a GUI client).

{
  home.packages = [
    pkgs.globalprotect-openconnect
  ];
}
