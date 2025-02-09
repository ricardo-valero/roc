{ pkgs }:
let
  zigPkg = pkgs.zig;
  llvmPkgs = pkgs.llvm_18;
  # nix does not store libs in /usr/lib or /lib
  glibcPath = if pkgs.stdenv.isLinux then "${pkgs.glibc.out}/lib" else "";
  libGccSPath =
    if pkgs.stdenv.isLinux then "${pkgs.stdenv.cc.cc.lib}/lib" else "";
  darwinInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin (builtins.attrValues {
    inherit (pkgs.darwin.apple_sdk.frameworks)
      AppKit CoreFoundation CoreServices Foundation Security;
  });
in { inherit zigPkg llvmPkgs glibcPath libGccSPath darwinInputs; }
