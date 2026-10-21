## Hunting configuration coverage

| Config | BFS distinct states | Depth | Result |
|---|---:|---:|---|
| `MC_hunt_s1_exfat.cfg` | 519 | 18 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s1_ext2.cfg` | 710 | 19 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s1_growth_exfat.cfg` | 359 | 21 | MC-2; SuccessfulTransferAccounting |
| `MC_hunt_s1_growth_ext2.cfg` | 627 | 29 | Complete BFS; no violation |
| `MC_hunt_s1_growth_ramfs.cfg` | 885 | 26 | MC-1; SuccessfulTransferAccounting |
| `MC_hunt_s1_growth_resize_exfat.cfg` | 231 | 16 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s1_growth_resize_ext2.cfg` | 468 | 23 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s1_growth_resize_ramfs.cfg` | 550 | 21 | MC-1; SuccessfulTransferAccounting |
| `MC_hunt_s1_ramfs.cfg` | 562 | 15 | MC-1; SuccessfulTransferAccounting |
| `MC_hunt_s1_ramfs_offset.cfg` | 872 | 27 | MC-1; ControlledOffsetAccounting |
| `MC_hunt_s1_ramfs_suffix.cfg` | 869 | 26 | MC-1; UnreportedReadSuffixUnchanged |
| `MC_hunt_s2_exfat_accounting.cfg` | 296 | 20 | MC-3; SuccessfulTransferAccounting |
| `MC_hunt_s2_exfat_extent.cfg` | 848 | 29 | MC-3; SettledReadableExtent |
| `MC_hunt_s2_exfat_fault.cfg` | 564 | 19 | MC-3; SuccessfulTransferAccounting |
| `MC_hunt_s2_exfat_preserve.cfg` | 823 | 29 | MC-3; ExtendersPreserveExtent |
| `MC_hunt_s2_ext2.cfg` | 1228 | 41 | Complete BFS; no violation |
| `MC_hunt_s2_ramfs.cfg` | 1955 | 37 | Complete BFS; no violation |
| `MC_hunt_s2_shrink_exfat.cfg` | 252 | 21 | MC-3; SuccessfulTransferAccounting |
| `MC_hunt_s2_shrink_ext2.cfg` | 721 | 34 | Complete BFS; no violation |
| `MC_hunt_s2_shrink_ramfs.cfg` | 981 | 32 | Complete BFS; no violation |
| `MC_hunt_s3_cold_tail_exfat.cfg` | 105 | 17 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s3_exfat.cfg` | 735 | 35 | MC-5; HoleZeros |
| `MC_hunt_s3_ext2.cfg` | 976 | 47 | Complete BFS; no violation |
| `MC_hunt_s3_extend_zero_exfat.cfg` | 66 | 8 | MC-4; SuccessfulResizeContract |
| `MC_hunt_s3_holes_exfat.cfg` | 512 | 35 | MC-5; HoleZeros |
| `MC_hunt_s3_holes_ext2.cfg` | 1003 | 48 | Complete BFS; no violation |
| `MC_hunt_s3_holes_ramfs.cfg` | 1051 | 44 | Complete BFS; no violation |
| `MC_hunt_s3_ramfs.cfg` | 1051 | 44 | Complete BFS; no violation |
| `MC_hunt_s3_regrow_exfat.cfg` | 131 | 21 | MC-4; SuccessfulResizeContract |
| `MC_hunt_s3_regrow_ext2.cfg` | 956 | 40 | Complete BFS; no violation |
| `MC_hunt_s3_regrow_ramfs.cfg` | 1266 | 39 | Complete BFS; no violation |
| `MC_hunt_s4_empty_exfat.cfg` | 13 | 13 | MC-7; EmptyWriteNoEffect |
| `MC_hunt_s4_empty_ext2.cfg` | 5 | 5 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s4_empty_ramfs.cfg` | 10 | 10 | MC-6; EmptyWriteNoEffect |
| `MC_hunt_s4_fault_exfat.cfg` | 107 | 28 | Complete BFS; no violation |
| `MC_hunt_s4_fault_ext2.cfg` | 85 | 27 | Complete BFS; no violation |
| `MC_hunt_s4_fault_ramfs.cfg` | 83 | 27 | MC-8; AcceptedExtent |
| `MC_hunt_s4_read_fault_exfat.cfg` | 37 | 10 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s4_read_fault_ext2.cfg` | 37 | 10 | Complete BFS; simulation follow-up pending |
| `MC_hunt_s4_read_fault_ramfs.cfg` | 41 | 11 | Complete BFS; simulation follow-up pending |
