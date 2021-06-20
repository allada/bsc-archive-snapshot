// Copyright 2021 Nathan (Blaise) Bruer
//
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
const process = require('process');

const ethers = require('ethers');
const WebSocket = require('ws');

// This script assumes all arguments provided at startup are to a websocket
// service that is backed by geth. For example:
//   nodejs ./ws_proxy.js ws://127.0.0.1:1234 ws://127.0.0.1:1235
// This will cause the script to first connect to each geth instance
// then find what available blocks are on each one of the geth instances.
// It will then create a new websocket service on `LISTEN_PORT_NUMBER` and
// route requests to the different geth-backends based on the `blockTag` sent
// (if present); all requests that don't specify a specific block will use
// service with the latest block.
//
// NOTE: This script is only a proof-of-concept. If you plan on using it in a
// production environment I highly recommend to do your own testing and
// implement any features that might be missing. However, please feel free
// to open a pull request to this repo if you fix bugs or provide features that
// users might want.

// Port number has no special meaning, was randomly chosen.
const LISTEN_PORT_NUMBER = 13714;

// Interval to ping (ie: timeout) in milliseconds.
const PING_INTERVAL_MS = 30000;

// Each argument provided should be a URI to a geth websocket service.
// Note: We take the first two items off because they are `node` and
// `./ws_proxy.js`.
const endPoints = Array.from(process.argv).slice(2);

// Providers that are going to be used to route requests. This will be filled
// later in the script.
// Note: This list should always be sorted from lowest available block number
// to greatest.
let providers = [];

// Symbols used to attach/reference available block numbers onto providers.
const startBlockSymbol = Symbol('StartBlock');
const endBlockSymbol = Symbol('EndBlock');

// Returns the provider for a given block number. If `blockNumber` is falsy it
// will return the provider that has the most recent blocks.
// This function is log(providers.length) in complexity.
function providerForBlock(blockNumber) {
  if (!blockNumber) {
    return providers[providers.length - 1];
  }
  let left = 0;
  let right = providers.length - 1;
  while (left <= right) {
    const mid = Math.floor((right + left) / 2);
    if (providers[mid][startBlockSymbol] > blockNumber) {
      right = mid - 1;
      continue;
    }
    if (providers[mid][endBlockSymbol] < blockNumber) {
      left = mid + 1;
      continue;
    }
    return providers[mid];
  }
  throw new Exception("Block not found in any providers: " + blockNumber);
}

// Bisects the provider to sniff out what blocks are available on it.
// This is done by trying to get the balance on a known address and if it throws
// bisects to a new address.
// This function is log(N) in complexity.
// Note: This assumes each provider has no gaps on archive data and last block
// is always present.
async function getBlockRangeOfProvider(provider) {
  // This is a TokenHub address that was present at the genesis block.
  const KNOWN_ADDRESS = '0x0000000000000000000000000000000000001004';
  const lastBlock = await provider.getBlockNumber();
  let left = 0;
  let right = lastBlock;
  while (left <= right) {
    const mid = Math.floor((right + left) / 2);
    try {
      await provider.getBalance(KNOWN_ADDRESS, mid);
      // If we didn't throw it means we have the block.
      right = mid - 1;
    } catch (e) {
      // If we throw we don't have that block.
      left = mid + 1;
    }
  }
  return [left, lastBlock];
}

const isAliveSymbol = Symbol('IsAlive');

async function main() {
  // Query all providers for available block numbers and create the available
  // providers.
  providers = await Promise.all(endPoints.map(async (endPoint) => {
    const provider = new ethers.providers.WebSocketProvider(endPoint);
    const [startBlock, endBlock] = await getBlockRangeOfProvider(provider);
    provider[startBlockSymbol] = startBlock;
    provider[endBlockSymbol] = endBlock;
    return provider;
  }));
  // Ensure they are always sorted.
  providers.sort((a, b) => a[startBlockSymbol] - b[startBlockSymbol]);

  const wss = new WebSocket.Server({ port: LISTEN_PORT_NUMBER });

  wss.on('connection', function connection(ws) {
    ws[isAliveSymbol] = true;
    ws.on('pong', () => ws[isAliveSymbol] = true);

    async function handleMessage(message) {
      const jsonData = JSON.parse(message);
      // console.log('Request', jsonData);
      let blockTag = null;  // Latest.
      switch (jsonData.method) {
        case 'eth_chainId':
          ws.send(JSON.stringify({
            id: jsonData.id,
            jsonrpc: "2.0",
            result: "0x38" // 56 (BSC chain number)
          }));
          return;
        // The following calls have the last parameter as the 'blockTag' in hex
        // form which we need to figure out what instance to route the request
        // to.
        case 'eth_getBalance':
        case 'eth_getCode':
        case 'eth_getTransactionCount':
        case 'eth_getStorageAt':
        case 'eth_call':
        case 'eth_getTransactionCount':
        case 'eth_estimateGas':
          blockTag = jsonData.params[jsonData.params.length - 1];
          if (blockTag === 'latest') {
            blockTag = null;
            break;
          }
          if (!blockTag.startsWith('0x')) {
            throw new Exception('Expected blockTag to start with 0x');
          }
          blockTag = parseInt(blockTag, 16);
          break;
      }
      // Find provider, forward request and relay response.
      const provider = providerForBlock(blockTag);
      const response = await provider.send(jsonData.method, jsonData.params);
      const fullResponse = {
        id: jsonData.id,
        jsonrpc: "2.0",
        result: response,
      };
      ws.send(JSON.stringify(fullResponse));
    }

    ws.on('message', (message) => handleMessage(message).catch(console.log));
  });

  // TODO(allada) Might be a good idea here to randomize this a bit, otherwise
  // if you had a lot of clients connected at once, they are all going to send
  // a pong back at the same time, which might cause needless load.
  const pingInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws[isAliveSymbol] === false) {
        ws.terminate();
        return;
      }

      ws[isAliveSymbol] = false;
      ws.ping(() => {}); // No need to handle response.
    });
  }, PING_INTERVAL_MS);

  wss.on('close', () => clearInterval(pingInterval));
  console.log('Ready');
}

main();
