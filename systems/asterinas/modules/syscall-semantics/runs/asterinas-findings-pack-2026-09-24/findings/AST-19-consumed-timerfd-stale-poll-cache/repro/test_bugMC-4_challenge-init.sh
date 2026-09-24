#!/bin/sh

echo "MC4B_GUEST_BOOT smp=2"
/test_bugMC-4_challenge.guest
status=$?
echo "MC4B_GUEST_EXIT status=$status"
sync
poweroff -f
reboot -f

while true; do
    sleep 1
done
