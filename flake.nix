{
  description = "Clasp compiler and language workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            pkgs = import nixpkgs { inherit system; };
          });
    in
    {
      packages = forAllSystems ({ pkgs }: {
        default = pkgs.haskellPackages.callCabal2nix "clasp-compiler" ./. { };
      });

      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            cabal-install
            cargo
            git
            haskellPackages.ghc
            nodejs_22
            python3
            rustc
          ];
        };
      });

      formatter = forAllSystems ({ pkgs }: pkgs.nixfmt-rfc-style);
    };
}
