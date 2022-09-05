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

# Basic installs.
apt update
DEBIAN_FRONTEND=noninteractive apt install -y awscli zfsutils-linux golang-go pv docker docker-compose clang-12 make jq

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
zfs set recordsize=32K tank
zfs set sync=disabled tank
zfs set redundant_metadata=most tank
zfs set atime=off tank
zfs set logbias=throughput tank

# Download, setup and install zstd v1.5.2.
# We use an upgraded version rather than what ubuntu uses because
# 1.5.0+ greatly improved performance (3-5x faster for compression/decompression).
zfs create -o mountpoint=/zstd tank/zstd
cd /zstd
wget -q -O- https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz | tar xzf -
cd /zstd/zstd-1.5.2
CC=clang-12 CXX=clang++-12 CFLAGS="-O3" make zstd -j$(nproc)
ln -s /zstd/zstd-1.5.2/zstd /zstd/zstd

# Download, setup and install bsc-geth.
zfs create -o mountpoint=/erigon tank/erigon
cd /erigon
git clone https://github.com/ledgerwatch/erigon.git
cd /erigon/erigon
git checkout v2022.07.03
sed -i 's/user: 472:0/user: ${DOCKER_UID:-1000}:${DOCKER_GID:-1000}/g' docker-compose.yml

# Setup zfs dataset and download the latest erigon snapshot into it.
zfs create -o mountpoint=/erigon/data/erigon tank/erigon_data
mkdir -p /erigon/data/erigon/chaindata/
mkdir -p /erigon/data/erigon/parlia/
cd /erigon/data/erigon
aws s3 sync --request-payer=requester --quiet s3://public-blockchain-snapshots/bsc/erigon-snapshots-folder-latest/ /erigon/data/erigon/snapshots/ &
sync_pid="$!"
aws s3 cp --request-payer=requester "s3://public-blockchain-snapshots/bsc/erigon-16k-db-latest.mdbx.zstd" - | pv | /zstd/zstd --long=31 -d > /erigon/data/erigon/chaindata/mdbx.dat
aws s3 cp --request-payer=requester "s3://public-blockchain-snapshots/bsc/parlia-db-latest.mdbx.zstd" - | pv | /zstd/zstd --long=31 -d > /erigon/data/erigon/parlia/mdbx.dat

wait "$sync_pid" # Wait for sync process to finish.

# Set zfs's arc to 2GB. Erigon uses it's own cache system, so no need for zfs's.
echo 2073741824 > /sys/module/zfs/parameters/zfs_arc_max

# Move docker files to a zvol. This is not required, but I (allada@)
# uses small EBS volumes with large NVMe volumes. In addition docker
# performs very poorly when using native zfs volumes, so we use
# zvol + ext4 which gives better performance and less errors.
service docker stop
rm -rf /var/lib/docker
zfs create -V 50G tank/docker
# Sadly this is the best that I know of to prevent mkfs from erroring due to the above
# command not finishing some background stuff.
sleep 5
mkfs.ext4 /dev/zvol/tank/docker
mkdir /var/lib/docker
mount /dev/zvol/tank/docker /var/lib/docker
service docker start

# Create erigon user.
useradd erigon

cd /erigon/erigon

# There are some permission issues with root owning files that docker-compose uses,
# this is a simple hack to just make it work. In a production system these should
# be more constrained to how you have the permissions setup.
mkdir /erigon/data/erigon-grafana
mkdir /erigon/data/erigon-prometheus
chmod -R 777 /erigon/data/ # WARNING: Unsafe, but easiest way to get it working.
chown -R erigon:erigon /erigon/data/

# This starts the erigon services.
# You may follow the stdout/stderr of erigon services with:
# sudo docker-compose logs -f
# Note: These snapshots use a 16k page size. This cannot be easily changed without a resync.
ERIGON_FLAGS="--chain bsc --snapshots=true --db.pagesize=16k" \
  DOCKER_UID=$(id -u erigon) \
  DOCKER_GID=$(id -g erigon) \
  XDG_DATA_HOME=/erigon/data \
  DOCKER_BUILDKIT=1 \
  COMPOSE_DOCKER_CLI_BUILD=1 \
  docker-compose up -d

# Create script that can be used to upload a snapshot quickly.
cat <<'EOT' > /home/ubuntu/create-bsc-snapshot.sh
set -ex
# Just in case delete clone (if exists).
zfs destroy tank/erigon_upload || true
zfs destroy tank/erigon_data@snap || true

# First stop erigon and take a snapshot of drive.
cd /erigon/erigon
docker-compose stop
zfs snap tank/erigon_data@snap
docker-compose start

# Clone drive and upload clone data and then delete clone
zfs clone -o mountpoint=/erigon_upload tank/erigon_data@snap tank/erigon_upload
cd /erigon_upload
/zstd/zstd ./chaindata/mdbx.dat --auto-threads=logical -T0 -6 -v --long=31 --stdout | aws s3 cp - s3://public-blockchain-snapshots/bsc/erigon-16k-db-latest.mdbx.zstd --expected-size 4900000000000 &
db_send_pid="$!"
aws s3 sync ./snapshots s3://public-blockchain-snapshots/bsc/erigon-snapshots-folder-latest/
wait "$db_send_pid" # Wait for the mdbx database to finish uploading.
cd /
zfs destroy tank/erigon_upload
zfs destroy tank/erigon_data@snap
EOT

# If we are configured to auto upload a snapshot configure crontab.
if [[ "${SHOULD_AUTO_UPLOAD_SNAPSHOT:-}" == "1" ]]; then
  echo '@daily root /home/ubuntu/create-bsc-snapshot.sh' >> /etc/crontab
  chmod +x /home/ubuntu/create-bsc-snapshot.sh
  service cron reload
fi
