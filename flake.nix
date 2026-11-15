{
  # TC0 development toolchain epoch, NOT a qualification claim.
  # Pins the Shen ports and tools the pure-call development checks rely on:
  #   shen-scheme v0.26   host oracle (build/toolchain/shen-scheme)
  #   shen-cl dff7445     second port and Yggdrasil stage-1 host, built from the
  #                       S41.2 kernel precompiled with nixpkgs' shen-sbcl 41.2
  #   yggdrasil a40d8c5   tree-shaker for the eval-free oracle
  #   sbcl, nodejs_22, python3, go 1.27 from the pinned nixpkgs release
  # The native-host epoch (Solo5 images, C toolchain) is separate and not opened here.
  description = "Fenrir / Gleipnir TC0 development toolchain epoch";

  inputs = {
    nixpkgs.url = "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1088030.8edc0c72e3a3/nixexprs.tar.zst";
    # Sources fetched by Nix itself and locked by NAR hash in flake.lock.
    shen-cl-src = { url = "git+https://github.com/Shen-Language/shen-cl?rev=dff7445e6cd3ed9c021fdf6e8a45ffafa3128347"; flake = false; };
    yggdrasil-src = { url = "git+https://github.com/pyrex41/yggdrasil?rev=a40d8c5b6ed1eb2b5d7a4511e61d0304ce9a2e3d"; flake = false; };
    # Shen/JIT v0.7: host of the Shen harness (harness/) and of the model it runs.
    shen-jit-src = { url = "git+https://github.com/tizoc/shen-jit?rev=2f4b48bf9aabc2b93379d15f1818e4209137eb60"; flake = false; };
    # Solo5 v0.9.3 at the commit the Solo5 lane pins (tools/solo5/freerun.mjs SOLO5_COMMIT).
    solo5-src = { url = "git+https://github.com/Solo5/solo5?rev=38e0c348be231a2a3c59510a5caabf562792679f"; flake = false; };
  };

  outputs = { self, nixpkgs, shen-cl-src, yggdrasil-src, shen-jit-src, solo5-src }:
    let
      system = "x86_64-linux"; # shen-scheme v0.26 ships a Linux x86-64 binary only
      pkgs = nixpkgs.legacyPackages.${system};

      shen-scheme = pkgs.stdenv.mkDerivation {
        pname = "shen-scheme";
        version = "0.26";
        src = pkgs.fetchurl {
          url = "https://github.com/tizoc/shen-scheme/releases/download/v0.26/shen-scheme-v0.26-linux-bin.tar.gz";
          hash = "sha256-KFk4TzsWzWz1lghM//fi2dWzGhHfPR98nh8XRu1u95g=";
        };
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.libuuid ];
        installPhase = ''
          mkdir -p $out
          cp -r bin lib $out/
        '';
      };

      # Shen/JIT builds itself from the kernel release and an earlier Shen/JIT release,
      # which its tools/ci-deps.sh names with these hashes. bin/shen-jit is the runtime
      # with its image appended, so it must not be stripped or patched after the build.
      shen-jit-kernel = pkgs.fetchurl {
        url = "https://github.com/Shen-Language/shen-sources/releases/download/shen-43.6/ShenOSKernel-43.6.tar.gz";
        sha256 = "61d1795755a57da252ba8108cdfccc680f95a04bfd395a54f533ab6724647ef5";
      };
      shen-jit-bootstrap = pkgs.fetchurl {
        url = "https://github.com/tizoc/shen-jit/releases/download/v0.1/shen-jit-0.1-linux-x86_64-static.tar.gz";
        sha256 = "4e569fe92e24a722afe406807e7ad3271fd2d6cc4b7744c981536f732e2953bd";
      };
      shen-jit = pkgs.stdenv.mkDerivation {
        pname = "shen-jit";
        version = "0.7";
        src = shen-jit-src;
        buildPhase = ''
          mkdir -p .deps/kernel .deps/shen-jit
          tar -C .deps/kernel --strip-components=1 -xzf ${shen-jit-kernel}
          tar -C .deps/shen-jit --strip-components=1 -xzf ${shen-jit-bootstrap}
          make
          make process
        '';
        installPhase = ''
          mkdir -p $out/bin $out/lib
          cp build/shen-jit $out/bin/
          cp lib/*.shen $out/lib/
          cp build/shen-process.so $out/lib/
        '';
        dontStrip = true;
        dontPatchELF = true;
        dontFixup = true;
      };

      # Stock Solo5 at the pinned commit, built in place the way the hand-built checkout is
      # (./configure.sh && make) with nixpkgs' libseccomp and pkg-config, and installed as
      # the built tree: the tools read tenders/spt/solo5-spt, elftool/solo5-elftool and the
      # toolchain wrapper under toolchain/bin. No source file is modified; the store path
      # derives from the locked source hash, and COMMIT records the pinned commit.
      solo5 = pkgs.stdenv.mkDerivation {
        pname = "solo5";
        version = "0.9.3-38e0c348";
        src = solo5-src;
        nativeBuildInputs = [ pkgs.pkg-config pkgs.gnumake ];
        buildInputs = [ pkgs.libseccomp ];
        dontConfigure = true;
        dontStrip = true;
        dontPatchELF = true;
        dontFixup = true;
        hardeningDisable = [ "all" ];
        buildPhase = ''
          # A source tree without .git needs the release tarball's version header; this is
          # what scripts/gen_version_h.sh would print for the tagged commit (git describe).
          cat > include/version.h.distrib <<'EOM'
          /* Automatically generated, do not edit */

          #ifndef __VERSION_H__
          #define __VERSION_H__

          #define SOLO5_VERSION "v0.9.3"

          #endif
          EOM
          # Solo5 builds with -Werror and v0.9.3 predates nixpkgs' gcc: demote only the
          # newer diagnostics to warnings. The source is not touched.
          export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -Wno-error=address"
          sh ./configure.sh
          make
          test -x tenders/spt/solo5-spt
          test -x elftool/solo5-elftool
        '';
        installPhase = ''
          mkdir -p $out
          cp -r . $out/
          # The in-tree toolchain links its headers and bindings by absolute build path.
          find $out -type l | while read -r link; do
            target=$(readlink "$link")
            case "$target" in
              "$PWD"/*) ln -sfn "$out/''${target#"$PWD"/}" "$link" ;;
            esac
          done
          echo 38e0c348be231a2a3c59510a5caabf562792679f > $out/COMMIT
        '';
      };

      shen-kernel = pkgs.fetchurl {
        url = "https://github.com/Shen-Language/shen-sources/releases/download/shen-41.2/ShenOSKernel-41.2.tar.gz";
        hash = "sha256-0hgtcEU9PpPRO8IPdj79wYzbI7SB9Br7mUP16aB5j2E=";
      };

      # The whole built checkout: Yggdrasil's lisp builder needs compiled/ and src/
      # next to bin/sbcl/shen.
      shen-cl = pkgs.stdenv.mkDerivation {
        pname = "shen-cl";
        version = "unstable-dff7445";
        src = shen-cl-src;
        nativeBuildInputs = [ pkgs.sbcl pkgs.shen-sbcl ];
        # An SBCL executable carries its core after the ELF image; stripping or
        # patching it would corrupt that.
        dontStrip = true;
        dontPatchELF = true;
        buildPhase = ''
          export HOME=$TMPDIR
          tar zxf ${shen-kernel}
          mv ShenOSKernel-41.2 kernel
          mkdir -p compiled
          # shen-sbcl is REPL-only; it reports "empty stream" and exits nonzero once
          # stdin ends, so success is judged by the compiled files below.
          printf '(load "scripts/build.shen")\n(build)\n' | shen-sbcl > precompile.log 2>&1 || true
          for f in compiler core declarations dict extension-expand-dynamic extension-features \
                   extension-launcher init load macros prolog reader sequent stlib sys t-star \
                   toplevel track types writer yacc; do
            test -s compiled/$f.lsp || { echo "missing compiled/$f.lsp"; tail -40 precompile.log; exit 1; }
          done
          sbcl --load boot.lsp
          test -x bin/sbcl/shen
        '';
        installPhase = ''
          mkdir -p $out
          cp -r . $out/
        '';
      };

      yggdrasil = (pkgs.buildGoModule.override { go = pkgs.go_1_27; }) {
        pname = "yggdrasil";
        version = "unstable-a40d8c5";
        src = yggdrasil-src;
        vendorHash = null;
        subPackages = [ "." ];
        doCheck = false; # its tests need every Shen target port installed
      };

      # ---- BEGIN stage A3 host service (host/service/): additive, self-contained block ----
      # The OTP host and the SQLite port program of stage A3 (04_DIRECTION_AMENDMENT.md
      # section 8), pinned by this flake's nixpkgs input: Erlang/OTP from beamPackages,
      # SQLite (library and headers) for the C port program, gcc to build it, and
      # nodejs_22 for the existing image build step. No hex/rebar dependency is fetched.
      a3-tools = pkgs.buildEnv {
        name = "fenrir-a3-tools";
        paths = [ pkgs.beamPackages.erlang pkgs.sqlite.out pkgs.sqlite.dev pkgs.sqlite.bin pkgs.gcc pkgs.nodejs_22 ];
        pathsToLink = [ "/bin" "/lib" "/include" ];
      };
      # ---- END stage A3 host service ----

      # Links the pinned host oracle where the development checks expect it.
      link-toolchain = pkgs.writeShellScriptBin "fenrir-link-toolchain" ''
        set -eu
        mkdir -p build/toolchain
        ln -sfn ${shen-scheme}/bin/shen-scheme build/toolchain/shen-scheme
        echo "build/toolchain/shen-scheme -> ${shen-scheme}/bin/shen-scheme"
        echo "shen-cl:   ${shen-cl}"
        echo "yggdrasil: ${yggdrasil}/bin/yggdrasil"
      '';
    in {
      packages.${system} = { inherit shen-scheme shen-cl shen-jit solo5 yggdrasil link-toolchain; default = link-toolchain; } // { fenrir-a3-tools = a3-tools; }; # A3: additive
      apps.${system}.default = { type = "app"; program = "${link-toolchain}/bin/fenrir-link-toolchain"; };
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_22 pkgs.python3 pkgs.sbcl pkgs.go_1_27 shen-scheme yggdrasil ];
        FENRIR_SHEN_CL = "${shen-cl}";
      };
    };
}
