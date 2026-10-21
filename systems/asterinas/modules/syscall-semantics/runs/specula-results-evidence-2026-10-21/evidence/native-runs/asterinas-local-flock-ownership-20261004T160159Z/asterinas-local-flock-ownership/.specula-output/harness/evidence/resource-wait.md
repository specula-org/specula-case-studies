The reviewed v12 attempt failed its host MemAvailable admission check before apply/build/guest. This is not a kernel failure. The threshold remains 10 GiB. Keep the existing 16 accepted v10 traces and do not lower the overlap requirement. Await host capacity for the corrected end-to-end run.
2026-10-05T14:40:02.206446+00:00 MemAvailable:    9211888 kB
