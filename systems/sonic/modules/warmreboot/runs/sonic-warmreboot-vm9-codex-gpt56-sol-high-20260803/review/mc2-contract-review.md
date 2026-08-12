# MC-2 contract review

## Question

Does MC-2 depend on an unsupported administrative operation: running `sonic-package-manager install --enable` during warm finalization?

## Conclusion

The operation is in the supported management surface, and current code contains no admission guard that makes it invalid during warm finalization. The defect is therefore recordable either as missing barrier coordination or, if maintainers choose to define that interleaving as unsupported, as a missing guard that should reject/defer the command.

## Evidence

- The official SONiC Application Extension HLD says the framework lets SONiC be extended at runtime and integrate extensions with warm and fast restarts:
  [`sonic-net/SONiC@c334d5c.../sonic-application-extention-hld.md#L98-L108`](https://github.com/sonic-net/SONiC/blob/c334d5cbb1cd7c76500bcdcdadbdab2e627869a8/doc/sonic-application-extension/sonic-application-extention-hld.md#L98-L108).
- The same HLD requires CLI package installation/uninstallation, cold and warm upgrades, and registration of packages as optional FEATUREs:
  [`#L120-L128`](https://github.com/sonic-net/SONiC/blob/c334d5cbb1cd7c76500bcdcdadbdab2e627869a8/doc/sonic-application-extension/sonic-application-extention-hld.md#L120-L128).
- The HLD documents `sonic-package-manager install --enable` as enabling the feature after install:
  [`#L449-L475`](https://github.com/sonic-net/SONiC/blob/c334d5cbb1cd7c76500bcdcdadbdab2e627869a8/doc/sonic-application-extension/sonic-application-extention-hld.md#L449-L475).
- Package upgrade is documented for features that support warm upgrade:
  [`#L536-L575`](https://github.com/sonic-net/SONiC/blob/c334d5cbb1cd7c76500bcdcdadbdab2e627869a8/doc/sonic-application-extension/sonic-application-extention-hld.md#L536-L575).
- The package manifest's `processes/[name]/reconciles` flag explicitly tells the warmboot finalizer which processes it must wait for:
  [`#L1233-L1276`](https://github.com/sonic-net/SONiC/blob/c334d5cbb1cd7c76500bcdcdadbdab2e627869a8/doc/sonic-application-extension/sonic-application-extention-hld.md#L1233-L1276).
- The listed restrictions do not prohibit runtime install during warm finalization:
  [`#L1490-L1495`](https://github.com/sonic-net/SONiC/blob/c334d5cbb1cd7c76500bcdcdadbdab2e627869a8/doc/sonic-application-extension/sonic-application-extention-hld.md#L1490-L1495).
- Merged `sonic-net/sonic-utilities#1554` is specifically titled "support warm/fast reboot for extension packages" and explains that install/uninstall/upgrade regenerates reboot/finalizer files:
  [`sonic-utilities#1554`](https://github.com/sonic-net/sonic-utilities/pull/1554).

Current source confirms the path:

- `install --enable` says it sets the feature default state to enabled and enables it after installation:
  [`sonic_package_manager/main.py#L394-L460`](https://github.com/sonic-net/sonic-utilities/blob/57b74eed0ee8858556e9b9094fc33d4873ce4f38/sonic_package_manager/main.py#L394-L460).
- Package operations use only the package-manager lock, not a warm-finalizer lock:
  [`manager.py#L91-L100`](https://github.com/sonic-net/sonic-utilities/blob/57b74eed0ee8858556e9b9094fc33d4873ce4f38/sonic_package_manager/manager.py#L91-L100).
- Install creates the service and regenerates shutdown sequence files:
  [`manager.py#L400-L461`](https://github.com/sonic-net/sonic-utilities/blob/57b74eed0ee8858556e9b9094fc33d4873ce4f38/sonic_package_manager/manager.py#L400-L461).
- Service creation generates `/etc/sonic/<service>_reconcile` before FEATURE registration, using manifest processes where `reconciles` is true:
  [`creator.py#L163-L195`](https://github.com/sonic-net/sonic-utilities/blob/57b74eed0ee8858556e9b9094fc33d4873ce4f38/sonic_package_manager/service_creator/creator.py#L163-L195),
  [`creator.py#L518-L532`](https://github.com/sonic-net/sonic-utilities/blob/57b74eed0ee8858556e9b9094fc33d4873ce4f38/sonic_package_manager/service_creator/creator.py#L518-L532).
- `featured` processes FEATURE SET events, maps a new enabled feature to `enable_feature`, and starts the systemd unit:
  [`featured#L186-L224`](https://github.com/sonic-net/sonic-host-services/blob/0c3c0550ff67b90358681ff0cc579fba187c93e2/scripts/featured#L186-L224),
  [`featured#L269-L318`](https://github.com/sonic-net/sonic-host-services/blob/0c3c0550ff67b90358681ff0cc579fba187c93e2/scripts/featured#L269-L318),
  [`featured#L520-L559`](https://github.com/sonic-net/sonic-host-services/blob/0c3c0550ff67b90358681ff0cc579fba187c93e2/scripts/featured#L520-L559).
- The current finalizer snapshots `/etc/sonic/*_reconcile` once at startup and derives static service/component lists from that map:
  [`finalize-warmboot.sh#L16-L27`](https://github.com/sonic-net/sonic-buildimage/blob/544f52cb3abf45287ac81829ba855fc1950fac52/files/image_config/warmboot-finalizer/finalize-warmboot.sh#L16-L27),
  [`#L62-L100`](https://github.com/sonic-net/sonic-buildimage/blob/544f52cb3abf45287ac81829ba855fc1950fac52/files/image_config/warmboot-finalizer/finalize-warmboot.sh#L62-L100).
- It waits only for those captured components and then finalizes globally:
  [`#L237-L302`](https://github.com/sonic-net/sonic-buildimage/blob/544f52cb3abf45287ac81829ba855fc1950fac52/files/image_config/warmboot-finalizer/finalize-warmboot.sh#L237-L302).
- The unit has no ordering or mutual exclusion with package management or `featured`:
  [`warmboot-finalizer.service#L1-L11`](https://github.com/sonic-net/sonic-buildimage/blob/544f52cb3abf45287ac81829ba855fc1950fac52/files/image_config/warmboot-finalizer/warmboot-finalizer.service#L1-L11).

## Reproduced consequence

The current-source reproduction uses the real finalizer and real `service_mgmt.sh`. The fixture supplies SONiC DB/CLI responses because this host is not a SONiC image. Level 2 is admissible because the injected late reconcile file is exactly the durable state produced by the public install path above.

The finalizer omits `latecomp`, disables the global warm flag while `latecomp` remains `restoring`, and then the real service-management consumer chooses `stop`. The positive control proves the same consumer chooses `kill` while the global warm flag is still true.
