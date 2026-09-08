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

  # zish has one Zig package dependency (clap), fetched over the network by
  # `zig build`. Nix builds are sandboxed and offline, so the fetch happens here
  # in a fixed-output derivation and the populated cache is handed to the real
  # build below.
  #
  # After changing build.zig.zon, update `outputHash`: set it to
  # lib.fakeHash, run the build, and copy the hash nix reports.
  deps = stdenv.mkDerivation {
    pname = "zish-deps";
    version = "0.21.1";
    inherit src;

    nativeBuildInputs = [ zig ];

    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;

    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$out
      zig build --fetch
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-pQpattmS9VmO3ZIQUFn66az8GSmB4IvYhTTCFn6SUmo=";
  };
in
stdenv.mkDerivation {
  pname = "zish";
  version = "0.16.0";
  inherit src;

  nativeBuildInputs = [
    zig
    installShellFiles
    makeWrapper
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    cp -r --no-preserve=mode,ownership ${deps} $ZIG_GLOBAL_CACHE_DIR
    zig build --release=fast --prefix $out -Dfeats=${featSet}
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
