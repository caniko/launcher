{
  description = "BlizzNux: Battle.net games on Linux through Proton, no Steam needed";

  inputs = {
    harbor-rs.url = "github:caniko/harbor-rs";
    nixpkgs.follows = "harbor-rs/nixpkgs";
    rust-overlay.follows = "harbor-rs/rust-overlay";
    crane.follows = "harbor-rs/crane";
  };

  outputs = {
    self,
    nixpkgs,
    harbor-rs,
    rust-overlay,
    ...
  }: let
    # Proton, and so every game, is x86_64 only.
    systems = ["x86_64-linux"];
    forSystem = system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };
      inherit (pkgs) lib;
      # Stable, as the release container and test.yml use; harbor-rs defaults to nightly.
      toolchain = harbor-rs.lib.mkToolchain {
        inherit pkgs;
        toolchainProfile = "stable";
      };
      inherit (toolchain) craneLib;
      cross = harbor-rs.lib.mkCross {inherit pkgs system;};

      # The crate is in src-tauri/; its build embeds ui/ and the package installs bin/ and share/.
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./src-tauri/Cargo.toml
          ./src-tauri/Cargo.lock
          ./src-tauri/build.rs
          ./src-tauri/capabilities
          ./src-tauri/icons
          ./src-tauri/src
          ./src-tauri/tauri.conf.json
          ./ui
          ./bin
          ./share
          ./scripts
          ./install.sh
          ./flatpak/build.sh
        ];
      };

      buildInputs = [pkgs.glib-networking pkgs.webkitgtk_4_1];

      commonArgs = {
        inherit src buildInputs;
        inherit (craneLib.crateNameFromCargoToml {cargoToml = ./src-tauri/Cargo.toml;}) pname version;
        cargoToml = ./src-tauri/Cargo.toml;
        cargoLock = ./src-tauri/Cargo.lock;
        # harbor-rs reads the manifest at the root of src unless told otherwise.
        rsHarborCargoTomlContents = builtins.readFile ./src-tauri/Cargo.toml;
        postUnpack = ''
          cd "$sourceRoot/src-tauri"
          sourceRoot=.
        '';
        strictDeps = true;
        nativeBuildInputs = [pkgs.pkg-config];
        # What `tauri build` adds over a plain cargo build; the UI needs no build step.
        cargoExtraArgs = "--locked --features tauri/custom-protocol";
      };

      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      package = craneLib.buildPackage (commonArgs
        // {
          inherit cargoArtifacts;
          doCheck = false; # checks.test
          nativeBuildInputs = commonArgs.nativeBuildInputs ++ [pkgs.wrapGAppsHook3];
          # The app finds blizznux-run next to its own binary.
          postInstall = ''
            install -Dm755 ../bin/blizznux-run -t $out/bin
            install -Dm644 ../share/applications/com.blizznux.launcher.desktop -t $out/share/applications
            cp -r ../share/icons $out/share
            rm -r $out/lib # the crate's library targets, only for the binary
          '';
          # Wraps both programs: the deb/rpm dependencies (python3 only ran the downloaded
          # umu-launcher), and the packaged umu-launcher, which runs on NixOS.
          preFixup = ''
            gappsWrapperArgs+=(
              --prefix PATH : ${lib.makeBinPath [pkgs.curl pkgs.xz]}
              --set-default BLIZZNUX_UMU ${lib.getExe pkgs.umu-launcher}
            )
          '';
          meta = {
            description = "Battle.net games on Linux through Proton, no Steam needed";
            homepage = "https://github.com/BlizzNux/launcher";
            license = lib.licenses.gpl3Plus;
            mainProgram = "blizznux";
            platforms = systems;
          };
        });
    in {
      inherit package;

      checks = {
        inherit package;

        # The bug-class lints only, as in .github/workflows/test.yml.
        clippy = craneLib.cargoClippy (commonArgs
          // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- -D clippy::correctness -D clippy::suspicious";
          });

        test = craneLib.cargoTest (commonArgs
          // {
            inherit cargoArtifacts;
            cargoTestExtraArgs = "--lib";
          });

        # The module evaluates and wires what it promises.
        module = let
          inherit
            (nixpkgs.lib.nixosSystem {
              modules = [
                self.nixosModules.default
                {
                  nixpkgs.hostPlatform = system;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "25.11";
                  programs.blizznux = {
                    enable = true;
                    proton = "/opt/proton";
                  };
                }
              ];
            })
            config
            ;
        in
          assert config.hardware.graphics.enable32Bit;
          assert config.environment.sessionVariables.BLIZZNUX_PROTON == "/opt/proton";
          assert builtins.elem package config.environment.systemPackages;
            pkgs.runCommand "blizznux-module" {} "touch $out";

        scripts =
          pkgs.runCommand "blizznux-scripts" {
            nativeBuildInputs = [pkgs.bash];
          } ''
            cd ${src}
            for f in bin/blizznux-run scripts/*.sh install.sh flatpak/build.sh; do
              bash -n "$f"
            done
            bash scripts/test-labs-env.sh
            touch $out
          '';
      };

      devShell =
        (harbor-rs.lib.mkDevShells {
          inherit pkgs cross craneLib;
          # The package's inputs, so pkg-config also finds what webkitgtk requires.
          checks = {inherit package;};
          packages = [pkgs.cargo-tauri];
        }).default;
    };
  in {
    packages = nixpkgs.lib.genAttrs systems (system: {
      default = (forSystem system).package;
    });

    checks = nixpkgs.lib.genAttrs systems (system: (forSystem system).checks);

    devShells = nixpkgs.lib.genAttrs systems (system: {
      default = (forSystem system).devShell;
    });

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.programs.blizznux;
    in {
      options.programs.blizznux = {
        enable = lib.mkEnableOption "BlizzNux, Battle.net games through Proton";

        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          defaultText = lib.literalExpression "blizznux.packages.\${pkgs.stdenv.hostPlatform.system}.default";
          description = "The BlizzNux package.";
        };

        proton = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "pkgs.proton-ge-bin.steamcompattool";
          description = ''
            A Proton folder (holding an executable `proton`) to use instead of the launcher's
            own download. Sets `BLIZZNUX_PROTON`, which wins over the folder chosen in Labs.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [cfg.package];
        environment.sessionVariables = lib.mkIf (cfg.proton != null) {
          BLIZZNUX_PROTON = toString cfg.proton;
        };
        # Proton runs 32-bit code; the launcher's readiness check wants both Vulkan drivers.
        hardware.graphics = {
          enable = lib.mkDefault true;
          enable32Bit = lib.mkDefault true;
        };
      };
    };
  };
}
