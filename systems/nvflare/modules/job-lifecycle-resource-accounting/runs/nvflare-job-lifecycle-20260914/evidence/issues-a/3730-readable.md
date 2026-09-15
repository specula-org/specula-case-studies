# 3730: [Issue] submitting job with large file(>2GB), the job start before the transfer is completed

{'state': 'CLOSED', 'createdAt': '2025-09-30T00:53:42Z', 'updatedAt': '2025-10-12T12:28:25Z', 'closedAt': '2025-10-10T13:58:24Z'}

## Body
Problem : When submitting a job containing a large file, the job start occurs before the transfer is completed, causing the job to fail.

Background: We are currently preparing a real production environment involving many organizations in an AWS environment.
The server and each client are individually connected, and there were no issues when using the small job file example in the previous step.
However, some of our clients have blocked external internet access, and while they are still connected to the server, they are unable to use external networks like huggingface.
Therefore, instead of using huggingface to load the LLM model in the client script file, I placed each model's .safetensors file in the same job folder and loaded it locally using from_pretrained. The total file size is approximately 2GB (for each "app_client" folder).

Issue: After checking the server and client logs, the issue was as follows:

1. job submit >> The nvflare admin console and the Python API it uses submit the job_configs location and send the job command to the server.
2. The FL aggregation server receives the command, forwards it to the app_server to prepare for job execution, and sends the app_client folder for the remaining clients to execute. (However, due to my lack of understanding, it's possible that each app_client folder isn't being sent from the FL server, but from another server where the admin console exists. Perhaps... please point this out.)
3. However, at this stage, when I connected two clients and tested, the FL server completed the transfer to the first client and returned a "job_deploy: OK" signal. While transferring the folder to the second client, it recorded a "job_deploy: UNKNOWN" signal (probably because the file is still being transferred and no completion response has been received), and then sent a "job start" signal.
4. Naturally, the second client that received the "job start" signal didn't find the job because the file transfer wasn't completed yet, and the workspace/UUID/...~~ path created when the job was executed didn't exist. Therefore, it couldn't find the job, resulting in a "No such file or directory" error. The server logged an error indicating that the second client couldn't execute the job and aborted the job because it didn't meet the "min client" number I set.
5. I've searched for any settings, but I can't find any that increase the server transmission wait timeout or wait for an "job_deploy: UNKNOWN" signal during the "job file deployment phase before starting the job."

Question: What settings, modifications, or features can I use to successfully transfer these large local job files and start the job?

FYI. We're developing a unified platform. The Python API server receives specific job creation requests and submits them immediately. Clients in the production environment can't directly connect to the server, and direct commands can't be written in the admin console. Therefore, pre-transferring job files is impossible.

+ I'm not a native English speaker, and this query was translated using a translator, so it may be difficult to read. If you have any further questions, please ask. I'll provide as much information as possible, within the scope of security regulations.

## timeline-comments 3352608646 by chesterxgchen; https://github.com/NVIDIA/NVFlare/issues/3730#issuecomment-3352608646; ; 
Thanks for reporting the issues

Few general questions: 
1) Which version of FLARE are you running ? 
2) Which framework did you run the job with ( pytorch, pytorch-lightning, tensorflow etc)
3) Which python version
4) can you share the logs with us (Server and client side logs) ?
5) can you share the example code with us ? 

My initial guess, without reading the log, issue you experience is likely due to insufficient timeout setting or something related. 

>FYI. We're developing a unified platform. The Python API server receives specific job creation requests and submits them immediately. Clients in the production environment can't directly connect to the server, and direct commands can't be written in the admin console. Therefore, pre-transferring job files is impossible.

I am not fully understand this statement.  Can you elaborate more on this ? 

> and direct commands can't be written in the admin console. 

There is no need to directly issue admin console command for this type of work. There is equivalent python API for job submission and monitoring. You can look at this [FLARE API tutorial](https://github.com/NVIDIA/NVFlare/blob/main/examples/tutorials/flare_api.ipynb) which shows how to use Python API to submit job ( this is the same as using Admin Console via submit job command) 

> Clients in the production environment can't directly connect to the server,

Does this mean you use a proxy FL client that connect to the FL Server ? The real production Client connect to proxy FL Client ? 

>Therefore, pre-transferring job files is impossible.

I am not sure what this means ? are these job dynamic created ? do you have custom python code ? or just job configuration ? 





## timeline-comments 3354148035 by alcatraz7698; https://github.com/NVIDIA/NVFlare/issues/3730#issuecomment-3354148035; ; 
Thank you for respond.

1. nvflare==2.5.2
2. pytorch / pytorch_lightning
3. python3.11
4. i will share the logs(with masking our ip and dns) (The logs are delivered as text files. The inline code doesn't break, so it's a bit messy.) [log.txt](https://github.com/user-attachments/files/22628598/log.txt)
5. i'm really sorry but i can't. this training code is not of mine, it belongs to other company.
(In fact, in my opinion, it seems to me that the problem is not a logic issue when executing the job, but rather a timeout or client response condition check issue during the job_deploy process. Therefore, regardless of what user python code is included in the job, it seems that you only need to focus on the deployment of the "large file job" and its timeout.)

First, let's talk about the log file. The server-side log shows a message indicating that client2 cannot execute the app because the path to execute it does not exist.
Client1 attempted to execute the app successfully, but received an abort_job signal from the server.
In the case of client2, the server unilaterally sent an abort_job signal while receiving the job from the server. This appears to be the reason why client2's log is stopped in the log.txt file. Accessing the client's file system reveals that the job file sent from the server is successfully saved. This is because the timeout check that starts the server's job_start process is shorter than the time of the job_deploy process.

And while I can't give you the job example file, I can give you my job config and the client/local/**.json values.
[jsons.zip](https://github.com/user-attachments/files/22628597/jsons.zip)
comm_config.json >> Applies to both server and client at
resources.json >> Applies to only clients

> My initial guess, without reading the log, issue you experience is likely due to insufficient timeout setting or something related.

yes. i really think so. but i don't know what i have to do and edit which configs

here is what i found from nvflare

When the job_runner function in nvflare/private/fed/server/job_runner.py is executed, it appears to first execute the _deploy_job() function to deploy the job.

During this process,
""" f"App {app_name} to be deployed to the clients: {display_sites} for run: {run_number}" """
After the above message appears, the process moves on to the next step.

```
engine = fl_ctx.get_engine()
admin_server = engine.server.admin_server
client_token_to_reply = admin_server.send_requests_and_get_reply_dict(client_deploy_requests, timeout_secs=admin_server.timeout)
```
Here, the FL engine receives the ""admin_server"" object and uses the ""admin_server.timeout"" as the timeout args for the send_requests_and_get_reply_dict() function.

Looking at the ""FedAdminServer(AdminServer)"" class in the nvflare/private/fed/server/admin.py file, which is the ""admin_server"" object, at the bottom of the class init(),

self.timeout = 10.0

The setting is hardcoded.

My guess is that the timeout isn't due to the server waiting long enough for the job to deploy to the client or for a specific condition, but rather the job is terminated after 10 seconds.

Second, let's return to the _deploy_job() function.
Immediately below the ""admin_server.send_requests_and_get_reply_dict(client_deploy_requests, timeout_secs=admin_server.timeout)"" function call described above, there's a process that checks the client's response and classifies it as OK, Fail, or Unknown.

```
for client_token, reply in client_token_to_reply.items():
    client_name = client_token_to_name[client_token]
    if reply:
        assert isinstance(reply, Message)
        rc = reply.get_header(MsgHeader.RETURN_CODE, ReturnCode.OK)
        if rc != ReturnCode.OK:
            failed_clients.append(client_name)
            deploy_detail.append(f"{client_name}: {reply.body}")
        else:
            deploy_detail.append(f"{client_name}: OK")
    else:
        deploy_detail.append(f"{client_name}: unknown")

```

During this process, clients that return "failed" are added to the "failed_clients" list, and clients that return "OK" are added to the "deploy_detail" list.
However, even if the client returns "unknown," it's still added to the "deploy_detail" list.
Therefore, the nvflare server immediately proceeds to the "job_start" step after completing the client verification process.
That is, even if the client returns an "unknown" response, the nvflare server engine (job_runner.py) will not wait for that client, but will consider it a "non-failed" client and send a job start signal to it.
This sends a signal to execute a file that hasn't yet been transferred, resulting in an error.

What I'm asking is, instead of directly modifying the nvflare package code, whether it's possible to adjust the timeout value by adding a configuration file or adding logic to check for OK and Unknown.


> There is no need to directly issue admin console command for this type of work. There is equivalent python API for job submission and monitoring. You can look at this [FLARE API tutorial](https://github.com/NVIDIA/NVFlare/blob/main/examples/tutorials/flare_api.ipynb) which shows how to use Python API to submit job ( this is the same as using Admin Console via submit job command)

yes. i know. :)
so i'm making python api server which has working like a Wrapper service of nvflare. that is the python api what a said. sorry for confuse.
actually, we're using nvflare's python api code and admin session like down below

```
class Fl_Session(BaseModel):
    def __init__(self):
    super().__init__(session = new_secure_session((the admin ID Email), f'{where is the admin dir}'))
    self.session.set_timeout(300.0)
    ... ... 
    def start_job(self):
    self.job_id = self.session.submit_job(f'{the exported job dir location}')
```
Does it look familiar? haha
we are trying to make a platform, so users do not access nvflare system & it's python api directly, the concept is that when a file to be created as a job is submitted, it is exported as a job from my API server, and when a start request comes in, a nvflare admin session is created and submitted.

> Does this mean you use a proxy FL client that connect to the FL Server ? The real production Client connect to proxy FL Client ?

Oh, I'm sorry.
The part where I said, "Clients in the production environment can't directly connect to the server," didn't mean that clients couldn't connect directly to the FL server. It meant that since it's the actual data repository, I, as the central system administrator, couldn't directly connect to the host system via SSH. That's a complete mistranslation.
Our servers and clients are all connected via VPC peering on AWS, so we have full access to our internal network bandwidth, and we haven't had any network stability issues in our testing over the past several months, so you don't have to worry.

> I am not sure what this means ? are these job dynamic created ? do you have custom python code ? or just job configuration ?

I'm not entirely sure I understand your question: "Are these jobs dynamically created?
Do you have custom Python code?
Or just job configuration?"
But as I explained above, the API server I run uses the nvflare Python API, just like your example code, to create, export, create sessions, and submit job files for platform users.

Therefore, jobs are dynamically created and submitted.
Custom Python code: Whether it's the job.py file the user wants to learn or my Python API server code that manages it, that's correct.
Just job configuration?: I didn't quite understand that part, but if you mean only the config_fed_server.json file that's generated when we create a job, then that's not the case. We create a job with the following structure using job_export:

our_job
├── app_client1
│    ├── config
│    │            └── config_fed_client.json
│    └── custom
│    ├── config.yaml
│    ├── data.py
│    ├── model
│    │            └── (here is the model file which is 2GB .safetensors)
│    ├── model_load.py
│    ├── script.py
│    ├── train_eval.py
├── app_client2
│    ├── config
│    │            └── config_fed_client.json
│    └── custom
│    ├── config.yaml
│    ├── data.py
│    ├── model
│    │            └── (here is the model file which 2GB .safetensors)
│    ├── model_load.py
│    ├── script.py
│    ├── train_eval.py
├── app_server
│    ├── config
│    │            └── config_fed_server.json
│    └── custom
│    ├── config.yaml
│    ├── model
│    │            └── (here is the model file which 2GB .safetensors)
│    └── model_load.py
└── meta.json


Thanks for your help. I look forward to your next reply.


## timeline-comments 3373199617 by YuanTingHsieh; https://github.com/NVIDIA/NVFlare/issues/3730#issuecomment-3373199617; ; 
@alcatraz7698 thanks, you are right that timeout is somehow hardcoded as 10: https://github.com/NVIDIA/NVFlare/blob/main/nvflare/private/fed/server/admin.py#L175
 and it is not adjustable.

We will be updating the main branch and 2.6 to add enhancement to make it configurable.

Could you try 2.6 later?
Or to unblock you now, you could directly edit the installed source code (NVFlare 2.5.2) for your environment.


## timeline-comments 3390303336 by alcatraz7698; https://github.com/NVIDIA/NVFlare/issues/3730#issuecomment-3390303336; ; 
@YuanTingHsieh 

Thank you for letting me know.

It's a bit sad that there's no solution other than directly modifying the package, but your clear answers have simplified the problem by saving me from wasting time trying different things. Thank you.

I expect this feature will probably be added in version 2.6.3, but when do you think it will be released? With the beta test coming up this month and the release planned for the end of the year, I think we'll need to consider the timeline for feature support. If possible, I'd appreciate a rough estimate. (Regardless of whether or not that schedule actually happens, I fully agree that this is not an official answer.)




## timeline-comments 3391186932 by chesterxgchen; https://github.com/NVIDIA/NVFlare/issues/3730#issuecomment-3391186932; ; 
@YuanTingHsieh  lets fix this in both main branch and 2.6 branch, we can issue a patch.  @alcatraz7698  gives us a few weeks to patch this, we are busy with 2.7 release. We have a few other items to patch in 2.6 branch. 


## timeline-comments 3394306655 by alcatraz7698; https://github.com/NVIDIA/NVFlare/issues/3730#issuecomment-3394306655; ; 
@chesterxgchen, @YuanTingHsieh 

Thank you for your reply.
I'll wait until the next 2.6 patch or 2.7 release to add this feature.

rooting for the NVflare team and all the contributors!
