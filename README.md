# BSC Archive Node Snapshot Tools
This repository holds the tools and commands that can be used to deploy your own BSC Archive node by downloading pre-built snapshots and installing them on an instance.

# BSC Archive Snapshots
All Binance Smart Chain Archive snapshots are hosted on S3 on the following path:

| s3://public-blockchain-snapshots/bsc/

This path is public, but is configured as requester-pays. This means you'll need an AWS account in order access/download them. This is because I calculated that a full download would cost \~$15USD in just data transfer costs as of 2021-06-19. You may greatly reduce this cost to nearly zero by using AWS in us-west-2 region. In such case, you should only need to pay for the cost of the api request (ie: <$0.00001USD).

# Download and build a full archive node
As reference code I have provided: `build_archive_node.sh` in this repo.

To build a server capable of running an archive node (this assumes ubuntu 20.04):
* Get an AWS account and ensure it is configured on the computer (I strongly encourage you to run this in AWS's EC2 on `i3en.6xlarge` in `us-west-2`)
* Checkout this repo to the computer
* Run `sudo ./build_archive_node.sh`.
* It will take some time to finish. You can run `sudo watch -n1 zfs list` to see numbers move if you want to make sure it is doing something.
* When it is done, it should be serving an archive on port `26656`.

# How it works
Instead of putting all archive data on a single geth instance this approach has you create multiple geth instances that only serve part of the chain.

## Why
First lets look at a few factors. At time of writing BSC is about 9 months old and the chain is already 6-8TB in size; this obviously won't scale well. Once you take SSD costs into account as well over time it will become more and more difficult to run an archive node. In addition the way LevelDB works (geth's database) you can't easily put archival data on slower/cheaper disks and newer blocks on less-expensive disks (see below for exception to this). This presents a problem because you currently need at least SSDs in order to run a full node, and since an archive node is pretty much a full node with all intermediate states.

The second reason for this is because at time of writing this there are very few providers that are able to run a BSC archive node successfully due how difficult it is to scale this up (this is why this project was started). To help get around this problem as well as get me a cost-effective archive node as fast as possible, I took a hard look at how geth works internally and realized that it is possible to partition archive chain into different instances. This solved many problems at the same time. First, it was EXTREMELY cost effective, since for my use case, I only needed to populate a database with archival data, I could spin up only parts of the chain at at time on smaller instances. It was also much cheaper to store the data, since I could host it in S3 instead of EBS and upon request download the ones I want in parallel (S3 is <1/2 the cost of EBS).

The third reason is because I believed providers were doing it wrong and wanted to set the story straight on how they could scale better. I was extremely frustrated at the fact that the providers that did offer this service had horrible latency and could only service a few requests per second. It obvious that the bottle neck was due to being unable to scale up quickly during high load, inability to load much of the chain into memory (ie: disk IO time) and the fact that a large amount of resources were being devoted to keeping up with the latest blocks.

## How it was built
When I made this project, I estimated it would take \~30-60 days to get a single archive node up and running and was not willing to wait that long. To help expedite this, Binance offers snapshots available here:
https://docs.binance.org/smart-chain/developer/snapshot.html

In addition Binance also has the following repo:
https://github.com/binance-chain/bsc-snapshots

Using both the first link and the git history of the git repo, I was able to download full node snapshots at different points in time and run them all in parallel on different nodes. This means that these nodes have all full node data from the last block on it and archival data from when it was snapshotted to the last block.

It took about 1 week to get the \~8TB of archival data. I arbitrarily chose 700G-800G as the splitting point for these instances, but has no real meaning.

Once an archival snapshot was done and ready to be split, I would clone it using zfs's clone feature, run a full database compaction on the archive (which gives faster read times) and in parallel run: `geth prune` on it; this would turn the archive node back into a full node. After it was done pruning, I would then resume the (now) full node as an archive node which gave me a new "start block" for this new clone.

# Technologies in use
I did a lot of testing of different file systems, different AWS node classes, different tuning parameters and came to the the following conclusions:

## ZFS
I am a big fan of ZFS. It has many powerful features that make life so much better. The biggest problem with it, is the way it manages in-memory paging, but in all honesty it is not a big deal because zfs is smart enough to free it's memory before letting the OS begin swapping.

The big features that make ZFS amazing for this kind of use case is that:
* Making a snapshot of the file system is almost instant. So, before you change anything or say "hold my beer", just run the `zfs snapshot` command and then if anything goes wrong, you can use `zfs rollback` and almost instantly go back to what you had before you screwed it up [without actually copying everything](https://docs.oracle.com/cd/E19253-01/819-5461/gbcxz/index.html) (this saved my butt many times).
* Enables you to use ZFS's snapshot ability to quickly stop the geth service, make a snapshot then start geth again within seconds. Then in parallel you can upload the snapshot as a backup with only \~1-2 seconds of downtime.
* You can add new drives to the pool very fast. In the event you start running out of space, you can easily add another drive to the instance and then run `zpool add` to add additional space to the pool effortlessly (however you can't remove any).
* ZFS's SLOG \[L2ARC\]. This might be the biggest reason to use it. Lets imagine a world where it is unrealistic to fit everything into SSD/NVMes in a cost effective way, but old spinning plates are still cheap. Well, this is where the SLOG comes in. This enables you to use the HDD as the drive that has all the data and then add SSD/NVMes as a cache drive. ZFS will automatically populate the SSD/NVMes with the most commonly read blocks, which enables extremely fast reads from the SSD/NVMes on frequently accessed data.

### ZFS configuration
After a bit of AB testing I found the following ZFS configuration to work the best:
```sh
zfs set recordsize=32K tank
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

### Instance class suggestion
At the time of writing this, I am using `i3en.6xlarge`. However, I have had success running everything on a single `d3en.xlarge`, but I did need to modify `geth` to give a 2 min timeout instead of the default 5 second timeout on executing contracts. This is because HDDs are much slower at random IO (which is what geth uses a lot of).

I also believe you may have success on smaller `i3` or `i3en` instances.
