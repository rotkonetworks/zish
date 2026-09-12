{
  lib,
  stdenv,
  zig,
  callPackage,
  installShellFiles,
  makeWrapper,
  curl,
  git,
  gnutar,
  coreutils,
  # Which feat set to stage beside the binary: "core" (default — utils + gf, the
  # lean base) or "all" (also agent/team/web/… for a batteries-included build).
  # flake.nix exposes both as packages.zish and packages.zish-full.
  featSet ? "core",
}:
let
  src = lib.cleanSource ../.;

  # From build.zig.zon, the only place the version is declared (the release
  # workflow refuses a tag that disagrees with it). A second copy here is
  # another thing to forget — this file still said 0.22.0 while the tree was
  # three releases further on.
  version =
    let
      m = builtins.match ".*\\.version = \"([0-9.]+)\".*"
        (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ../build.zig.zon));
    in
    if m == null then "0.0.0" else builtins.head m;
in
stdenv.mkDerivation {
  pname = "zish";
  inherit version src;

  nativeBuildInputs = [
    zig
    installShellFiles
    makeWrapper
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    # --release=safe, matching the Makefile, the PKGBUILD and CI. build.zig's own
    # comment argues these checks are "the difference between a crash and an
    # exploitable primitive" in a shell an agent drives; this said
    # `--release=fast`, so nix users were the only ones without them.
    #
    # ZIG_GLOBAL_CACHE_DIR is pointed into the build's own tmp: zish has no Zig
    # package dependencies (build.zig.zon's `.dependencies` is empty), so no
    # prefetch derivation is needed, and if one is ever added the build fails
    # loudly here — which is the right signal, rather than a pinned hash in this
    # file that nobody remembers to update.
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build --release=safe --prefix $out -Dfeats=${featSet}
    runHook postBuild
  '';

  # Tests are not run here.
  #
  # Several of them (crypto key persistence, shell init) create and read state
  # under $HOME, which does not exist in the Nix sandbox — they fail on the
  # environment, not on the code. Pointing HOME at a scratch directory is not
  # enough, because the key path is resolved before that is visible.
  #
  # They are covered where they can actually run: `zig build test` locally and
  # in CI, plus tests/regress.sh end-to-end. Making them sandbox-clean is worth
  # doing, but it is a change to the tests, not to this derivation.
  doCheck = false;

  postInstall = ''
    installManPage zish.1

    # Runtime tools the feats shell out to: gf execs curl/git/tar/sha256sum to
    # fetch, verify and unpack feats; web execs curl. Suffix them onto PATH so
    # they are a fallback on a minimal system without shadowing the user's own.
    # Feats inherit this PATH because zish execs them.
    wrapProgram $out/bin/zish \
      --suffix PATH : ${
        lib.makeBinPath [
          curl
          git
          gnutar
          coreutils
        ]
      }
  '';

  meta = {
    description = "Fast, zsh-compatible shell written in Zig";
    homepage = "https://github.com/rotkonetworks/zish";
    license = lib.licenses.mit;
    mainProgram = "zish";
    # Linux-only by construction: the shell talks to the kernel directly for
    # job control and terminal handling (std.os.linux, TIOCSPGRP, and friends).
    platforms = lib.platforms.linux;
  };
}
