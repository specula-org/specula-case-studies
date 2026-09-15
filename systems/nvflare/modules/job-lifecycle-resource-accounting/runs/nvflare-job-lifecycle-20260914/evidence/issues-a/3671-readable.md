# 3671: [BUG] job fails due to the communication error

{'state': 'CLOSED', 'createdAt': '2025-09-09T15:54:47Z', 'updatedAt': '2025-09-22T05:07:34Z', 'closedAt': '2025-09-22T05:07:34Z'}

## Body
I am running Flare in production mode in on my lab setup in AWS. There are 4 virtual machines for 4 clients, in addition one of these machines also runs server. Every process: server and clients run in separate docker containers. All machines are in the same VPC, connected to the same network.

The issue happens less frequently when no client is running on the same host that server runs.

I am ruining the same job multiple times. sometime it completes successfully, sometime it fails. Even for completed job, I can see the following exception in the server log:
```
Traceback (most recent call last):
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/drivers/grpc_driver.py", line 89, in send_frame
    self.oq.append(Frame(seq=seq, data=bytes(frame)))
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/drivers/grpc/qq.py", line 35, in append
    raise QueueClosed("queue stopped")
nvflare.fuel.f3.drivers.grpc.qq.QueueClosed: queue stopped

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/cellnet/core_cell.py", line 1166, in _send_to_endpoint
    self.communicator.send(to_endpoint, CoreCell.APP_ID, message)
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/communicator.py", line 141, in send
    self.conn_manager.send_message(endpoint, app_id, message.headers, message.payload)
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/sfm/conn_manager.py", line 235, in send_message
    sfm_conn.send_data(app_id, stream_id, headers, flat_payload)
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/sfm/sfm_conn.py", line 108, in send_data
    self.send_frame(prefix, headers, payload)
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/sfm/sfm_conn.py", line 148, in send_frame
    self.conn.send_frame(buffer)
  File "/opt/venv/lib/python3.12/site-packages/nvflare/fuel/f3/drivers/grpc_driver.py", line 91, in send_frame
    raise CommError(CommError.ERROR, f"Error sending frame: {ex}")
nvflare.fuel.f3.comm_error.CommError: Code: ERROR Error: Error sending frame: queue stopped
```

The only difference that in some jobs Flare knows to recover, and in another jobs, I getting errors like that:
```
All clients are dead: ['b0336cd2-f7fd-4979-899d-c5ec5e63fcf2', 'd9942b10-6785-45b2-b92b-18ca6ef8989e', 'f23f8871-b2ce-407e-b0ff-49fc1e362b59', '62f0f054-c09a-4956-8625-d9c2e6aaaf6c']

Aborting current RUN due to FATAL_SYSTEM_ERROR received: Aborting job due to deployment policy violation
```

I do not see any networking interference during the job run. This happens during a long period of time, so it is not related to a temporary networking issues. This also happens when I deploy the entire setup on a separate set of virtual machines.

- OS: ubuntu 24.04, Flare Server and Clients run in docker containers
- Python Version 3.12
- NVFlare Version 2.6.0



## timeline-comments 3275073385 by evgvain; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3275073385; ; 
I see in Client log few milliseconds **before** the server:
```
CLIENT: exception <class 'grpc._channel._MultiThreadedRendezvous'> in read_loop
CLIENT in conn_mgr_1: done read_loop
CLIENT: closing queue
Connection [CN00002 Not Connected] is closed PID: 230
Connection removed: GrpcDriver:[CN00002 N/A => auto-4916-node2.dev.acme-test.com:8002]
CLIENT: finished connection [CN00002 Not Connected]
Connection CN00002 is removed from endpoint server
========= 62f0f054-c09a-4956-8625-d9c2e6aaaf6c: EP server state changed to 3
Retrying [CH00001 ACTIVE grpc://auto-4916-node2.dev.acme-test.com:8002] in 1 seconds
62f0f054-c09a-4956-8625-d9c2e6aaaf6c: removed CellAgent server
Queue closed - stop iteration
```



## timeline-comments 3288689900 by YuanTingHsieh; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3288689900; ; 
@evgvain thanks for raising the issue.

- Could you please share a bit more about your workload and environment setup?

    - How large is your model in terms of weights—are we talking several GBs?

    - What’s the disk size on each VM?

- You mentioned: "happens less frequently when no client is running on the same host that server runs."
Just to clarify, does the issue occur in both setups, but is more frequent when a client is running on the same host as the server?

- Also, would it be possible for you to share the full logs? That would really help us understand the issue better.


## timeline-comments 3291001486 by evgvain; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3291001486; ; 
- Let me provide more detailed information about the latest setup. 
    - I have 3 VMs: node2, node3, node4. There is a dedicated container for flare server on the node2. In addition there are 10 worker containers on each node. For every computation tasks messages are published. The server container starts flare server process for every task. One arbitrary worker on each VM starts the flare client process. The flare admin monitors the flare server and submits a job after all clients are connected.
    - The data I am using for test is really small. Every client calculates a histogram over 2 categories. Then the server aggregates histograms calculated by the clients.
    - Each VM has more than 100GB free disk space, 16 vCPU, 64GB RAM
    - All VMs are in the same AWS VPC, connected to the same subnet

- I have 2 configurations (I run about 100 jobs on each one):
    - server no node2, clients are on node2, node3, node4 - in this setup the error happens approximately in 5-7% of runs 
    - server no node2, clients are on node3, node4 - in this setup the error happens approximately in 2-3% of runs
   
- Attaching logs for successful and for failed sessions from the 1st setup (server no node2, clients are on node2, node3, node4)

[failed.client2.log](https://github.com/user-attachments/files/22329879/failed.client2.log)
[failed.client3.log](https://github.com/user-attachments/files/22329881/failed.client3.log)
[failed.client4.log](https://github.com/user-attachments/files/22329880/failed.client4.log)
[failed.server.log](https://github.com/user-attachments/files/22329876/failed.server.log)
[successful.client2.log](https://github.com/user-attachments/files/22329878/successful.client2.log)
[successful.client3.log](https://github.com/user-attachments/files/22329877/successful.client3.log)
[successful.client4.log](https://github.com/user-attachments/files/22329875/successful.client4.log)
[successful.server.log](https://github.com/user-attachments/files/22329874/successful.server.log)


## timeline-comments 3294675359 by chesterxgchen; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3294675359; ; 
@YuanTingHsieh 


## timeline-comments 3299977488 by yanchengnv; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3299977488; ; 
The log file shows grpc.RpcError exception. This happens when the underline gRPC ran into connection issues.
Can you try HTTP?  You will need to re-provision the project, and specify the "scheme" to be "http" in the project.yml.


## timeline-comments 3302974150 by evgvain; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3302974150; ; 
@yanchengnv 
I clanged the schema as you suggested and the error did not happen again.
Could you help me to understand what are the upsides and downsides of using http instead of grpc? Is mTLS connection security preserved? Thanks.


## timeline-comments 3313028286 by nvidianz; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3313028286; ; 
HTTP scheme uses WebSocket (a HTTP extension) for transport. In the past, websockets library is used and it's very slow so we didn't recommend it. Since 2.6, we switched to aiohttp library and the performance is the same as gRPC based on our benchmark. 

The upside is that it has much less issues than gRPC. The downside is sometimes websocket is blocked by the network infrastructure.

mTLS is the same on all schemes.


## timeline-comments 3315512173 by evgvain; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3315512173; ; 
@nvidianz , thanks for you the explanation. So we can use the 'http' driver instead of 'grpc', without any other changes in the configuration, keeping the same security level and performance, correct?


## timeline-comments 3316093951 by chesterxgchen; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3316093951; ; 
Yes.

Get Outlook for iOS<https://aka.ms/o0ukef>
________________________________
From: evgvain ***@***.***>
Sent: Saturday, September 20, 2025 10:23:23 PM
To: NVIDIA/NVFlare ***@***.***>
Cc: Chester Chen ***@***.***>; Comment ***@***.***>
Subject: Re: [NVIDIA/NVFlare] [BUG] job fails due to the communication error (Issue #3671)

[https://avatars.githubusercontent.com/u/6605905?s=20&v=4]evgvain left a comment (NVIDIA/NVFlare#3671)<https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3315512173>

@nvidianz<https://github.com/nvidianz> , thanks for you the explanation. So we can use the 'http' driver instead of 'grpc', without any other changes in the configuration, keeping the same security level and performance, correct?

—
Reply to this email directly, view it on GitHub<https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3315512173>, or unsubscribe<https://github.com/notifications/unsubscribe-auth/AAD5FQ7UAPJK5BG7KB7GDPT3TYY4XAVCNFSM6AAAAACGBJYWBOVHI2DSMVQWIX3LMV43OSLTON2WKQ3PNVWWK3TUHMZTGMJVGUYTEMJXGM>.
You are receiving this because you commented.Message ID: ***@***.***>



## timeline-comments 3316833734 by evgvain; https://github.com/NVIDIA/NVFlare/issues/3671#issuecomment-3316833734; ; 
@chesterxgchen Thanks
