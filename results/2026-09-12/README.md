# Standalone harness verification — September 12, 2026

A full run of the packaged runner at benchmark repository commit `e0fefa2`:
new private PostgreSQL cluster, newly generated fixtures, 100,000 chats,
1 million messages, three trials per mode, 10,000-message batches, no writers.

All six trials passed the migration checks and extra integrity audits. Their
content, relationship and usage fingerprints match the September 11 dataset
exactly. Their generated migration hashes also match the sources archived in
[the original dataset](../2026-09-11/migrations/).

Median (minimum–maximum), in seconds:

| Mode | Total migration time | Required AI downtime |
| --- | ---: | ---: |
| Rename | 19.73 s (19.48–20.17) | 19.73 s (19.48–20.17) |
| Online copy | 139.88 s (137.31–140.86) | 3.81 s (3.80–4.28) |

This confirms the same trade-off; it does not replace or get pooled with the
original measurements. Both datasets use PostgreSQL 15.19, Ruby 4.0.6,
Active Record 8.1.3.1, the same RubyLLM revision and the same machine. The new
cluster used disk-backed Btrfs storage, 2 GiB shared buffers and the settings
captured in each JSON file. Neither dataset measures concurrent application
writers, job draining, restarts or end-to-end application downtime.

Each JSON additionally records hashes of the runner sources in `bin/` and
`lib/`, the loaded gem revision, batch size and machine information. The Git
checkpoint above preserves those sources and the dependency lockfile. The
runner built all fixtures itself; no pre-existing seed database was reused.

A separate fresh clone also passed both modes with 1,000 chats and 10,000
messages, using the checked-in files and PostgreSQL server tools without
any pre-existing seed database. That
smoke check used 256 MiB shared buffers and temporary memory-backed storage;
its timings are not included in either full-size dataset. The repository's
12 unit/provenance checks passed with 94 assertions.

Recalculate this table with:

```sh
ruby bin/report results/2026-09-12
```
