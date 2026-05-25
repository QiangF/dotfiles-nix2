{ self, ... }:

{
  imports = [
    self.inputs.nix-flatpak.nixosModules.nix-flatpak
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
      "flathub:app/com.stremio.Stremio/x86_64/stable"
    ];
  };
}
