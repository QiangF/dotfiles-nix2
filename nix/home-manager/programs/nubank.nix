{ config, lib, pkgs, ... }:

{
  imports = [
    ./vpn.nix
  ];

  home.packages = with pkgs; [
    aws-iam-authenticator
    databricks-cli
    kubelogin-oidc
    stable.kubectl
    zoom-us
    plantuml
    tektoncd-cli
    stable.yubikey-manager
    # yubikey-personalization-gui was archived upstream and removed from nixpkgs
    # (2025-06-07). yubikey-manager (above) handles the same workflows for
    # YubiKey 5 and later. Add `yubioath-flutter` here if a GUI OATH client is
    # needed.
    scala
    scalafmt
    teleport
    mob
    stable.protobuf
    stable.buf
    # (nubank.flutter.override { flutterPackages = stable.flutterPackages; })
  ];
}
