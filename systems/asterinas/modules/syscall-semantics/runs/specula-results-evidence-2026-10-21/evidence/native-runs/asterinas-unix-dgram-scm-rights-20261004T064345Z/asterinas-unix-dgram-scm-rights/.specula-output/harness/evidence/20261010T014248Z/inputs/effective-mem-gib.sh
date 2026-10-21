#!/bin/sh
# Prints reclaimable host memory in GiB: MemFree + Inactive(file).
# MemAvailable is not used because this host sets vm.watermark_scale_factor=2000,
# which subtracts about 24.7 GiB of zone watermarks from it. The user chose this
# measure for the resource gates on 2026-10-09.
awk '/^MemFree:/{f=$2} /^Inactive\(file\):/{i=$2} END{printf "%.2f\n",(f+i)/1048576}' /proc/meminfo
