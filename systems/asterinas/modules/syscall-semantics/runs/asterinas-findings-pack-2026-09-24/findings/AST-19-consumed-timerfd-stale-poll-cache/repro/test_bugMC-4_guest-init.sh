#!/bin/sh

echo "MC4_GUEST_BOOT smp=2"
/test_bugMC-4_timerfd_cache.guest
status=$?
echo "MC4_GUEST_EXIT status=$status"
sync
poweroff -f
reboot -f

while true; do
    sleep 1
done
