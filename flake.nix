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
          filteredSource =
            pkgs.lib.cleanSourceWith {
              src = ./.;
              filter =
                path: type:
                let
                  pathStr = toString path;
                  rootStr = toString ./.;
                  rel =
                    if pathStr == rootStr then
                      "."
                    else
                      pkgs.lib.removePrefix "${rootStr}/" pathStr;
                  top =
                    if rel == "." then
                      "."
                    else
                      builtins.head (pkgs.lib.splitString "/" rel);
                  generatedTopLevel =
                    pkgs.lib.hasPrefix ".clasp-" top
                    || top == "target"
                    || top == "dist"
                    || top == "result";
                  generatedRuntimePath =
                    rel == "runtime/target"
                    || pkgs.lib.hasPrefix "runtime/target/" rel;
                  generatedRootArtifact = rel == "libclasp_runtime.a";
                in
                pkgs.lib.cleanSourceFilter path type
                && !generatedTopLevel
                && !generatedRuntimePath
                && !generatedRootArtifact;
            };
          claspc = pkgs.rustPlatform.buildRustPackage {
            pname = "claspc";
            version = "0.1.0";
            src = filteredSource;
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
