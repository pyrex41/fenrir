# Evaluation only: nix eval --offline --impure --file tests/host/pinned-tools.nix
let
  flake = builtins.getFlake ("git+file://" + toString ../..);
  lib = flake.inputs.nixpkgs.lib;
  systems = [ "x86_64-linux" "aarch64-linux" ];
  checksFor = system:
    let
      pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
      exports = flake.packages.${system};
      otp = pkgs.beam_minimal.interpreters.erlang;
      a3Inputs = with pkgs; [
        beamPackages.erlang
        sqlite.out
        sqlite.dev
        sqlite.bin
        gcc
        nodejs_22
      ];
      erlang = exports.erlang;
      a3 = exports.fenrir-a3-tools;
    in {
      erlang =
        exports ? erlang
        && erlang.system == system
        && erlang.drvPath == otp.drvPath
        && lib.versions.major erlang.version == "28";
      fenrir-a3-tools =
        exports ? fenrir-a3-tools
        && a3.system == system
        && a3.name == "fenrir-a3-tools"
        && a3.pathsToLink == [ "/bin" "/lib" "/include" ]
        && map toString a3.paths == map toString a3Inputs
        && builtins.isString a3.drvPath;
    };
  failures = builtins.concatMap (system:
    let checks = checksFor system;
    in map (name: "packages.${system}.${name}")
      (builtins.filter (name: !checks.${name}) (builtins.attrNames checks))
  ) systems;
in
if failures == [ ] then
  builtins.listToAttrs (map (system: { name = system; value = checksFor system; }) systems)
else
  throw "Missing or incorrect pinned host tools: ${lib.concatStringsSep ", " failures}"
