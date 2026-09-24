{ sourceRepo ? /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree }:
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c0bebd16e69e631ac6e52d6eb439daba28ac50cd.tar.gz";
    sha256 = "1fbhkqm8cnsxszw4d4g0402vwsi75yazxkpfx3rdvln4n6s68saf";
  };
  pkgs = import nixpkgs {
    crossSystem.config = "x86_64-unknown-linux-gnu";
  };
  mc5Test = pkgs.stdenv.mkDerivation {
    pname = "mc5-exact-counterexample";
    version = "1";
    src = ./.;
    dontConfigure = true;
    buildPhase = ''
      ${pkgs.stdenv.cc.targetPrefix}cc -O2 -Wall -Werror -no-pie \
        test_bugMC-5_exact_counterexample.c \
        -o test_bugMC-5-exact-counterexample
    '';
    installPhase = ''
      mkdir -p "$out/io/mc5"
      install -m 0755 test_bugMC-5-exact-counterexample \
        "$out/io/mc5/test_bugMC-5-exact-counterexample"
    '';
  };
  initramfs = pkgs.callPackage "${sourceRepo}/test/initramfs/nix/initramfs.nix" {
    busybox = pkgs.busybox;
    benchmark = null;
    conformance = null;
    regression = null;
    specula = mc5Test;
    dnsServer = "none";
  };
in pkgs.callPackage "${sourceRepo}/test/initramfs/nix/initramfs-image.nix" {
  inherit initramfs;
  compressed = false;
}
