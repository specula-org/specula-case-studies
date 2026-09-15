# 4445: [BUG] nvflare poc start gpu flags do not work with docker

{'state': 'CLOSED', 'createdAt': '2026-04-15T15:12:57Z', 'updatedAt': '2026-05-04T19:55:26Z', 'closedAt': '2026-05-04T19:55:26Z'}

## Body
**Describe the bug**
Even after running nvflare poc prepare -d [image] -n 2 followed by nvflare poc start -gpu 0, the spawned containers do not have GPU capabilities enabled upon startup.

I am currently using a workaround by setting export GPU2USE='--gpus=0' manually before starting the POC.

**To Reproduce**
Run: nvflare poc prepare -d <your-image-name> -n 2
Run: nvflare poc start -gpu 0
Check for GPU availability inside the container (e.g., check if PyTorch detects CUDA or run nvidia-smi).
Result: GPU is not detected unless the environment variable is manually exported.

**Expected behavior**
The -gpu flag in the nvflare poc start command should automatically configure the containers with the appropriate GPU capabilities without requiring manual environment variable exports.

**Desktop:**
 - OS: ubuntu 22.04
 - Python Version 3.10.12
 - NVFlare Version 2.7.2



## timeline-comments 4300097501 by chesterxgchen; https://github.com/NVIDIA/NVFlare/issues/4445#issuecomment-4300097501; ; 
thanks for reporting, I will take a look


## timeline-comments 4316169061 by YuanTingHsieh; https://github.com/NVIDIA/NVFlare/issues/4445#issuecomment-4316169061; ; 
@Vithor112 

Thanks for reporting!

It looks like we have a bug in the GPU option translation code for `nvflare poc`.

`nvflare poc start -gpu 0` is intended to assign host GPU device `0` to the POC client. In Docker mode, this should be translated to Docker’s device syntax, for example:

    --gpus '"device=0"'

However, the current code translates it as:

    --gpus=0

which does not correctly select GPU device `0` for the container.

We will fix this in the next release. Thanks again for catching this.

