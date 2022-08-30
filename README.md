## UPDATE
There has been enough demand for an ethereum snapshot to be hosted that I have decided to start maintaining one here: https://github.com/allada/eth-archive-snapshot

# BSC Archive Node Snapshot Tools
This repository holds the tools and commands that can be used to deploy your own BSC Archive node by downloading pre-built snapshots and installing them on an instance.

Please consider donating especially if you are using this project to make money. I am considering changing
the license from Apache (extremely permissive) to something that requires a license (ie: fee) if you derive
money from it. I would like to avoid this at all costs though!

You can support me in this kind of public work by donating to:
`0xd6A6Da9F5622FcB3C9745a4DDA5DcCa75d92a1F0`
Prefer binance smart chain, stable coins, eth, btc, or bsc.

Thank you!


# BSC Archive Snapshots
All Binance Smart Chain Archive snapshots are hosted on S3 on the following path:

| s3://public-blockchain-snapshots/bsc/

This path is public, but is configured as requester-pays. This means you'll need an AWS account in order access/download them. This is because I calculated that a full download will cost \~$100-150USD in just data transfer costs. You may greatly reduce this cost to nearly zero by using AWS in us-west-2 region. In such case, you should only need to pay for the cost of the api request (ie: <$0.10USD).

# Download and build a full archive node
As reference code I have provided: `build_archive_node.sh` in this repo.

To build a server capable of running an archive node (this assumes ubuntu 20.04):
* Get an AWS account and ensure it is configured on the computer (I strongly encourage you to run this in AWS's EC2 on `Im4gn.4xlarge` or larger/similar in `us-west-2`, you need at least 64 gigs of ram). If your node cannot keep up with latest blocks, try running it on a larger instance with more ram.
* Checkout this repo to the computer
* Run `sudo ./build_archive_node.sh`.
* When it is done, it should be serving an archive on port `8545`.

# Why use Erigon?
This snapshot uses [erigon](https://github.com/ledgerwatch/erigon) even though it is barely out of alpha stage. To understand why it is a bad idea to use `geth` as an archive node, you need to understand some internals on how `geth` works.


## Geth internals
As a quick refresher, let's talk about what an archive node is; in simple terms, an archive node is a node that can run any contract on a smart chain at any given block. A full node on the other hand can generally only serve any contract at the most recent blocks. In addition, an archive node is also a full node by nature.

Geth maintains a `state`, this state can be thought of as the state of every contract, the contract bytecode, wallet balances and a few other things that are needed to execute a contract. This state is stored in a trie, which provides very efficient lookups, inserts and the keys used to reference the data in the trie are very space efficient while providing a root hash that can be used in the block header for security. The major technical difference between an archive node and a full node, is that an archive node never purges any of the state of any given block. A full node has a bit of logic that will try and remove any nodes of the trie tree that are no longer needed by the most recent blocks.

Lets now build an example of a part of a state node and how geth manages it. Let's say I have a value that contains the an [ABI](https://docs.soliditylang.org/en/develop/abi-spec.html) referenceable key of the contract state that I need to store in the state tree. We will now say that we want to reference this value in the state. Geth will walk down the global state root node using the contract address until it comes across the old contract state and replace it (or insert a new node if it does not exist). The value of the contract's key will be a root hash of new merkle tree that we will traverse down for the data's key in the contract and the same process is performed on this trie. Each node in the trie that was used to get to the inserted location will be copied and replaced and marked as "dirty", until it gets to the root node, which then gets returned. This has the major advantage of only needing to make a copy of the part of the trie that was modified which saves a lot of space and processing time. When a new block is finalized, the current global root state node will then be committed to disk. Geth will then iterate every dirty node (starting from the leaves) and turn them into a "hashNode". Internally a "hashNode" is a node that does not have the data immediately available, only has a key that can be used to retrieve a serialized version of the node from a key-value store. There are a few layers of in-memory caching that happens here, but for now we will assume that the data must be read from disk to get the actual data that the "hashNode" represents. The key of the "hashNode" is the value that is run through the Keccak256 hashing algorithm. Then as we walk up the trie to the next level, we flatten all children into hashNodes and then hash all the children's hashes until we reach the parent. This algorithm is called a [Patricia Tree](https://eth.wiki/fundamentals/patricia-tree).

Great now that we know the internals of how this works, what's the problem with geth + archive node? It is important to remember how a [trie](https://en.wikipedia.org/wiki/Trie) works and how [merkle trees](https://en.wikipedia.org/wiki/Merkle_tree) work. Think of how many contracts & wallets exist at any given block, then imagine putting each address into a trie and estimate how many levels it'd create. At the time of writing this (Jan 26th 2022) there's about 130 million unique addresses on the BSC chain. For the sake of argument, lets assume all 130M of them exist in the latest block's state (which many will not due to having zero balance). If my math is correct (log2(130M)/4 [array of 16 refs or 1 nibble of each key can be stored per level]), you'll need an average of about 6-8 levels to fit these entries. Each one of these nodes is a 32 byte hash and each value is at least (except leaf nodes) 32 bytes, but usually 16 * 32 bytes, so this means that if one value changes in any contract or wallet, the state will require somewhere between 2-4kb of new data. This does not include any of the contract state changes that might also be changed, which can also be quite large on contracts with lots of state. These numbers roughly equate to the additional 200GB per day that was being generated in mid December 2021.

Keep in mind that Geth's storage format is almost not compressible at all due to most of the data being just hashes.

## How erigon stores data
Erigon uses a completely different way of storing data. I have personally not dug deep into the code, but I will attempt to explain based on the documentation I've read and filling in the gaps based on the little code I have read.

Erigon first stores the data of each wallet and contract in a flat key-value database ([mdbx](https://github.com/erthink/libmdbx) for default local db). Geth also stores data in a flat key-value list, but geth uses LevelDB, which both have a different set of pros and cons. Once it downloads all the headers and such, it will eventually start to build the state of each block, however, it does not actually store the hashes, it just puts uses a block index number + contract/wallet address as the key. Erigon will eventually calculate the entire tree, but it will only do it for the last blocks. Erigon will also eventually build indexes for things like Log entries, Transactions, Sender/Recipient data and whatever other indexes are needed. Then when you want to execute a contract as an archive node, it will not use the merkle root, but instead just do a single lookup per key, instead of walking a trie.

Not only is the data much smaller on disk and faster, but it is also highly compressible. As of Jan 26th 2022, the entire BSC archive is about 4.5TB compared to about 30TB required for `geth`. If you use a filesystem compressor too (like zfs + lz4), I see consistent 2.3x compression ratios with this configuration and about 4x ratios with `zstd` when uploading the tar.

## Erigon's problems
* Erigon is new and not yet battle tested
* ~~Erigon does not really keep up to date with latest blocks like you'd think (see below)~~

~~The biggest problem with Erigon is that to my knowledge, it does not keep executing latest blocks as it gets them, instead it queues them up and batches them together. For example, Erigon takes about (on decent compute) 2 mins to process a batch, then process all items queued up as a batch again, but you can't access any of the blocks that it is working on until it has finished. However, there's good news if you need latest blocks + archive, `geth` has the ability to set how many block's worth of state hash to hold onto before it purges it. What you can do is write a proxy that will first ask erigon if it has that block and if not forward it to an instance that runs geth that is a full node. Then ensure the full node has enough recent blocks to cover while erigon is processing the batch.~~

#### Update [2022-08-30]
After doing a full fresh sync using 16k blocks in mdbx this issue is resolved. The comment above is left here so if in the future it happens again there is documentation that it has existed before.

# Technologies I use
I did a lot of testing of different file systems, different AWS node classes, different tuning parameters and came to the the following conclusions:

## ZFS
I am a big fan of ZFS. It has many powerful features that make life so much better. The biggest problem with it, is the way it manages in-memory paging, but in all honesty it is not a big deal because zfs is smart enough to free it's memory before letting the OS begin swapping.

The big features that make ZFS amazing for this kind of use case is that:
* Making a snapshot of the file system is almost instant. So, before you change anything or say "hold my beer", just run the `zfs snapshot` command and then if anything goes wrong, you can use `zfs rollback` and almost instantly go back to what you had before you screwed it up [without actually copying everything](https://docs.oracle.com/cd/E19253-01/819-5461/gbcxz/index.html) (this saved my butt many times).
* Enables you to use ZFS's snapshot ability to quickly stop the geth service, make a snapshot then start geth again within seconds. Then in parallel you can upload the snapshot as a backup with only \~1-2 seconds of downtime.
* You can add new drives to the pool very fast. In the event you start running out of space, you can easily add another drive to the instance and then run `zpool add` to add additional space to the pool effortlessly (however you can't remove any).
* ZFS's SLOG \[L2ARC\]. This might be the biggest reason to use it. Lets imagine a world where it is unrealistic to fit everything into SSD/NVMes in a cost effective way, but old spinning plates are still cheap. Well, this is where the SLOG comes in. This enables you to use the HDD as the drive that has all the data and then add SSD/NVMes as a cache drive. ZFS will automatically populate the SSD/NVMes with the most commonly read blocks, which enables extremely fast reads from the SSD/NVMes on frequently accessed data.

#### Notice
ZFS does add overhead that likely adds overhead to erigon which decreases performance, but in testing it has not been shown to be much of an issue. The configuration I use is slightly modified from the config below, the script that keeps snapshots updated uses `recordsize=1M`, which means that if 1 byte is modified at least 1Mb of data is written to disk and `compression=lz4`. `recordsize` influences how compressible the data is, because a compression frame is set by `recordsize`, so the larger the recordsize, generally the more compressed the data will be. In testing `lz4` has not shown to be noticeably slower than when compression is disabled. This is likely because the amount read and written to disk is reduced, so it can read and write \~2x more data for the same time and since `lz4` is so fast at decompression the overhead is offset by less data it needs to read from disk.

### ZFS configuration
After a bit of AB testing I found the following ZFS configuration to work the best:
```sh
zfs set recordsize=16k tank
zfs set sync=disabled tank
zfs set redundant_metadata=most tank
zfs set atime=off tank
zfs set logbias=throughput tank
```
In addition make sure when you create the zpool you use `-o ashift=12`.

Note: I did not care about if the instance randomly shutdown (since I was using spot instances anyway) so I set `sync=disabled`, but your use case might not be the same.

## AWS configuration
### If you need high availability
I suggest using something as follows in the event you need high availability:
* Create auto-scaling group with appropriate instance type(s).
* Use spot instances except for a few on-demand (just in case capacity gets low).
* Configure the scaling rules to follow the CPU usage.
Spot instances are currently the absolute cheapest way to run an instance. The problem is that the instance might be terminated with a 2 minute warning, but with the proper infra you can just retry on another instance in the event of early-termination. Since it allows you to ensure a few are on-demand, the worst case is that users see a slow down when AWS resources are limited.

Do not run all archive snapshots on the same instance, instead you should try and run smaller instances that can fit 1 to 2 archive snapshots on it at a time, but allow them to scale with the demand. This is because it is likely safe to assume that most users will likely be reading blocks closer to the head block than further back, if you can make that assumption, you can spin up more instances that have only that part of the chain. This has several advantages, the biggest advantage is that you can fit more of the chain into memory-per instance, this would likely not be the case if you ran all the chain on one node.

# Do you still have the geth BSC archives?
Yes, however they are only up to about mid December 2021 and in deep archive storage. If you need these archives, please reach out to me and I will see about resurrecting them and giving access, however this will come at a cost (as it will cost me to request them from AWS's deep archive storage).
