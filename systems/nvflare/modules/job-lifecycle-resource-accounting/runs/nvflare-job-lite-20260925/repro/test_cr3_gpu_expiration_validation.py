"""CR-3: GPUResourceManager documents/validates expiration_period as int-or-float >= 0
(gpu_resource_manager.py:81,99-102) but its base AutoCleanResourceManager requires int > 0
(auto_clean_resource_manager.py:42-45). CR-2 context: free_resources has no ownership check
(auto_clean_resource_manager.py:166-172) — what a double free would do if any caller did it."""
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager
from nvflare.apis.fl_context import FLContext

for v in (30, 30.5, 0):
    try:
        GPUResourceManager(num_of_gpus=0, mem_per_gpu_in_GiB=0, expiration_period=v)
        print(f"GPUResourceManager(expiration_period={v!r}): accepted")
    except Exception as e:
        print(f"GPUResourceManager(expiration_period={v!r}): {type(e).__name__}: {e}")

# CR-2: behavior of an (unreachable-in-supported-flows) double free
m = ListResourceManager(resources={"slot": [0]})
ok, tok = m.check_resources({"slot": 1}, FLContext())
alloc = m.allocate_resources({"slot": 1}, tok, FLContext())
m.free_resources(alloc, tok, FLContext())
m.free_resources(alloc, tok, FLContext())
print("ListResourceManager after double free:", m.report_resources(FLContext()))
