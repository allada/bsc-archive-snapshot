#!/bin/bash
# Copyright 2021 Nathan (Blaise) Bruer
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.W
set -euxo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# If set to "1", will create a crontab entry to upload a snapshot daily.
# This requires write permission to `s3://public-blockchain-snapshots`.
# You may also set this through an environmental variable at startup.
# SHOULD_AUTO_UPLOAD_SNAPSHOT="0"

function safe_wait() {
  BACKGROUND_PIDS=( $(jobs -p) )
  for PID in "${BACKGROUND_PIDS[@]}"; do
    wait -f $PID
  done
}

function install_prereq() {
  set -euxo pipefail
  # Basic installs.
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y zfsutils-linux unzip pv clang-12 make jq python3-boto3 super
  # Use clang as our compiler by default if needed.
  ln -s $(which clang-12) /usr/bin/cc || true
  snap install --classic go

  if ! cargo --version 2>&1 >/dev/null ; then
    # Install cargo.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash /dev/stdin -y
    source "$HOME/.cargo/env"
  fi
}

function setup_drives() {
  set -euxo pipefail
  if zfs list tank ; then
    return # Our drives are probably already setup.
  fi
  # Creates a new pool with the default device.
  DEVICES=( $(lsblk --fs --json | jq -r '.blockdevices[] | select(.children == null and .fstype == null) | .name') )
  DEVICES_FULLNAME=()
  for DEVICE in "${DEVICES[@]}"; do
    DEVICES_FULLNAME+=("/dev/$DEVICE")
  done
  zpool create -o ashift=12 tank "${DEVICES_FULLNAME[@]}"
  # The root tank dataset does not get mounted.
  zfs set mountpoint=none tank

  # Configures ZFS to be slightly more optimal for our use case.
  zfs set compression=lz4 tank
  # Note: You might be able to get better erigon performance by changing this to 16k.
  zfs set recordsize=128k tank
  zfs set sync=disabled tank
  zfs set redundant_metadata=most tank
  zfs set atime=off tank
  zfs set logbias=throughput tank

  # By creating a swap it won't hurt much unless it's running on a small instance.
  # Under rare cases erigon might want to use an insane amount of ram (like if parlia database is
  # missing). This will allow us to at least get beyond that point. Measuring shows it only uses
  # about 48gb of ram when this happens. The vast majority of the time the swap will not be used.
  zfs create -s -V 48G -b $(getconf PAGESIZE) \
    -o compression=zle \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    tank/swap
  sleep 3 # It takes a moment for our zvol to be created.
  mkswap -f /dev/zvol/tank/swap
  swapon /dev/zvol/tank/swap

  # Set zfs's arc to 4GB. Erigon uses mmap() to map files into memory which is a cache system itself.
  echo 4147483648 > /sys/module/zfs/parameters/zfs_arc_max
}

function install_zstd() {
  set -euxo pipefail
  if pzstd --help ; then
    return # pzstd is already installed.
  fi
  # Download, setup and install zstd v1.5.2.
  # We use an upgraded version rather than what ubuntu uses because
  # 1.5.0+ greatly improved performance (3-5x faster for compression/decompression).
  mkdir -p /zstd
  cd /zstd
  wget -q -O- https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz | tar xzf -
  cd /zstd/zstd-1.5.2
  CC=clang-12 CXX=clang++-12 CFLAGS="-O3" make zstd -j$(nproc)
  ln -s /zstd/zstd-1.5.2/zstd /usr/bin/zstd || true
  cd /zstd/zstd-1.5.2/contrib/pzstd
  CC=clang-12 CXX=clang++-12 CFLAGS="-O3" make pzstd -j$(nproc)
  rm -rf /usr/bin/pzstd || true
  ln -s /zstd/zstd-1.5.2/contrib/pzstd/pzstd /usr/bin/pzstd
}

function install_aws_cli() {
  set -euxo pipefail
  if aws --version ; then
    return # Aws cli already installed.
  fi
  temp_dir=$(mktemp -d)
  cd $temp_dir
  curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  ./aws/install
  cd /
  rm -rf $temp_dir
  ln -s /usr/local/bin/aws /usr/bin/aws
}

function install_s3pcp() {
  set -euxo pipefail
  if s3pcp --help ; then
    return # putils already installed.
  fi

  temp_dir=$(mktemp -d)
  trap 'rm -rf $temp_dir' EXIT
  cd $temp_dir

  git clone https://github.com/allada/s3pcp.git
  cd $temp_dir/s3pcp
  make s3pcp
}

function install_putils() {
  set -euxo pipefail
  if psplit --help && pjoin --help ; then
    return # `putils` already installed.
  fi

  temp_dir=$(mktemp -d)
  trap 'rm -rf $temp_dir' EXIT
  cd $temp_dir

  git clone https://github.com/allada/putils.git
  cd $temp_dir/putils/psplit
  cargo build --release &
  cd $temp_dir/putils/pjoin
  cargo build --release &
  safe_wait
  mv $temp_dir/putils/psplit/target/release/psplit /usr/bin/psplit
  mv $temp_dir/putils/pjoin/target/release/pjoin /usr/bin/pjoin
}

function install_erigon() {
  set -euxo pipefail
  if erigon --help ; then
    return; # Erigon already installed.
  fi
  # Download, setup and install erigon.
  mkdir -p /erigon
  cd /erigon
  git clone https://github.com/ledgerwatch/erigon.git
  cd /erigon/erigon
  git checkout v2.28.1
  CC=clang-12 CXX=clang++-12 CFLAGS="-O3" make erigon
  ln -s /erigon/erigon/build/bin/erigon /usr/bin/erigon

  # Stop the service if it exists.
  systemctl stop erigon-bsc || true
}

function prepare_zfs_datasets() {
  set -euxo pipefail
  # Create datasets if needed.
  zfs create -o mountpoint=/erigon/data tank/erigon_data || true
  zfs create -o mountpoint=/erigon/data/bsc tank/erigon_data/bsc || true
}

function download_snapshots() {
  set -euxo pipefail
  if ! zfs list tank/erigon_data/bsc/snapshots ; then
    # Setup zfs dataset and download the latest erigon snapshots into it if needed.
    zfs create -o mountpoint=/erigon/data/bsc/snapshots tank/erigon_data/bsc/snapshots
  fi
  mkdir -p /erigon/data/bsc/snapshots/
  aws s3 sync \
      --request-payer requester \
      s3://public-blockchain-snapshots/bsc/erigon-snapshots-folder-latest/ \
      /erigon/data/bsc/snapshots/
}

# This is not strictly required, but it will make it much faster for a node to join the pool.
function download_nodes() {
  set -euxo pipefail
  if ! zfs list tank/erigon_data/bsc/nodes ; then
    zfs create -o mountpoint=/erigon/data/bsc/nodes tank/erigon_data/bsc/nodes
  fi
  # TODO(allada) Figure out a way to compress and decompress this. It has directories inside it
  # that refer to which protocol version it is using, so it's not easy to know if an upgrade
  # happens. The file is only about 1GB, so not a huge deal.
  aws s3 sync \
      --request-payer requester \
      s3://public-blockchain-snapshots/bsc/erigon-nodes-folder-latest/ \
      /erigon/data/bsc/nodes/ \
  || true # This command is allowed to fail since it's only an optimization.
}

# This is not strictly required, but it will make it much faster to start the Execution phase
# because it will be able to find a snapshot in the parlia database. If this fails it just means
# it'll have to traverse many blocks backwards which takes an insane amount of ram and time (usually
# a few hours).
function download_parlia() {
  set -euxo pipefail
  if ! zfs list tank/erigon_data/bsc/parlia ; then
    zfs create -o mountpoint=/erigon/data/bsc/parlia tank/erigon_data/bsc/parlia
  fi
  aws s3 cp \
      --request-payer requester \
      s3://public-blockchain-snapshots/bsc/parlia-db-latest.mdbx.zstd \
      - \
    | pzstd -d -f -o /erigon/data/bsc/parlia/mdbx.dat || true
}

# This complicated bit of code accomplishes 2 goals.
# 1. In the event that the current file being downloaded gets updated while a user is
#    downloading the file, this configuration will be pinned to a specific version,
#    so it won't get interrupted in the middle of the download unless it takes over
#    ~24 hours.
# 2. Downloads many parts at a time and runs a parallelized decompressor. This is
#    about 3-4x faster than using normal `aws s3 cp` + `zstd -d`.
function download_database_file() {
  set -euxo pipefail
  if zfs list tank/erigon_data/bsc/chaindata ; then
    return # Already have chaindata.
  fi
  zfs create -o mountpoint=/erigon/data/bsc/chaindata tank/erigon_data/bsc/chaindata

  s3pcp --requester-pays s3://public-blockchain-snapshots/bsc/erigon-16k-db-latest.mdbx.zstd \
    | pv \
    | pzstd -p $(nproc) -q -d -f -o /erigon/data/bsc/chaindata/mdbx.dat
}

function prepare_erigon() {
  set -euxo pipefail
  # Create erigon user if needed.
  useradd erigon || true

  chown -R erigon:erigon /erigon/data/

  # Stop the service if it exists.
  systemctl stop erigon-bsc || true

  echo '[Unit]
Description=Erigon BSC daemon
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=1
User=erigon
ExecStart=/erigon/start_erigon_service.sh

[Install]
WantedBy=multi-user.target
' > /etc/systemd/system/erigon-bsc.service

  echo '#!/bin/bash' > /erigon/start_erigon_service.sh
  if [[ "${SHOULD_AUTO_UPLOAD_SNAPSHOT:-}" == "1" ]]; then
    # Run erigon in a subshell but append the subshell's process id to first stdout.
    # Also give special environ that tells erigon to stop processing new blocks after Finish stage.
    echo -n "sh -c '>&2 echo \$\$; STOP_AFTER_STAGE=Finish " >> /erigon/start_erigon_service.sh
  fi

  echo -n "exec erigon --chain bsc --snapshots=true --db.pagesize=16k --datadir=/erigon/data/bsc --txpool.disable" >> /erigon/start_erigon_service.sh

  if [[ "${SHOULD_AUTO_UPLOAD_SNAPSHOT:-}" == "1" ]]; then
    # Create a subshell that will get the process id of the erigon and forward stdout as it comes in
    # but if it has the magic string 'STOP_AFTER_STAGE env flag forced to stop app' it will shutdown
    # erigon and start a snapshot.
    # Sadly erigon does not properly shutdown everything when the flag is set, it only stops
    # processing new blocks.
    echo "' 2> >(PARENT_PID=\$(head -1); while read -r line; do echo >&2 \"\$line\"; if [[ \"\$line\" == *'STOP_AFTER_STAGE env flag forced to stop app'* ]]; then kill \$PARENT_PID || true; fi done)" >> /erigon/start_erigon_service.sh
    echo 'super create-bsc-snapshot-and-shutdown' >> /erigon/start_erigon_service.sh
  fi

  chmod +x /erigon/start_erigon_service.sh

  systemctl daemon-reload
  systemctl enable erigon-bsc
}

function run_erigon() {
  set -euxo pipefail
  systemctl start erigon-bsc
}

function add_create_snapshot_script() {
  set -euxo pipefail
  # Create script that can be used to upload a snapshot quickly.
  cat <<'EOT' > /erigon/create-bsc-snapshot-and-shutdown.sh
#!/bin/bash
set -ex

export PATH="$PATH:/usr/sbin"

# Once the snapshot is created shutdown our node.
# A cronjob should start up the node again.
trap 'shutdown now' EXIT

function upload_mdbx_file() {
  upload_id=$(aws s3api create-multipart-upload \
      --bucket public-blockchain-snapshots \
      --key bsc/erigon-16k-db-latest.mdbx.zstd \
      --request-payer requester \
    | jq -r ".UploadId")

  bytes_per_chunk=$(( 1024 * 1024 * 512 )) # 500mib.

  avail_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  # Reduce the theoretical size by about 60% because there are 2 copies in memory at all times.
  parallel_downloads=$(( avail_mem_kb * 1000 / bytes_per_chunk * 10 / 25 ))
  num_cores=$(nproc)
  # We want more than the number of cores but not by a lot.
  max_parallel_downloads=$(echo "x = ($num_cores + 5) * 1.5; scale=0; x / 1" | bc -l)
  if [ $parallel_downloads -gt $max_parallel_downloads ]; then
    parallel_downloads=$max_parallel_downloads
  fi

  mkdir -p /erigon_upload_tmp
  mount -t tmpfs -o rw,size=$(( parallel_downloads * bytes_per_chunk + 1024 * 1024 )) tmpfs /erigon_upload_tmp
  trap "umount /erigon_upload_tmp" EXIT
  mkdir -p /erigon_upload_tmp/working_stdout
  mkdir -p /erigon_upload_tmp/upload_part_results

  # Sadly s3api/boto3 does not support streaming file descriptors. This means we need to write
  # our entire chunk to a file then upload that file. This probably isn't a big deal since the
  # data is in memory anyway
  pzstd \
      -p $parallel_downloads \
      -3 \
      -v \
      --stdout \
      /erigon/data/bsc/chaindata/mdbx.dat \
    | psplit \
      -b $bytes_per_chunk \
      "bash -euo pipefail -c ' \
         SEQ=\$(( \$SEQ + 1 )) && \
         md5_value=\$(tee /erigon_upload_tmp/working_stdout/\$(printf %05d \$SEQ) | md5sum | cut -c -32) && \
         trap \"rm -rf /erigon_upload_tmp/working_stdout/\$(printf %05d \$SEQ)\" EXIT && \
         etag_result=\$(aws s3api upload-part \
            --body /erigon_upload_tmp/working_stdout/\$(printf %05d \$SEQ) \
            --request-payer requester \
            --bucket public-blockchain-snapshots \
            --key bsc/erigon-16k-db-latest.mdbx.zstd \
            --upload-id $upload_id \
            --part-number \$SEQ \
        | jq -r .ETag | tr -d \\\" | tee > /erigon_upload_tmp/upload_part_results/\$(printf %05d \$SEQ)') && \
        if [ \$md5_value -ne \$etag_result ]; then echo \"md5 did not match \$md5_value -ne \$etag_result\" >&2 ; exit 1; fi"

  # Sadly `aws s3api complete-multipart-upload` requires the `multipart-upload` field be sent as an
  # argument which is too large to send over an argument, so we use a short python script to finish.
  python3 -c "
import boto3, os
part_nums=os.listdir('/erigon_upload_tmp/upload_part_results/')
part_nums.sort()
boto3.client('s3').complete_multipart_upload(
    Bucket='public-blockchain-snapshots',
    Key='bsc/erigon-16k-db-latest.mdbx.zstd',
    UploadId='$upload_id',
    RequestPayer='requester',
    MultipartUpload={
        'Parts': [{'PartNumber': int(name), 'ETag': open('/erigon_upload_tmp/upload_part_results/' + name).readline().strip()} for name in part_nums]
    }
)"
}

zfs set readonly=on tank/erigon_data/bsc/snapshots
aws s3 sync /erigon/data/bsc/snapshots s3://public-blockchain-snapshots/bsc/erigon-snapshots-folder-latest/ &

zfs set readonly=on tank/erigon_data/bsc/nodes
aws s3 sync /erigon/data/bsc/nodes s3://public-blockchain-snapshots/bsc/erigon-nodes-folder-latest/ &

zfs set readonly=on tank/erigon_data/bsc/parlia
pzstd -1 /erigon/data/bsc/parlia/mdbx.dat --stdout \
  | aws s3 cp - s3://public-blockchain-snapshots/bsc/parlia-db-latest.mdbx.zstd &

zfs set readonly=on tank/erigon_data/bsc/chaindata
upload_mdbx_file &

# If one of the background tasks has a bad exit code it's ok.
wait # Wait for all background tasks to finish.
EOT
  chmod 0744 /erigon/create-bsc-snapshot-and-shutdown.sh
  chown root:root /erigon/create-bsc-snapshot-and-shutdown.sh

  echo "create-bsc-snapshot-and-shutdown     /erigon/create-bsc-snapshot-and-shutdown.sh uid=root erigon" >> /etc/super.tab
}

install_prereq
setup_drives

# These installations can happen in parallel.
install_zstd &

install_aws_cli &
install_s3pcp &
install_putils &
install_erigon &
safe_wait # Wait for our parallel jobs finish.

prepare_zfs_datasets

download_snapshots & # Download just the snapshots folder.
download_nodes & # Downloads the last known list of nodes.
download_parlia & # Downloads the last known parlia snapshots.
download_database_file & # Download the database file. This is the bulk of the downloads.
safe_wait # Wait for download_snapshot to finish.

prepare_erigon
run_erigon
add_create_snapshot_script
