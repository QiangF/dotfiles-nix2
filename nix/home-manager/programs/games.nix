{ config, lib, pkgs, ... }:

{
  home.packages = with pkgs; [
    # dolphin-emu-beta
    aseprite
    # lutris  # 2026-05-29: temporarily disabled — pulls in openldap whose
    #         # `test017-syncreplication-refresh` fails on current nixpkgs rev
    #         # and isn't on cache.nixos.org. Re-enable after nixpkgs bump.
    steam
    # wineWowPackages.staging
    master.godot
    audacity
    steam-run
    cemu
    winetricks
    gamemode
  ];
}
