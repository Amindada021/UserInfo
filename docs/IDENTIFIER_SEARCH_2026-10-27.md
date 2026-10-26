# Identifier search change — release acceptance pending

Baseline: `9a601f139df0add757b8bad98a2103499972ac58` (main).

## Findings verified from source

- SQLite schema v8 already has `record_identifiers` and covering B-trees
  `idx_ident_mobile(mobile,record_id)` and `idx_ident_national(national,record_id)`.
- Full identifiers previously used ranges, then sorted all matches by record ID
  before LIMIT. EXPLAIN confirmed a temporary B-tree for the sort.
- Bulk import defers both identifier and name indexing. Until the manual build
  completes, search is incomplete. This change does not eliminate that existing
  dependency or automatically start an expensive index build.
- Existing index normalization converts Persian/Arabic digits but retains country
  prefixes. Query variants now search domestic, 98, +98, 0098 and bare 9 forms.
- Search already has ID cursor pagination, async sqflite operations and stale
  response suppression. Suppression does not cancel running SQLite statements.
- Backup is a streamed raw SQLite file after close/checkpoint; no compression.
  Table payload, indexes/FTS and freelist pages are copied. The actual source of
  the user's 50 GB size is unverified without that file. No automatic VACUUM or
  backup-format change was introduced.

## Implemented

Full-number searches use separate equality seeks, ordered by `ids.record_id`
with LIMIT per representation. At most five pages are merged in memory, with
deduplication and the same descending-ID cursor. Complete national IDs use one
seek. Original values and leading zeroes are preserved.

Prefix input requires at least seven normalized digits. A covering-index probe
reads at most 10,001 candidate IDs before allowing record joins/sorting. Above
10,000 candidates the UI asks for more digits. Wildcards/contains are rejected.
Advanced mobile/national filters share these normalization and breadth rules.
Additional restrictive filters on an exact identifier can still inspect many
matching IDs; that combination is not proven sub-second.

Existing chunked indexing now checks free bytes before each chunk and pauses
below 512 MiB (or on unknown space), retaining its transactional cursor. This is
a safety reserve, not a proven worst-case storage estimate for arbitrary rows.
The existing 2,500-row transaction/cursor recovery remains unchanged.

## Data and update compatibility

No schema change is needed: version remains 8, and existing identifier indexes
are reused. No new startup migration, data rewrite, table drop, database path,
application ID or signing configuration change. App version becomes 0.1.15+16.
Existing migrations from older schemas remain in place; they have not all been
revalidated in this environment.

The existing CI requires persistent signing secrets for main releases. Access
to the installed APK's certificate and compatible private key was not available
here; therefore update compatibility is NOT certified and no installable update
APK was produced. Do not replace an incompatible installed app by uninstalling.

## Validation performed

`python tool/benchmarks/identifier_seek_regression.py` passed, SQLite 3.53.1.
One million synthetic duplicated identifiers, in-memory Linux SQL only, five
repetitions under the same conditions:

| Query | Median ms | Plan |
|---|---:|---|
| Old range + ID order | 204.3668 | covering-index range, PK lookup, temporary sort |
| New equality + ID order | 0.0108 | covering-index equality, PK lookup, no temporary sort |

The results were identical. These figures are NOT a Flutter, Android, disk-I/O,
100M-row or user-data benchmark. They isolate the query-plan regression only.
The full mobile path may perform five seeks, not one.

Added Dart tests for country formats, Persian/Arabic digits, zero preservation,
input rejection, exact pagination and query plans. Existing prefix tests were
updated to the documented seven-digit minimum. Dart/Flutter are unavailable in
this environment, so these tests and APK compilation have NOT been executed.
`git diff --check` passed.

## Outstanding acceptance gates

- Build/analyze and all Flutter tests in CI.
- Real near-100M database measurements on POCO X7 Pro, including cold/warm I/O,
  absent numbers, beginning/middle/end IDs, duplicate-heavy exact matches and
  prefix caps. No personal data should be published in benchmark logs.
- Installed certificate comparison, upgrade-over-existing APK, count/content
  checks and app termination/restart on a disposable copy.
- Large backup/restore round trip and fault injection for low storage and process
  termination. A 50 GB backup cannot fit this environment's 29 GB free storage.
- Independent identifier backfill, initial full storage estimation and verified
  recovery across every legacy schema remain outside this completed patch.

This is a reviewable partial implementation, not a release-ready completion of
the full 100M optimization request. Keep it in draft until the gates are met.
