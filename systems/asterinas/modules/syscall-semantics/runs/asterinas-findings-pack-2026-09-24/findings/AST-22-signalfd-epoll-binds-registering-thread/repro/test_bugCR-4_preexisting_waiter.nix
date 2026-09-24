{ pkgs ? import <nixpkgs> { } }:

let
  sourceRoot = /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/worktree;

  test = pkgs.stdenv.mkDerivation {
    pname = "test-bugCR-4-preexisting-waiter";
    version = "1";
    dontUnpack = true;
    buildInputs = [ pkgs.glibc pkgs.glibc.static ];
    buildPhase = ''
      $CC -std=c11 -O2 -Wall -Wextra -Werror -pthread -static \
        ${./test_bugCR-4_preexisting_waiter.c} \
        -o test_bugCR-4_preexisting_waiter
    '';
    installPhase = ''
      install -Dm755 test_bugCR-4_preexisting_waiter \
        $out/test_bugCR-4_preexisting_waiter
    '';
  };

  initramfs = pkgs.callPackage "${sourceRoot}/test/initramfs/nix/initramfs.nix" {
    benchmark = null;
    conformance = null;
    regression = null;
    specula = test;
    dnsServer = "none";
  };
in
pkgs.runCommand "test_bugCR-4_preexisting_waiter.cpio" {
  nativeBuildInputs = [ pkgs.cpio ];
} ''
  cd ${initramfs}
  find . -print0 | cpio --quiet --null -o -H newc --owner=0:0 > "$out"
''
