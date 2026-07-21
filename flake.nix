{
  description = "Modern filesystem benchmark runner";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
      benchmarkFor = system:
        import ./nix/benchmark-package.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          source = self;
        };
    in
    {
      packages = forEachSystem (system: {
        default = (benchmarkFor system).package;
        benchmark = (benchmarkFor system).package;
      });

      apps = forEachSystem (system: {
        default = self.apps.${system}.manual;
        manual = {
          type = "app";
          program = "${self.packages.${system}.benchmark}/bin/modern-fs-benchmark";
        };
      });

      nixosModules.default = import ./nix/module.nix { source = self; };
      nixosModules.modern-fs-benchmark = self.nixosModules.default;
    };
}
