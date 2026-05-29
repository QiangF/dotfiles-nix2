{
  description = "My NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    master.url = "github:NixOS/nixpkgs/master";
    hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    emacs = {
      url = "github:nix-community/emacs-overlay/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nubank is itself a nixpkgs fork and has no own inputs — `follows`
    # would be a no-op. Same for nix-flatpak.
    nubank.url = "github:nubank/nixpkgs/master";
    nix-flatpak.url = "github:gmodena/nix-flatpak";

    # GlobalProtect VPN client (CLI build of yuezk/GlobalProtect-openconnect).
    # Lives in a personal fork so the package recipe / flake plumbing can
    # be maintained outside this config and eventually PR'd upstream.
    # Using `path:` for local-checkout development — switch to
    # `github:ericdallo/GlobalProtect-openconnect/<branch>` once committed.
    gp-openconnect = {
      url = "path:/home/greg/dev/GlobalProtect-openconnect";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations.greg = home-manager.lib.homeManagerConfiguration {
        modules = [ ./hosts/asus-zenbook-oled/ubuntu.nix ];

        inherit pkgs;
        extraSpecialArgs = { inherit self system; };
      };

      nixosConfigurations =
      let
        mkSystem = { modules, system ? "x86_64-linux" }:
          nixpkgs.lib.nixosSystem {
            inherit system modules;
            specialArgs = { inherit self system; };
          };
      in
      {
        gregnix-personal = mkSystem { modules = [ ./hosts/asus-zenbook-oled ]; };
      };
  };
}
