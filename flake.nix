{
  description = "Cardano Node";

  inputs = {
    # IMPORTANT: report any change to nixpkgs channel in nix/default.nix:
    nixpkgs.follows = "haskellNix/nixpkgs-2105";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils.url = "github:numtide/flake-utils";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Custom user config (default: empty), eg.:
    # { outputs = {...}: {
    #   # Cutomize listeming port of node scripts:
    #   nixosModules.cardano-node = {
    #     services.cardano-node.port = 3002;
    #   };
    # };
    customConfig.url = "github:input-output-hk/empty-flake";
  };

  outputs = { self, nixpkgs, utils, haskellNix, iohkNix, customConfig }:
    let
      inherit (nixpkgs) lib;
      inherit (lib) head systems mapAttrs recursiveUpdate mkDefault
        getAttrs optionalAttrs nameValuePair attrNames;
      inherit (utils.lib) eachSystem mkApp flattenTree;
      inherit (iohkNix.lib) prefixNamesWith collectExes;

      supportedSystems = import ./supported-systems.nix;
      defaultSystem = head supportedSystems;

      overlays = [
        haskellNix.overlay
        iohkNix.overlays.haskell-nix-extra
        iohkNix.overlays.crypto
        iohkNix.overlays.cardano-lib
        iohkNix.overlays.utils
        (final: prev: {
          customConfig = recursiveUpdate
            (import ./nix/custom-config.nix final.customConfig)
            customConfig.outputs;
          gitrev = self.rev or "dirty";
          commonLib = lib
            // iohkNix.lib
            // final.cardanoLib
            // import ./nix/svclib.nix { inherit (final) pkgs; };
        })
        (import ./nix/pkgs.nix)
      ];

    in eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        inherit (pkgs.commonLib) eachEnv environments;

        devShell = import ./shell.nix { inherit pkgs; };

        flake = pkgs.cardanoNodeProject.flake {
          crossPlatforms = p: with p; [
            mingwW64
            musl64
          ];
        };

        scripts = flattenTree pkgs.scripts;

        checks =
          # Linux only checks:
          optionalAttrs (system == "x86_64-linux") (
            prefixNamesWith "nixosTests/" (mapAttrs (_: v: v.${system} or v) pkgs.nixosTests)
          )
          # checks run on default system only;
          // optionalAttrs (system == defaultSystem) {
            hlint = pkgs.callPackage pkgs.hlintCheck {
              inherit (pkgs.cardanoNodeProject.projectModule) src;
            };
          };

        exes = collectExes
           flake.packages;


        packages = {
          inherit (devShell) devops;
          inherit (pkgs) cardano-node-profiled cardano-node-eventlogged cardano-node-asserted tx-generator-profiled locli-profiled;
        }
        // scripts
        // exes
        # Linux only packages:
        // optionalAttrs (system == "x86_64-linux") {
          "dockerImage/node" = pkgs.dockerImage;
          "dockerImage/submit-api" = pkgs.submitApiDockerImage;
        }

        # Add checks to be able to build them individually
        // (prefixNamesWith "checks/" checks);

      in recursiveUpdate flake {

        inherit environments packages checks;

        legacyPackages = pkgs;

        # Built by `nix build .`
        defaultPackage = flake.packages."cardano-node:exe:cardano-node";

        # Run by `nix run .`
        defaultApp = flake.apps."cardano-node:exe:cardano-node";

        # This is used by `nix develop .` to open a devShell
        inherit devShell;

        apps = {
          repl = mkApp {
            drv = pkgs.writeShellScriptBin "repl" ''
              confnix=$(mktemp)
              echo "builtins.getFlake (toString $(git rev-parse --show-toplevel))" >$confnix
              trap "rm $confnix" EXIT
              nix repl $confnix
          '';
          };
          cardano-ping = { type = "app"; program = pkgs.cardano-ping.exePath; };
        }
        # nix run .#<exe>
        // (collectExes flake.apps);
      }
    ) // {
      overlay = import ./overlay.nix self;
      nixosModules = {
        cardano-node = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-node-service.nix ];
          services.cardano-node.cardanoNodePkgs = lib.mkDefault self.legacyPackages.${pkgs.system};
        };
        cardano-submit-api = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-submit-api-service.nix ];
          services.cardano-submit-api.cardanoNodePkgs = lib.mkDefault self.legacyPackages.${pkgs.system};
        };
      };
    };
}
