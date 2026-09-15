# 3060: Custom Script Changes Not Reflected During Execution in NVFlare

State: CLOSED

I'm using a custom script for `tf/fedopt_ctl` with the example in `my_new_home/NVFlare/examples/getting_started/tf`. I commented out line 127 of the code in  `fedopt_ctl_10` , which should cause an error since `num_trainable_weights` is not defined, but strangely, I don't get any error and the execution continues. 

**To Reproduce**
Steps to reproduce the behavior:
1. Copy `fed_ctl_10.py`.
2. In line 128 of `tf_fl_script_runner_cifar10.py`, change `from fedopt_ctl_10 import FedOpt`.
3. Execute the code.
4. Modify `fed_ctl_10.py` and commented out line 127 of the code.
5. Execute the code again.

**Expected behavior**
get the error  `num_trainable_weights` is not defined

 

**Desktop (please complete the following information):**
 -   ubuntu 22.04
 - Python 3.9.16
 - NVFlare version is 2.5.1


Here are the custom code for fedopt and the logs before and after modification 
 [fedopt_ctl_10.txt](https://github.com/user-attachments/files/17704254/fedopt_ctl_10.txt)
[fedopt_ctl_log_before_modification.txt](https://github.com/user-attachments/files/17704266/fedopt_ctl_log_before_modification.txt)
[fedopt_ctl_log_after_modification.txt](https://github.com/user-attachments/files/17704459/fedopt_ctl_log_after_modification.txt)



## Comment 2479061301 https://github.com/NVIDIA/NVFlare/issues/3060#issuecomment-2479061301

@falibabaei The root cause of this issue is because of the wrong indentation in your fedopt_ctl_10.py. The "def update_model(self, global_model: FLModel, aggr_result: FLModel):" has an extra indentation which makes this method unreachable. So your modified codes were not got executed.

## Comment 2479923637 https://github.com/NVIDIA/NVFlare/issues/3060#issuecomment-2479923637

ah it happend during the copy. Sorry 
