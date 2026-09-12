# RubyLLM migration benchmark

How much work does RubyLLM's 1.16 → 2.0 migration take, and how much of it requires pausing AI activity?

With 100,000 synthetic chats and 1 million messages, **rename finished sooner overall; online copy required less AI downtime**:

| Mode | Total migration time | Required AI downtime |
| --- | ---: | ---: |
| Rename | 20.09 s | 20.09 s |
| Online copy | 136.43 s | 3.74 s |

These are PostgreSQL medians from three runs per mode, recorded September 11, 2026. Both used the actual generated migrations at [RubyLLM e5827a01](https://github.com/crmne/ruby_llm/commit/e5827a01a4226a1b4bbf28a4f42c0ff252918443) with **10,000-message batches**. [Raw results and provenance](results/2026-09-11/README.md) include every trial and the generated migration hashes.

This is a measured trade-off, not a production downtime prediction. Use it alongside the [RubyLLM upgrade guide](https://rubyllm.com/next/upgrading/).

A [full verification run of this standalone harness](results/2026-09-12/README.md) reproduced the same data and migration source hashes, with the same overall trade-off. Its results are recorded separately from the headline measurements.

## What the clocks measure

- **Total migration time:** prepare, backfill and finish, including their built-in validation.
- **Required AI downtime:** all three phases for rename; only finish for online copy.
- Seeding, database cloning, Ruby startup and the benchmark's additional integrity checks are outside both clocks. So are job draining, application restarts and later legacy-data cleanup.

There are **no concurrent writers** in these runs. Copy's final change journal is empty: these timings do not establish how long cutover takes with a live-write backlog. Online preparation can still contend for database resources. There is no application availability probe here; the downtime column times the migration work that requires an AI pause.

The workload has exactly 10 messages per chat and 256-byte text payloads, including structured content, tool calls/results, model references, token counts and stored costs. It does not represent every application's chat lengths or data shape. These are not MySQL/SQLite measurements, model latency tests or provider benchmarks. Everything is synthetic; no API keys or provider requests are needed.

## Reproduce

Requires Linux or macOS, Ruby 3.4+ (recorded with 4.0.6), Bundler and PostgreSQL 15+ **server tools** (`initdb`, `pg_ctl`, `postgres`). The dependency lockfile pins the Ruby libraries and gem revision. For the headline dataset, allow at least 8 GiB RAM and 10 GiB free space on the temporary filesystem; actual needs vary.

```sh
bundle install

# Small end-to-end check: 1,000 chats, both modes, one trial each.
bundle exec ruby bin/bench --chats 1000 --repeats 1 --shared-buffers 256MB

# Headline workload: 100,000 chats × 10 messages, three trials per mode.
bundle exec ruby bin/bench
```

If the server tools aren't on PATH or discoverable via `pg_config`, set `PG_BINDIR` to their bin directory. Use PostgreSQL 15.19 and the recorded hardware/settings for the closest comparison. New versions and machines will produce different times. `--shared-buffers 256MB` allows a smaller-memory smoke test; it is not the headline configuration.

The runner creates a **new private PostgreSQL cluster**, reachable only through its private Unix socket. It never uses `DATABASE_URL`, an application database or an existing server. Run it as a regular user, not root. Database files go under this repository's ignored `tmp/` directory by default. `TMPDIR` overrides that location; choose a disk-backed location when comparing disk-backed results.

Each invocation starts from newly generated fixtures and writes to a new, ignored `results/local/` directory. `--output PATH` selects another **nonexistent** output directory. The runner does not overwrite earlier results or retry failures silently. Successful runs stop PostgreSQL and remove their temporary database files; failed runs stop it and retain those files for inspection. JSON results, generated migrations and logs remain in the output directory.

```sh
# Regenerate the published summary without starting PostgreSQL.
ruby bin/report

# Summarize a new full run (three trials per mode).
ruby bin/report results/local/RUN_DIRECTORY

# Unit checks for result validation and database-target guards.
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'
```

## Method and verification

Each trial uses a fresh clone of the same seed database and an isolated Ruby process. Trial order is rename/copy, copy/rename, rename/copy. Filesystem caches are not cleared. PostgreSQL durability and autovacuum remain enabled.

Before and after migration, row counts and two order-independent fingerprints check message content, chat/model links, tool calls/results, token buckets and costs. Copy additionally checks every original source column, the active version and the drained journal. All six recorded trials passed these checks. Failed trials are retained and cannot enter the summary.

The original environment was PostgreSQL 15.19, Ruby 4.0.6 and Active Record 8.1.3.1 on a Ryzen 5 7500F, 62 GiB RAM and local Btrfs storage with zstd compression. PostgreSQL used 2 GiB shared buffers, 32 MiB work memory and 512 MiB maintenance work memory. See the raw JSON for per-phase timings, storage sizes and settings.

The September 11 records predate this standalone packaging. Their measurements are preserved; the portable runner extracts the same fixture generation, migration calls and timing boundaries. Fresh verification runs are separate evidence, not replacements for the original measurements. This repository does not include earlier experimental migration implementations or attribute their timings to the pinned gem.
