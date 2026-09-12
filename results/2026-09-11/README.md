# September 11, 2026 measurements

Six successful trials of the actual RubyLLM-generated migrations at commit
`e5827a01a4226a1b4bbf28a4f42c0ff252918443`. The JSON measurements are preserved
from the original runs, before this harness was packaged as a standalone repo.
JSON files have a trailing newline for repository formatting.

Each trial contains 100,000 synthetic chats, 1 million messages, 256-byte text
payloads and no concurrent writers. All integrity checks passed. The
`migration_hashes` fields identify the generated files retained under
`migrations/`. Hashes are SHA-256 of the complete generated source, including
its timestamped migration version references where present.

Median (minimum–maximum), in seconds:

| Mode | Total migration time | Required AI downtime |
| --- | ---: | ---: |
| Rename | 20.09 s (19.82–20.15) | 20.09 s (19.82–20.15) |
| Online copy | 136.43 s (135.11–137.23) | 3.74 s (3.73–3.79) |

Run `ruby bin/report` from the repository root to recalculate this table. The
root README defines the timing boundaries and limitations. Additional source,
legacy and target audits are recorded in `phases` but excluded from the totals.

The database identifiers are randomly named disposable synthetic databases,
not application database names. `gem_commit` is the RubyLLM revision, not a
revision of this later standalone repository. New trials also record harness
source hashes so their exact runner can be identified.
