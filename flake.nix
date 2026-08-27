{
  description = "shen-julia development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { nixpkgs, ... }: let systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]; each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system}); in {
    packages = each (pkgs: { toolchain = pkgs.buildEnv { name = "shen-julia-toolchain"; paths = [ pkgs.julia ]; }; default = pkgs.buildEnv { name = "shen-julia-toolchain"; paths = [ pkgs.julia ]; }; });
    devShells = each (pkgs: { default = pkgs.mkShell { packages = [ pkgs.julia ]; }; });
  };
}
