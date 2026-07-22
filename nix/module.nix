{ source }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.modern-fs-benchmark;

  benchmark = import ./benchmark-package.nix {
    inherit pkgs source;
    zfsPackage = cfg.zfsPackage;
  };
  benchmarkPackages = benchmark.runtimeInputs;

  allowedConfigurations = [
    "ext4/single"
    "ext4/md-raid10"
    "ext4/lvm-raid10"
    "ext4/md-raid6"
    "ext4/md-raid10-luks"
    "xfs/single"
    "xfs/md-raid10"
    "xfs/lvm-raid10"
    "xfs/zvol"
    "xfs/lvm-raid10-int"
    "btrfs/raid1"
    "btrfs/raid6"
    "btrfs/single"
    "btrfs/raid1-luks"
    "zfs/mirror"
    "zfs/mirror-8k"
    "zfs/single"
    "zfs/raidz1"
    "zfs/raidz2"
    "zfs/raidz1-enc"
    "zfs/raidz2-enc"
    "zfs/mirror-enc"
    "bcachefs/replicas2"
    "bcachefs/single"
    "bcachefs/ec"
    "bcachefs/replicas2-enc"
  ];

  runBenchmark = pkgs.writeShellApplication {
    name = "modern-fs-benchmark-run";
    runtimeInputs = benchmarkPackages;
    text = ''
      if [[ $# -eq 1 && $1 == --capabilities ]]; then
        printf '%s\n' hardware-random-scaling-v1 hardware-random-scaling-v2
        exit 0
      fi

      if [[ $# -ne 10 ]]; then
        echo "usage: modern-fs-benchmark-run <run-id> <attempt> <fs> <layout> <dev-size> <aging-iters> <aging-io> <snap-count> <min-seq-mbps> <min-rand-iops>" >&2
        exit 2
      fi

      run_id=$1
      attempt=$2
      fs=$3
      layout=$4
      dev_size=$5
      aging_iters=$6
      aging_io=$7
      snap_count=$8
      min_seq_mbps=$9
      min_rand_iops=''${10}
      configuration="$fs/$layout"

      if [[ ! $run_id =~ ^[0-9]+$ || ! $attempt =~ ^[0-9]+$ ]]; then
        echo "run ID and attempt must be numeric" >&2
        exit 2
      fi

      case "$configuration" in
        ${lib.concatStringsSep " | " allowedConfigurations}) ;;
        *)
          echo "unsupported benchmark configuration: $configuration" >&2
          exit 2
          ;;
      esac

      if [[ ! $dev_size =~ ^[1-9][0-9]*[KMGT]?$ || ! $aging_io =~ ^[1-9][0-9]*[KMGT]?$ ]]; then
        echo "device and aging sizes must use fio size syntax" >&2
        exit 2
      fi
      for value in "$aging_iters" "$snap_count" "$min_seq_mbps" "$min_rand_iops"; do
        if [[ ! $value =~ ^[0-9]+$ ]]; then
          echo "benchmark counts and calibration floors must be numeric" >&2
          exit 2
        fi
      done

      expected_dev_size=16G
      expected_aging_iters=100
      case "$configuration" in
        ext4/lvm-raid10 | xfs/lvm-raid10 | xfs/lvm-raid10-int)
          expected_aging_iters=8
          ;;
        xfs/zvol)
          expected_aging_iters=25
          ;;
        zfs/single)
          expected_dev_size=32G
          expected_aging_iters=10
          ;;
        zfs/mirror-8k)
          ;;
        zfs/*)
          expected_aging_iters=10
          ;;
      esac
      if [[ $dev_size != "$expected_dev_size" || $aging_iters != "$expected_aging_iters" \
            || $aging_io != 64M || $snap_count != 500 \
            || $min_seq_mbps != 300 || $min_rand_iops != 8000 ]]; then
        echo "benchmark settings do not match the reviewed workflow matrix" >&2
        exit 2
      fi

      exec 9>/run/lock/modern-fs-benchmark.lock
      if ! flock -n 9; then
        echo "another filesystem benchmark is already running" >&2
        exit 75
      fi

      require_size() {
        local device=$1 expected=$2 actual
        if [[ ! -b $device ]]; then
          echo "$device is not a block device" >&2
          exit 2
        fi
        actual=$(blockdev --getsize64 "$device")
        if [[ $actual -ne $expected ]]; then
          echo "$device has size $actual bytes; expected $expected" >&2
          exit 2
        fi
      }

      device_identities=
      for device in ${lib.escapeShellArgs (cfg.devices ++ [ cfg.spareDevice cfg.zfsSingleDevice ])}; do
        identity=$(stat -Lc '%t:%T' -- "$device")
        case " $device_identities " in
          *" $identity "*)
            echo "$device resolves to a duplicate block device" >&2
            exit 2
            ;;
        esac
        device_identities+=" $identity"
      done

      for device in ${lib.escapeShellArgs (cfg.devices ++ [ cfg.spareDevice ])}; do
        require_size "$device" 17179869184
      done
      require_size ${lib.escapeShellArg cfg.zfsSingleDevice} 34359738368

      results_dir="/var/lib/modern-fs-benchmark/results/$run_id-$attempt/$fs-$layout"
      install -d -m 0755 /var/lib/modern-fs-benchmark/results
      rm -rf -- "$results_dir"
      install -d -m 0755 "$results_dir"

      export BENCH_DEVICES=${lib.escapeShellArg (lib.concatStringsSep " " cfg.devices)}
      export BENCH_SPARE_DEVICE=${lib.escapeShellArg cfg.spareDevice}
      export BENCH_ZFS_SINGLE_DEVICE=${lib.escapeShellArg cfg.zfsSingleDevice}
      export BENCH_WIPE=1
      export DEV_SIZE="$dev_size"
      export AGING_ITERS="$aging_iters"
      export AGING_IO="$aging_io"
      export SNAPSCALE_COUNT="$snap_count"
      export CALIB_MIN_SEQ_MBPS="$min_seq_mbps"
      export CALIB_MIN_RAND_IOPS="$min_rand_iops"
      export BENCH_HARDWARE_RANDOM_SCALING=1
      export RESULTS_DIR="$results_dir"

      ${benchmark.package}/bin/modern-fs-benchmark "$fs" "$layout"
    '';
  };
in
{
  options.services.modern-fs-benchmark = {
    enable = lib.mkEnableOption "the modern filesystem benchmark runner";

    repository = lib.mkOption {
      type = lib.types.str;
      description = "GitHub repository whose Actions jobs this runner accepts.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a GitHub runner PAT or registration token.";
    };

    runnerName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Name shown for the self-hosted GitHub runner.";
    };

    runnerLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "fs-benchmark" ];
      description = "Labels used to route benchmark jobs to this runner.";
    };

    runnerGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional GitHub organization runner group restricted to trusted repositories.";
    };

    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Re-register a clean runner after every job; requires a PAT in tokenFile.";
    };

    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Four disposable block devices used as array members.";
    };

    spareDevice = lib.mkOption {
      type = lib.types.str;
      description = "Disposable block device used as the rebuild target.";
    };

    zfsSingleDevice = lib.mkOption {
      type = lib.types.str;
      description = "Dedicated 32 GiB block device used by zfs/single.";
    };

    enableBcachefs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Build and load bcachefs for the cluster-selected kernel.";
    };

    enableZfs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable ZFS support for the cluster-selected kernel.";
    };

    zfsPackage = lib.mkOption {
      type = lib.types.package;
      default = config.boot.zfs.package;
      defaultText = lib.literalExpression "config.boot.zfs.package";
      description = "Cluster-selected ZFS package exposed to benchmark jobs.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.devices == 4;
        message = "services.modern-fs-benchmark.devices must contain exactly four devices";
      }
      {
        assertion = cfg.spareDevice != "";
        message = "services.modern-fs-benchmark.spareDevice must not be empty";
      }
      {
        assertion = builtins.length (lib.unique (cfg.devices ++ [ cfg.spareDevice cfg.zfsSingleDevice ])) == 6;
        message = "services.modern-fs-benchmark devices, spareDevice, and zfsSingleDevice must be distinct";
      }
    ];

    boot.extraModulePackages =
      lib.optional cfg.enableBcachefs config.boot.kernelPackages.bcachefs
      ++ lib.optional cfg.enableZfs config.boot.zfs.modulePackage;
    boot.kernelModules =
      [ "dm_raid" "dm_snapshot" "dm_integrity" ]
      ++ lib.optional cfg.enableBcachefs "bcachefs"
      ++ lib.optional cfg.enableZfs "zfs";
    services.udev.packages = lib.optional cfg.enableZfs cfg.zfsPackage;
    users.groups.modern-fs-benchmark = { };
    users.users.modern-fs-benchmark = {
      isSystemUser = true;
      group = "modern-fs-benchmark";
    };

    security.sudo.extraRules = [
      {
        users = [ "modern-fs-benchmark" ];
        commands = [
          {
            command = "${runBenchmark}/bin/modern-fs-benchmark-run";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    services.github-runners.modern-fs-benchmark = {
      enable = true;
      url = cfg.repository;
      tokenFile = cfg.tokenFile;
      name = cfg.runnerName;
      replace = true;
      extraLabels = cfg.runnerLabels;
      runnerGroup = cfg.runnerGroup;
      ephemeral = cfg.ephemeral;
      user = "modern-fs-benchmark";
      group = "modern-fs-benchmark";
      extraPackages = benchmarkPackages ++ [ runBenchmark ];
      serviceOverrides = {
        AmbientCapabilities = lib.mkForce null;
        CapabilityBoundingSet = lib.mkForce null;
        DeviceAllow = lib.mkForce null;
        NoNewPrivileges = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        PrivateMounts = lib.mkForce false;
        PrivateTmp = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
        ProtectClock = lib.mkForce false;
        ProtectControlGroups = lib.mkForce false;
        ProtectHome = lib.mkForce false;
        ProtectHostname = lib.mkForce false;
        ProtectKernelLogs = lib.mkForce false;
        ProtectKernelModules = lib.mkForce false;
        ProtectKernelTunables = lib.mkForce false;
        ProtectProc = lib.mkForce "default";
        ProtectSystem = lib.mkForce false;
        RemoveIPC = lib.mkForce false;
        RestrictAddressFamilies = lib.mkForce null;
        RestrictNamespaces = lib.mkForce false;
        RestrictSUIDSGID = lib.mkForce false;
        SystemCallFilter = lib.mkForce null;
        UMask = lib.mkForce "0022";
      };
    };
  };
}
