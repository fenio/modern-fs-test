{ pkgs, source, zfsPackage ? pkgs.zfs }:

let
  zvolId = pkgs.writeShellScriptBin "zvol_id" ''
    exec ${zfsPackage}/lib/udev/zvol_id "$@"
  '';

  runtimeInputs = (with pkgs; [
    bash
    bc
    bcachefs-tools
    btrfs-progs
    compsize
    coreutils
    cryptsetup
    diffutils
    e2fsprogs
    findutils
    fio
    gawk
    git
    gnugrep
    gnutar
    gzip
    jq
    keyutils
    kmod
    lvm2
    mdadm
    procps
    python3
    systemd
    util-linux
    xfsprogs
    zfsPackage
  ]) ++ [ zvolId ];

  package = pkgs.writeShellApplication {
    name = "modern-fs-benchmark";
    inherit runtimeInputs;
    text = ''
      exec ${source}/scripts/run-bench.sh "$@"
    '';
  };
in
{
  inherit package runtimeInputs;
}
