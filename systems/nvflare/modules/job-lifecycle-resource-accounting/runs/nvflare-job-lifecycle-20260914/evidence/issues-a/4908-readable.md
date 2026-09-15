# 4908: Recommended deployment of an NVFlare client on an HPC cluster

{'state': 'CLOSED', 'createdAt': '2026-07-15T10:50:08Z', 'updatedAt': '2026-07-29T07:04:24Z', 'closedAt': '2026-07-27T17:40:31Z'}

## Body
# Description

I am deploying an NVFlare client on an HPC cluster and would like to know the recommended approach for this type of environment.

The HPC system has the following constraints:

1. Compute nodes do not have direct Internet/external network access.
2. Long-running processes are not allowed on login nodes.
3. Training jobs are submitted through Slurm.
# Approaches I have considered
## Option 1: Run the NVFlare client as a long-lived Slurm job on a compute node

  This works if the compute node can communicate with the NVFlare server. However, on some HPC systems, compute nodes do not have external network access, so the client cannot connect to the server.
  
## Option 2: Run the NVFlare client on the login/service node and submit training jobs to compute nodes via Slurm   (recommended  [NVFlare Issue #2595](https://github.com/NVIDIA/NVFlare/issues/2595))

This avoids the networking issue, but many HPC centers prohibit long-running processes on login nodes, making this approach unsuitable.

# Questions
1. Is there a recommended deployment pattern for running NVFlare clients on HPC systems with these constraints?
2. Does NVFlare provide any built-in support or examples for environments where compute nodes cannot directly communicate with the server?
3. Are there any recommended architectures or best practices for integrating NVFlare with Slurm-based HPC clusters?

Any guidance or references to existing examples would be greatly appreciated.

## timeline-comments 4984224473 by pcnudde; https://github.com/NVIDIA/NVFlare/issues/4908#issuecomment-4984224473; ; 
Thanks for the detailed write-up — this is an important use case for us. In the upcoming 2.9 release we are making Slurm a first-class deployment target alongside Docker and Kubernetes. That said, the two constraints you describe are cluster policies the integration itself cannot remove — the client process still needs to run somewhere persistent with a network path to the FL server.

Our normal recommendation is a variant of your Option 2: run the client on a service/workflow node rather than a login node. Many centers can provide one for persistent orchestration processes (the same class as Nextflow/Snakemake head processes). The client is lightweight — no GPU; it only needs shared-filesystem access, the Slurm submit tools, and outbound connectivity to the server.

On Option 1: does your center provide a proxy or gateway that allows network egress from compute nodes to approved external destinations? If so, running the client as a long-lived Slurm job can work — it needs a single outbound TCP connection to one host/port, which is usually easy to allowlist. Happy to go into details if that path is available to you.


## timeline-comments 4992571484 by falibabaei; https://github.com/NVIDIA/NVFlare/issues/4908#issuecomment-4992571484; ; 
Dear @pcnudde,

Thank you very much for the quick reply. I have already tested both approaches on one HPC system, and both worked well. However, my goal is to find a more general solution that can be applied across different HPC centers, each with its own policies and operational constraints.

For **Option 2**, I have a working example using a custom Slurm launcher here which worked for me in the simulation mode:

- https://github.com/falibabaei/nvflare-hello-pt-slurm/tree/main

The main challenge I've encountered is that not every HPC center provides a persistent service/workflow node for users.

Regarding **Option 1**, I agree that allowing a single outbound connection to the FL server through a proxy or gateway would make this approach practical. 



## timeline-comments 4994004461 by pcnudde; https://github.com/NVIDIA/NVFlare/issues/4908#issuecomment-4994004461; ; 
I'm not sure that there is a simple path as the challenges to reach the FL server node are exactly the goal of the slurm security setup. 
I think the easiest approach would be if there was a standard proxy mechanism we could use. 

Do you have any ideas what would be the best solution?


## timeline-comments 5094720391 by pcnudde; https://github.com/NVIDIA/NVFlare/issues/4908#issuecomment-5094720391; ; 
https://github.com/NVIDIA/NVFlare/pull/4930 includes the native slurm launcher. It will be released as part of 2.9


## timeline-comments 5107066267 by pcnudde; https://github.com/NVIDIA/NVFlare/issues/4908#issuecomment-5107066267; ; 
@falibabaei regarding "Does NVFlare provide any built-in support or examples for environments where compute nodes cannot directly communicate with the server?"

2.9 will allow the compute nodes to talk to the client parent over any shared filesystem (like lustre). Obviously the client parent still needs to be able to reach the server over the network.




## timeline-comments 5114298484 by falibabaei; https://github.com/NVIDIA/NVFlare/issues/4908#issuecomment-5114298484; ; 
@pcnudde Thank you for the update.  
