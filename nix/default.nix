{ pkgs }:
let
  rustVersion = pkgs.rust-bin.fromRustupToolchainFile ../rust-toolchain.toml;
  rustPlatform = pkgs.makeRustPlatform {
    cargo = rustVersion;
    rustc = rustVersion;
  };

  # this will allow our callPackage to reference our own packages defined below
  # mainly helps with passing compile-deps and rustPlatform to builder automatically
  callPackage = pkgs.lib.callPackageWith (pkgs // packages);

  packages = {
    inherit rustPlatform;
    compile-deps = callPackage ./compile-deps.nix { };
    rust-shell =
      # llvm-tools-preview for code coverage with cargo-llvm-cov
      rustVersion.override {
        extensions = [ "rust-src" "rust-analyzer" "llvm-tools-preview" ];
      };

    # contains all rust crates in workspace.members of Cargo.toml
    full = callPackage ./builder.nix { };
    full-debug = callPackage ./builder.nix { buildType = "debug"; };
    language-server =
      callPackage ./builder.nix { subPackage = "language_server"; };
    language-server-debug = callPackage ./builder.nix {
      subPackage = "language_server";
      buildType = "debug";
    };
    cli = callPackage ./builder.nix { subPackage = "cli"; };
    cli-debug = callPackage ./builder.nix {
      subPackage = "cli";
      buildType = "debug";
    };
  };
in packages
