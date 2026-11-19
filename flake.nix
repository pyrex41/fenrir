{
  # TC0 development toolchain epoch, NOT a qualification claim.
  # Pins the Shen ports and tools the pure-call development checks rely on:
  #   shen-scheme v0.26   host oracle (build/toolchain/shen-scheme)
  #   shen-cl dff7445     second port and Yggdrasil stage-1 host, built from the
  #                       S41.2 kernel precompiled with nixpkgs' shen-sbcl 41.2
  #   yggdrasil a40d8c5   tree-shaker for the eval-free oracle
  #   sbcl, nodejs_22, python3, go 1.27 from the pinned nixpkgs release
  #   solo5 38e0c348      v0.9.3 built from source: spt and hvt tenders, elftool and
  #                       guest toolchain wrappers (use with FENRIR_SOLO5)
  #   erlang (OTP)        from the pinned nixpkgs, without wx: runs the supervisor of
  #                       supervisor/ (use with FENRIR_ERLANG); plain OTP, compiled with erlc
  # The control-channel native host (patched tender) is separate and not opened here.
  description = "Fenrir / Gleipnir TC0 development toolchain epoch";

  inputs = {
    nixpkgs.url = "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1088030.8edc0c72e3a3/nixexprs.tar.zst";
    # Sources fetched by Nix itself and locked by NAR hash in flake.lock.
    shen-cl-src = { url = "git+https://github.com/Shen-Language/shen-cl?rev=dff7445e6cd3ed9c021fdf6e8a45ffafa3128347"; flake = false; };
    yggdrasil-src = { url = "git+https://github.com/pyrex41/yggdrasil?rev=a40d8c5b6ed1eb2b5d7a4511e61d0304ce9a2e3d"; flake = false; };
    # Shen/JIT v0.7: host of the Shen harness (harness/) and of the model it runs.
    shen-jit-src = { url = "git+https://github.com/tizoc/shen-jit?rev=2f4b48bf9aabc2b93379d15f1818e4209137eb60"; flake = false; };
    # Solo5 v0.9.3, the commit tools/solo5/freerun.mjs pins as SOLO5_COMMIT.
    solo5-src = { url = "git+https://github.com/Solo5/solo5?ref=refs/tags/v0.9.3&rev=38e0c348be231a2a3c59510a5caabf562792679f"; flake = false; };
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

      # Shen/JIT bootstraps from the kernel and a native v0.1 executable, with
      # the hashes in the pinned source's tools/ci-deps.sh. Fetch both using
      # the build platform's nixpkgs, even though the kernel archive is shared.
      arm-pkgs = nixpkgs.legacyPackages.aarch64-linux;
      mkShenJit = pkgs: bootstrapArch: bootstrapHash:
        let
          kernel = pkgs.fetchurl {
            url = "https://github.com/Shen-Language/shen-sources/releases/download/shen-43.6/ShenOSKernel-43.6.tar.gz";
            sha256 = "61d1795755a57da252ba8108cdfccc680f95a04bfd395a54f533ab6724647ef5";
          };
          bootstrap = pkgs.fetchurl {
            url = "https://github.com/tizoc/shen-jit/releases/download/v0.1/shen-jit-0.1-linux-${bootstrapArch}-static.tar.gz";
            sha256 = bootstrapHash;
          };
        in pkgs.stdenv.mkDerivation {
          pname = "shen-jit";
          version = "0.7";
          src = shen-jit-src;
          buildPhase = ''
            mkdir -p .deps/kernel .deps/shen-jit
            tar -C .deps/kernel --strip-components=1 -xzf ${kernel}
            tar -C .deps/shen-jit --strip-components=1 -xzf ${bootstrap}
            make
            make process
          '';
          installPhase = ''
            mkdir -p $out/bin $out/lib
            cp build/shen-jit $out/bin/
            cp lib/*.shen $out/lib/
            cp build/shen-process.so $out/lib/
          '';
          # The Shen image is appended to the executable and must stay intact.
          dontStrip = true;
          dontPatchELF = true;
          dontFixup = true;
        };
      shen-jit = mkShenJit pkgs "x86_64" "4e569fe92e24a722afe406807e7ad3271fd2d6cc4b7744c981536f732e2953bd";
      arm-shen-jit = mkShenJit arm-pkgs "arm64" "2aad3cce35a39be0d9f8859122a4ad1582564ba6afad597054b2cfb2011f0f9d";

      # Solo5 at the pinned commit, built from source and installed with its own
      # `make install`: bin/ holds solo5-spt, solo5-hvt, solo5-elftool and the
      # <arch>-solo5-none-static-{cc,ld,objcopy} wrappers, which find include/ and
      # lib/ relative to themselves. The wrappers call the target compiler by name,
      # so it is configured as store paths: the unwrapped gcc with the unwrapped
      # binutils, because a guest is freestanding and must not pick up the nixpkgs
      # wrapper's hardening flags or glibc search paths. SOLO5_COMMIT is what
      # tools/solo5/freerun.mjs checks in place of a git HEAD.
      # nixpkgs carries solo5 0.10.1, not this commit, so it is not used.
      mkSolo5 = pkgs:
        let
          target-cc = pkgs.writeShellScript "solo5-target-cc" ''
            exec ${pkgs.stdenv.cc.cc}/bin/gcc -B${pkgs.binutils-unwrapped}/bin/ "$@"
          '';
        in pkgs.stdenv.mkDerivation {
          pname = "solo5";
          version = "0.9.3";
          src = solo5-src;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.libseccomp ];
          # Host tools as position-independent executables, as the distribution
          # compilers build them; otherwise configure.sh pins the spt tender at 1 GB.
          env.NIX_CFLAGS_COMPILE = "-fPIE -Wno-error=address"; # hvt_main.c:114 under this gcc
          env.NIX_CFLAGS_LINK = "-pie";
          configurePhase = ''
            # No .git in the fetched source; this is what a release tarball carries.
            printf '#define SOLO5_VERSION "v0.9.3"\n' > include/version.h.distrib
            TARGET_CC=${target-cc} \
            TARGET_LD=${pkgs.binutils-unwrapped}/bin/ld \
            TARGET_OBJCOPY=${pkgs.binutils-unwrapped}/bin/objcopy \
              sh configure.sh --prefix=$out
          '';
          buildPhase = "make";
          installPhase = ''
            make install
            for w in $out/bin/*-solo5-none-static-*; do
              sed -i '2i PATH=${pkgs.coreutils}/bin:${pkgs.findutils}/bin:$PATH' $w
            done
            printf '%s\n' ${solo5-src.rev} > $out/SOLO5_COMMIT
          '';
          dontStrip = true; # the guest bindings in lib/ are linked into every image
        };
      solo5 = mkSolo5 pkgs;
      arm-solo5 = mkSolo5 arm-pkgs;

      # Guest batches for the hvt check, built here so the VM needs neither node nor
      # a compiler: the TC1 handler fixtures with the TC0-A hand cases (43 programs),
      # and the hand, generated and 4-node exhaustive TC0-A programs (798), each
      # linked once for spt and once for hvt from the same lowered data.
      fs = pkgs.lib.fileset;
      solo5-batches = pkgs.stdenv.mkDerivation {
        name = "fenrir-solo5-batches";
        src = fs.toSource {
          root = ./.;
          fileset = fs.unions [ ./package.json ./tools ./runtime ./fixtures ./backends/solo5/pure-call ];
        };
        nativeBuildInputs = [ pkgs.nodejs_22 ];
        FENRIR_SOLO5 = "${solo5}";
        buildPhase = ''
          for abi in spt hvt; do
            node tools/solo5/freerun-pure-call.mjs --tc1 --build-only --abi $abi --out $out/tc1-$abi
            node tools/solo5/freerun-pure-call.mjs --exhaustive-nodes 4 --build-only --abi $abi --out $out/tc0-$abi
          done
          for b in tc1 tc0; do
            node -p 'JSON.parse(fs.readFileSync(process.argv[1])).count' $out/$b-spt/batch.json > $out/$b.count
            cmp $out/$b-spt/programs.json $out/$b-hvt/programs.json
          done
        '';
        dontInstall = true;
        dontFixup = true;
      };

      # Runs each batch under solo5-spt and solo5-hvt (needs /dev/kvm). Two checks:
      # the Shen harness compares each tender's guest with the Shen model, and the
      # frame streams of the two tenders are compared byte for byte in all three
      # guest modes. Tender banners are not frames and are dropped.
      harness-src = fs.toSource {
        root = ./.;
        fileset = fs.unions [ ./harness/common.shen ./harness/solo5-pure-call.shen ./models ];
      };
      hvt-compare = pkgs.writeShellApplication {
        name = "fenrir-hvt-compare";
        runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.diffutils ];
        text = ''
          test -r /dev/kvm -a -w /dev/kvm || { echo "fenrir-hvt-compare: /dev/kvm is not usable"; exit 2; }
          b=${solo5-batches}
          frames() { awk '/^FGRUN\/1 /{print; if ((getline line) > 0) print line}'; }
          work=$(mktemp -d)
          for batch in tc1 tc0; do
            for abi in spt hvt; do
              echo "== $batch under $abi against the Shen model"
              ${shen-jit}/bin/shen-jit script ${harness-src}/harness/solo5-pure-call.shen \
                ${shen-jit}/lib ${harness-src} $b/$batch-$abi < /dev/null | tail -n 1
            done
            count=$(cat $b/$batch.count)
            for mode in normal reverse-operands wrap-overflow; do
              first=0
              while [ "$first" -lt "$count" ]; do
                end=$((first + 250)); [ "$end" -le "$count" ] || end=$count
                ${solo5}/bin/solo5-spt --mem=32 $b/$batch-spt/guest.spt "$mode $first $end" | frames > "$work/spt"
                ${solo5}/bin/solo5-hvt --mem=32 $b/$batch-hvt/guest.hvt "$mode $first $end" | frames > "$work/hvt"
                test -s "$work/spt"
                cmp "$work/spt" "$work/hvt"
                first=$end
              done
            done
            echo "== $batch: $count programs, spt and hvt frames identical in normal, reverse-operands and wrap-overflow"
          done
          rm -rf "$work"
        '';
      };

      # NixOS VM with KVM passed through (-cpu host), so the hvt tender can run in it.
      # Needs KVM on the machine that builds the check; it cannot run under plain TCG.
      hvt-vm-test = pkgs.testers.runNixOSTest {
        name = "fenrir-hvt-vs-spt";
        nodes.machine = {
          virtualisation.memorySize = 2048;
          virtualisation.qemu.options = [ "-cpu host" ];
          boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
          environment.systemPackages = [ hvt-compare ];
        };
        testScript = ''
          machine.wait_for_unit("multi-user.target")
          machine.succeed("test -c /dev/kvm")
          print(machine.succeed("fenrir-hvt-compare 2>&1"))
        '';
      };

      # Erlang/OTP for the remote-perform supervisor (supervisor/, spec/tc1/EFFECTS.md §12).
      # The minimal build: no wx, so no GUI libraries in its closure. Nothing from hex or
      # rebar is used; harness/run-tc1-remote-run.sh compiles the sources with erlc.
      erlang = pkgs.beam_minimal.interpreters.erlang;

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
      packages.${system} = { inherit shen-scheme shen-cl shen-jit solo5 solo5-batches hvt-compare yggdrasil link-toolchain erlang; default = link-toolchain; };
      # Development only: the x86 gate and HVT comparison are not exported here.
      packages.aarch64-linux = { shen-jit = arm-shen-jit; solo5 = arm-solo5; };
      devShells.aarch64-linux.default = arm-pkgs.mkShell {
        packages = [ arm-pkgs.nodejs_22 arm-shen-jit arm-solo5 ];
        FENRIR_SHEN_JIT = "${arm-shen-jit}";
        FENRIR_SOLO5 = "${arm-solo5}";
      };
      checks.${system}.hvt = hvt-vm-test;
      apps.${system} = {
        default = { type = "app"; program = "${link-toolchain}/bin/fenrir-link-toolchain"; };
        hvt-compare = { type = "app"; program = "${hvt-compare}/bin/fenrir-hvt-compare"; };
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_22 pkgs.python3 pkgs.sbcl pkgs.go_1_27 shen-scheme yggdrasil erlang ];
        FENRIR_SHEN_CL = "${shen-cl}";
      };
    };
}
