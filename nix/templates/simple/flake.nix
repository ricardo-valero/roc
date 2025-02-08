{
  description = "Roc flake template";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    roc.url = "github:roc-lang/roc";
  };

  outputs = { nixpkgs, roc }:
    let
      systems = nixpkgs.lib.platforms.all;
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in {
      formatter = forEachSystem (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.nixpkgs-fmt);
      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # see "packages =" in https://github.com/roc-lang/roc/blob/main/flake.nix
          rocPkgs = roc.packages.${system};
          rocFull = rocPkgs.full;
        in {
          default = pkgs.mkShell {
            buildInputs = [
              rocFull # includes CLI
            ];

            # For vscode plugin https://github.com/ivan-demchenko/roc-vscode-unofficial
            shellHook = ''
              export ROC_LANGUAGE_SERVER_PATH=${rocFull}/bin/roc_language_server
            '';
          };
        });
    };
}
