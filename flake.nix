{
  description = "zish — a fast, zsh-compatible shell written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Linux only, matching meta.platforms in nix/zish.nix.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        zish = pkgs.callPackage ./nix/zish.nix { };
        default = zish;
      });

      # nix run github:rotkonetworks/zish
      apps = forAllSystems (pkgs: rec {
        zish = {
          type = "app";
          program = "${self.packages.${pkgs.system}.zish}/bin/zish";
        };
        default = zish;
      });

      # nix develop — Zig toolchain plus what tests/regress.sh needs.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            zig
            zls
            bashInteractive # tests/regress.sh diffs against bash
            hyperfine # ./bench.sh
          ];
        };
      });

      # Adds zish to environment.systemPackages and registers it in /etc/shells
      # so it can be set as a login shell.
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.zish;
        in
        {
          options.programs.zish = {
            enable = lib.mkEnableOption "the zish shell";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.zish;
              description = "The zish package to use.";
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];
            environment.shells = [ (lib.getExe cfg.package) ];
          };
        };
    };
}
