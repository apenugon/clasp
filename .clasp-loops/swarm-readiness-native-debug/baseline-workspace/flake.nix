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
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          });
    in
    {
      packages = forAllSystems ({ pkgs, system }:
        let
          claspc = pkgs.rustPlatform.buildRustPackage {
            pname = "claspc";
            version = "0.1.0";
            src = ./.;
            cargoRoot = "runtime";
            buildAndTestSubdir = "runtime";
            cargoLock = {
              lockFile = ./runtime/Cargo.lock;
            };
            cargoBuildFlags = [
              "--bin"
              "claspc"
            ];
          };
        in
        {
          default = claspc;
          claspc = claspc;
        });

      apps = forAllSystems ({ pkgs, system }: {
        default = {
          type = "app";
          program = "${self.packages.${system}.claspc}/bin/claspc";
        };
        claspc = {
          type = "app";
          program = "${self.packages.${system}.claspc}/bin/claspc";
        };
      });

      devShells = forAllSystems ({ pkgs, system }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            cargo
            git
            nodejs_22
            python3
            rustc
          ] ++ [
            self.packages.${system}.claspc
          ];
        };
      });

      formatter = forAllSystems ({ pkgs }: pkgs.nixfmt-rfc-style);
    };
}
