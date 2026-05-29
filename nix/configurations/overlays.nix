{ pkgs, lib, self, system, ... }:

let
  inherit (self) inputs;
in {
  nixpkgs.overlays = [
    inputs.emacs.overlay

    (final: prev:
      let
        cfg = {
          allowUnfree = true;
        };
      in {
      stable = import inputs.stable {
        inherit system;
        config = cfg;
      };

      master = import inputs.master {
        inherit system;
        config = cfg;
      };

      nubank = import inputs.nubank {
        inherit system;
        config = cfg;
      };
    })

    # GlobalProtect CLI lives in a separate fork-flake. Its overlay
    # exposes `pkgs.globalprotect-openconnect` (gpclient + gpservice +
    # gpauth, CLI build, no Tauri GUI). See
    # /home/greg/dev/GlobalProtect-openconnect/{flake,package}.nix.
    inputs.gp-openconnect.overlays.default
  ];
}
