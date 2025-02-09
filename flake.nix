{
  description = "Roc flake";

  inputs = {
    nixpkgs.url =
      "github:nixos/nixpkgs?rev=184957277e885c06a505db112b35dfbec7c60494";
    # rust from nixpkgs has some libc problems, this is patched in the rust-overlay
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # for non flake backwards compatibility
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, rust-overlay, ... }:
    let
      supportedSystems =
        [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;
      templates = import ./nix/templates { };
    in {
      inherit templates;

      devShells = forEachSystem (system:
        let
          overlays = [ (import rust-overlay) ] ++ [
            (final: prev: {
              # using a custom simple-http-server fork because of github.com/TheWaWaR/simple-http-server/issues/111
              # the server is used for local testing of the roc website
              simple-http-server =
                final.callPackage ./nix/simple-http-server.nix { };
            })
          ];
          pkgs = import nixpkgs { inherit system overlays; };
          rocBuild = import ./nix { inherit pkgs; };
          inherit (rocBuild.compile-deps)
            zigPkg llvmPkgs glibcPath libGccSPath darwinInputs;

          # DevInputs are not necessary to build roc as a user
          linuxDevInputs = pkgs.lib.optionals pkgs.stdenv.isLinux
            (builtins.attrValues {
              inherit (pkgs)
                valgrind # used in cli tests, see cli/tests/cli_tests.rs
                cargo-llvm-cov # to visualize code coverage
                curl # used by www/build.sh
              ;
            });
          darwinDevInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin
            (builtins.attrValues {
              inherit (pkgs)
                curl # for wasm-bindgen-cli libcurl (see ./ci/www-repl.sh)
              ;
            });

          sharedInputs = builtins.attrValues {
            inherit (pkgs)
              cmake # build libraries
              # lldb  # for debugging
              lld_18 # faster builds - see https://github.com/roc-lang/roc/blob/main/BUILDING_FROM_SOURCE.md#use-lld-for-the-linker
              clang_18 pkg-config # clang
              libffi libxml2 ncurses zlib # lib deps
              perl # ./ci/update_basic_cli_url.sh
            ;
          } ++ [
            llvmPkgs.dev # provides llvm
            zigPkg # roc builtins are implemented in zig, see compiler/builtins/bitcode/
            rocBuild.rust-shell
          ];

          sharedDevInputs = builtins.attrValues {
            inherit (pkgs)
              nil nixd # nix language server
              nixfmt-classic # nix formatter
              git python3 # other
              wasm-pack # for repl_wasm
              jq # used in several bash scripts
              zls # zig language server
              cargo-criterion # for benchmarks
              cargo-nextest # used to give more info for segfaults for gen tests
              # cargo-udeps # to find unused dependencies
            ;
          };

          aliases = ''
            alias clippy='cargo clippy --workspace --tests --release -- --deny warnings'
            alias fmt='cargo fmt --all'
            alias fmtc='cargo fmt --all -- --check'
          '';
        in {
          default = pkgs.mkShell {
            buildInputs = sharedInputs ++ sharedDevInputs ++ darwinInputs
              ++ darwinDevInputs ++ linuxDevInputs;

            # nix does not store libs in /usr/lib or /lib
            # for libgcc_s.so.1
            NIX_LIBGCC_S_PATH = libGccSPath;
            # for crti.o, crtn.o, and Scrt1.o
            NIX_GLIBC_PATH = glibcPath;

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (builtins.attrValues {
              inherit (pkgs) pkg-config libffi ncurses zlib;
              inherit (pkgs.stdenv.cc.cc) lib;
            } ++ linuxDevInputs);

            shellHook = ''
              export LLVM_SYS_180_PREFIX="${llvmPkgs.dev}"
                  ${aliases}

              # https://github.com/ziglang/zig/issues/18998
              unset NIX_CFLAGS_COMPILE
              unset NIX_LDFLAGS
            '';
          };
        });

      formatter = forEachSystem (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.nixfmt-classic);

      # You can build this package with the `nix build` command (e.g. `nix build .#cli`)
      packages = forEachSystem (system:
        let
          overlays = [ (import rust-overlay) ];
          pkgs = import nixpkgs { inherit system overlays; };
          rocBuild = import ./nix { inherit pkgs; };
        in rec {
          # all rust crates in workspace.members of Cargo.toml
          inherit (rocBuild)
            full full-debug cli cli-debug language-server language-server-debug;
          default = cli;
        });

      apps = forEachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/roc";
        };
      });
    };
}
