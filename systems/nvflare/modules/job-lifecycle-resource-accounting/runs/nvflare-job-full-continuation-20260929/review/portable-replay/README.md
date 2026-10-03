# Portable component replay checks

All three archived cases exited 0 on 2026-10-03 using the archive runner and separate clean exports of NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

- CR-4 reproduced accepted malformed metadata blocking a valid job; the valid control scheduled.
- CR-7 reproduced fractional free-order rounding that rejected an exact full-capacity request; its control restored capacity.
- CR-24 reproduced the forced STARTED/STOPPED ordering; its ordinary control completed after cleanup.

See [results.json](results.json) and the three logs. These checks validate the portable component entrypoint. They do not turn controlled component schedules into natural production triggers or revalidate the rest of the findings.
