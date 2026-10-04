{
  description = "Gloop (abseil/gloop fork) with a Nix dev shell for Bazel";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Gloop only supports Linux on x86-64 and ARM64.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The LLVM version everything is compiled with. The exact compiler is
      # whatever flake.lock pins for this major version. Gloop requires
      # Clang >= 21.
      llvmFor = pkgs: pkgs.llvmPackages_21;

      # A dev shell in which Bazel can build Gloop, or a project that depends
      # on it. Takes the same arguments as `pkgs.mkShell`; `packages` are added
      # to Bazel and the clang tools.
      mkDevShell = pkgs: args:
        let
          llvm = llvmFor pkgs;
        in
        # Gloop rejects libstdc++, so this is the libc++ flavour of the clang
        # stdenv. Bazel picks up $CC from it.
        (pkgs.mkShell.override { stdenv = llvm.libcxxStdenv; }) (args // {
          packages = [
            # nixpkgs' plain `bazel` is an older major version.
            pkgs.bazel_9
            # buildifier, the BUILD file formatter.
            pkgs.bazel-buildtools
            # clangd, clang-format and clang-tidy, matching the compiler and,
            # like it, reading libc++'s headers.
            (llvm.clang-tools.override { enableLibcxx = true; })
          ] ++ (args.packages or [ ]);

          # Bazel's auto-configured toolchain links libstdc++ unless told
          # otherwise. These are read when the toolchain is configured
          # (colon-separated). Compiling needs nothing: the clang wrapper
          # already selects libc++'s headers, and an explicit -stdlib there is
          # an unused-argument error in dependencies built with -Werror.
          # Linking does: Bazel links through `clang`, not `clang++`, so the
          # wrapper does not add libc++ or its directory itself.
          BAZEL_CXXOPTS = "-std=c++20";
          BAZEL_LINKOPTS = "-L${llvm.libcxx}/lib:-Wl,-rpath,${llvm.libcxx}/lib";
          BAZEL_LINKLIBS = "-lc++:-lm";
        });
    in
    {
      # For projects that depend on Gloop:
      #   devShells.default = gloop.lib.mkDevShell pkgs { packages = [ ... ]; };
      lib = { inherit mkDevShell; };

      devShells = forAllSystems (pkgs: {
        default = mkDevShell pkgs {
          packages = [
            # Profiling: perf samples a running program, flamegraph (from
            # cargo-flamegraph) draws the result, and samply opens recordings
            # in the Firefox Profiler.
            pkgs.perf
            pkgs.cargo-flamegraph
            pkgs.samply
          ];
        };
      });
    };
}
