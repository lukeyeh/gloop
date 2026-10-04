# Gloop with Nix

This fork of [abseil/gloop](https://github.com/abseil/gloop) adds a Nix flake
so that Gloop builds with Bazel on any Linux machine with Nix, and so that
Nix + Bazel projects (in the style of
[nix-bazel-cpp](https://github.com/lukeyeh/nix-bazel-cpp-skill)) can depend on
it. Gloop's sources are unchanged; the fork only adds:

| File | Purpose |
| --- | --- |
| `flake.nix`, `flake.lock` | The dev shell (Bazel 9, buildifier, Clang 21 with libc++, clangd, profilers), and `lib.mkDevShell` for projects that use Gloop |
| `.envrc` | `use flake` for direnv |
| `.bazelversion` | The Bazel version the Nix shell provides, for bazelisk users |
| `BUILD` | `:compile_commands` alias for clangd |
| `MODULE.bazel`, `.bazelrc` | The compile-commands dev dependency, and flags the Nix shell needs |
| `.github/workflows/sync-upstream.yml` | Daily rebase onto upstream (see below) |

## Setup

```
nix develop            # or `direnv allow` once
bazel test //gloop/util/...
bazel run :compile_commands     # compile_commands.json for clangd
```

Always run Bazel inside the shell. Outside it Bazel silently picks up the host
compiler, which Gloop will most likely reject. Start clangd with
`--query-driver=/**/*` so it can find Nix's system headers
([clangd#1079](https://github.com/clangd/clangd/issues/1079)).

`bazel test //...` builds everything, including gRPC and protobuf, and takes
a long time. Upstream tests inside Google's Docker image; in the Nix shell a
handful of tests that depend on that environment fail (see Known failures).

## Using Gloop from your own project

Your project keeps the usual layout: a flake dev shell, `nix/deps.nix`, and
rules_nixpkgs for libraries. Gloop is added as a Bazel module from this fork.
Three things differ from a project without Gloop.

### 1. The dev shell comes from this flake

Gloop only compiles with Clang >= 21 and libc++, and refuses libstdc++.
`lib.mkDevShell` is `pkgs.mkShell` with that toolchain and Bazel set up:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    gloop.url = "github:lukeyeh/gloop";
    # One nixpkgs, so one compiler pin.
    gloop.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, gloop }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = gloop.lib.mkDevShell pkgs {
          packages = [ pkgs.perf ];   # anything else you want in the shell
        };
      });
    };
}
```

### 2. Gloop and the libraries it shares with you come from the Bazel registry

Gloop builds its own Abseil, GoogleTest and protobuf from the registry. Take
those from the registry too, at the versions in Gloop's `MODULE.bazel`, so the
binary contains one copy. Do not also import them with `nix_pkg`.

```starlark
bazel_dep(name = "gloop")
git_override(
    module_name = "gloop",
    remote = "https://github.com/lukeyeh/gloop.git",
    commit = "<a commit on the nix branch, or a nix-YYYYMMDD tag's commit>",
)

bazel_dep(name = "abseil-cpp", version = "20260817.0")
bazel_dep(name = "googletest", version = "1.17.0.bcr.2")
```

Depend on targets as `@gloop//gloop/util/math:mathutil`,
`@abseil-cpp//absl/status` and `@googletest//:gtest_main`.

Everything else still comes from nixpkgs through rules_nixpkgs, exactly as
without Gloop (`nix_repo.flake`, `nix/deps.nix`, one `nix_pkg.file` block per
library). C libraries such as liburing work as they are. A C++ library from
nixpkgs is built against libstdc++ and has to be rebuilt for libc++ in
`nix/deps.nix`, e.g. `pkgs.foo.override { stdenv = pkgs.llvmPackages_21.libcxxStdenv; }`.

### 3. Flags

Gloop enforces these with `#error`. In `.bazelrc`:

```
build --cxxopt=-std=c++20 --host_cxxopt=-std=c++20
build --copt=-fno-exceptions --host_copt=-fno-exceptions
build --copt=-funsigned-char --host_copt=-funsigned-char
```

### What does not carry over

A `nix/package.nix` that compiles the sources without Bazel cannot build a
program that uses Gloop, since Gloop only exists as Bazel targets. Deploy the
binary Bazel builds instead.

This arrangement was checked with a project that links Gloop's `mathutil`,
`ipaddress`, `strtoint` and `ret_check` together with liburing from nixpkgs in
one test binary.

## How the toolchain is pinned

`mkDevShell` uses `llvmPackages_21.libcxxStdenv`, which sets `CC=clang`, and
exports the variables Bazel's auto-configured C++ toolchain reads so that it
links libc++ instead of libstdc++:

```
BAZEL_CXXOPTS=-std=c++20
BAZEL_LINKOPTS=-L<libcxx>/lib:-Wl,-rpath,<libcxx>/lib
BAZEL_LINKLIBS=-lc++:-lm
```

`flake.lock` pins the exact compiler; `nix flake update` moves it. To check
the pin took effect, confirm the compiler in `compile_commands.json` is
`/nix/store/...-clang-wrapper-21.x/bin/clang`.

## Known failures

Of the 407 tests, these do not pass in the Nix shell on Ubuntu. None affects
using Gloop as a library.

| Test | Cause |
| --- | --- |
| `//gloop/concurrent/percpu:rseq_clobber_test` | Does not link: its linker script is not accepted by gold, the linker Bazel selects here |
| `//gloop/util/process:subprocess_unittest_*` (4) | Runs commands through `/bin/sh`, which is dash on Ubuntu and rejects their bash syntax |
| `//gloop/base:sysinfo_unittest`, `sysinfo_errorlog_unittest` | Reading a piped command's output fails; not investigated further |
| `//gloop/util/symbolize:symbolized_stacktrace_unittest` | Expects a different symbol name for glibc's start function than Nix's glibc has |

## Keeping up with upstream

Upstream expects users to live at head and occasionally rewrites `main`, so
the fork keeps two branches:

| Branch | Contents |
| --- | --- |
| `main` | An exact mirror of `abseil/gloop` main. Never commit here. |
| `nix` | `main` plus the Nix commit. The default branch; depend on this one. |

`.github/workflows/sync-upstream.yml` runs daily (and on demand from the
Actions tab). It rebases `nix` onto upstream main, builds and tests a subset
inside the Nix shell, and then moves both branches together. If the rebase
conflicts or the build fails, nothing moves and the run fails, so `nix` always
points at a commit that built.

One-time setup on GitHub:

1.  Enable Actions for the fork (Actions tab).
2.  Create a fine-grained personal access token for this repository with
    **Contents** and **Workflows** read/write, and save it as the repository
    secret `SYNC_TOKEN`. Without it the sync fails whenever upstream touches
    `.github/workflows/`.
3.  Upstream's own workflows (`Tests`, `Release`, ...) need Google's
    infrastructure and are disabled in the fork with `gh workflow disable`.

GitHub pauses scheduled workflows after 60 days without repository activity;
re-enable it from the Actions tab if that happens.

Because `nix` is rebased, its commit ids change. Each sync also pushes a
`nix-YYYYMMDD` tag, so a commit you pinned with `git_override` stays available
after later rebases. To fix a failed sync by hand:

```
jj git fetch --all-remotes
jj rebase -b nix -d main@upstream     # resolve conflicts
nix develop -c bazel test //gloop/ci/...
jj bookmark set main -r main@upstream
jj git push --bookmark main --bookmark nix
```
