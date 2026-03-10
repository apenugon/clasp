{
  description = "Weft compiler and language workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            pkgs = import nixpkgs { inherit system; };
          });
    in
    {
      packages = forAllSystems ({ pkgs }: {
        default = pkgs.haskellPackages.callCabal2nix "weft-compiler" ./. { };
      });

      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            cabal-install
            haskellPackages.ghc
            nodejs_22
          ];
        };
      });

      formatter = forAllSystems ({ pkgs }: pkgs.nixfmt-rfc-style);
    };
}
