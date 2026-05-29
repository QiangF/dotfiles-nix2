{ config, lib, pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    vimAlias = true;
    # HM master (2026-05) requires the structured form here — passing
    # bare derivations triggers a `plugins.<entry>.runtime' does not exist`
    # error against nixpkgs's neovim plugin-submodule. Wrap each in
    # `{ plugin = ...; }`.
    plugins = with pkgs.vimPlugins; [
      { plugin = packer-nvim; }
      { plugin = vim-nix; }
    ];
  };
}
