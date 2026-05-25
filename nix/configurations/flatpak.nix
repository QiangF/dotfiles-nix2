{ self, pkgs, ... }:

{
  imports = [
    self.inputs.nix-flatpak.nixosModules.nix-flatpak
  ];

  # Tiny wrappers so flatpak apps can be launched by their familiar names
  # (also lets `which stremio` and `.desktop` files referencing `stremio`
  # find a real binary in PATH).
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "stremio" ''
      exec ${pkgs.flatpak}/bin/flatpak run com.stremio.Stremio "$@"
    '')
  ];

  services.flatpak = {
    enable = true;

    # Keep installed flatpaks in sync with this list on every rebuild.
    # Anything installed imperatively that isn't listed here will be removed.
    uninstallUnmanaged = true;

    update.auto = {
      enable = true;
      onCalendar = "weekly";
    };

    remotes = [{
      name = "flathub";
      location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
    }];

    packages = [
      # Stremio: shipped as a flatpak so we don't have to build qtwebengine5
      # locally (which used to take hours).
      { appId = "com.stremio.Stremio"; origin = "flathub"; }
    ];
  };
}
