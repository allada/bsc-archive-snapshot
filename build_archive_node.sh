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
# under the License.
set -euxo pipefail

# Directory of where this file lives.
SELF_DIR=$(dirname $0)

# This is the port number it will start with. Each geth instance will get a port
# number will incremented from this port number.
START_PORT_NUMBER=6340
# Base S3 bucket on where to download snapshots from.
S3_BUCKET_PATH="s3://public-blockchain-snapshots"

# Basic installs.
apt update
apt install -y awscli zfsutils-linux golang-go

# Creates a new pool with the default device.
DEVICES=( $(lsblk -o NAME,MODEL | grep NVMe | cut -d' ' -f 1) )
DEVICES_FULLNAME=()
for DEVICE in "${DEVICES[@]}"; do
  DEVICES_FULLNAME+=("/dev/$DEVICE")
done
zpool create -o ashift=12 tank "${DEVICES_FULLNAME[@]}"
# The root tank dataset does not get mounted.
zfs set mountpoint=none tank

# Configures ZFS to be slightly more optimal for our use case.
zfs set recordsize=32K tank
zfs set sync=disabled tank
zfs set redundant_metadata=most tank
zfs set atime=off tank
zfs set logbias=throughput tank

# Download, setup and install zstd v1.5.0.
zfs create -o mountpoint=/zstd tank/zstd
cd /zstd
aws s3 cp --request-payer=requester "$S3_BUCKET_PATH/support/zstd-v1.5.0-linux-x86.tar.gz" - | tar xzf -

# Download, setup and install bsc-geth.
zfs create -o mountpoint=/geth tank/geth
cd /geth
bash -c "aws s3 cp --request-payer=requester $S3_BUCKET_PATH/bsc-support/geth-v1.1.0-beta-linux-x86.tar.zstd - | /zstd/zstd -d | tar -xf -" &

ARCHIVE_NAMES=()

# Query S3 for all archives and download them in parallel to a new zfs dataset.
while IFS= read -r FILE_NAME; do
  ZFS_NAME=$(echo "$FILE_NAME" | cut -d'.' -f1)
  ARCHIVE_NAMES+=("$ZFS_NAME")
  zfs create -o "mountpoint=/$ZFS_NAME" "tank/$ZFS_NAME"
  bash -c "cd /$ZFS_NAME && aws s3 cp --request-payer=requester '$S3_BUCKET_PATH/bsc/$FILE_NAME' - | /zstd/zstd --long=30 -d | tar -xf -" &
done <<<"$(aws s3 ls --request-payer=requester "$S3_BUCKET_PATH/bsc/" | cut -d' ' -f4)"

# Block until all background processes finish.
wait

# Create geth user.
useradd geth

PORT=$START_PORT_NUMBER
WS_ENDPOINTS=()
# Loop through all snapshots and setup a new service.
for ARCHIVE_NAME in "${ARCHIVE_NAMES[@]}"; do
  chown -R geth "/$ARCHIVE_NAME"
  ENTRY_POINT="/geth/readonly.sh"
  # The latest snapshot has a special entry point, because it follows the chain.
  if [ "$ARCHIVE_NAME" == "latest" ]; then
    ENTRY_POINT="/geth/latest.sh"
  fi
  cat <<EOT > /etc/systemd/system/bsc-geth-archive-$ARCHIVE_NAME.service
[Unit]
Description=BSC Geth Service $ARCHIVE_NAME

[Service]
User=geth
WorkingDirectory=/$ARCHIVE_NAME
ExecStart=$ENTRY_POINT $PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOT

  systemctl daemon-reload
  systemctl enable "bsc-geth-archive-$ARCHIVE_NAME.service"
  systemctl start "bsc-geth-archive-$ARCHIVE_NAME.service"

  WS_ENDPOINTS+=("ws://127.0.0.1:$PORT")
  PORT="$((PORT+1))"
done

cat <<EOT > /etc/systemd/system/bsc-geth-ws-proxy.service
[Unit]
Description=BSC Geth Websocket Proxy

[Service]
User=geth
WorkingDirectory=$SELF_DIR
ExecStart=$SELF_DIR/ws_proxy.js ${WS_ENDPOINTS[@]}
Restart=always

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable "bsc-geth-ws-proxy.service"
systemctl start "bsc-geth-ws-proxy.service"
