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
  };

  outputs = { self, nixpkgs, shen-cl-src, yggdrasil-src }:
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
      packages.${system} = { inherit shen-scheme shen-cl yggdrasil link-toolchain; default = link-toolchain; };
      apps.${system}.default = { type = "app"; program = "${link-toolchain}/bin/fenrir-link-toolchain"; };
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_22 pkgs.python3 pkgs.sbcl pkgs.go_1_27 shen-scheme yggdrasil ];
        FENRIR_SHEN_CL = "${shen-cl}";
      };
    };
}
