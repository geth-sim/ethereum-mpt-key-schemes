# Storage metric definitions

`analysis/extract_storage_metrics.py` implements the aggregation formulas used
for the paper's LevelDB and read-path results. It reads simulator JSON directly
and does not require manual spreadsheet input.

## Measurement modes

| Paper result | Selected mode | Window | Output |
|---|---|---|---|
| Table 2: negative lookups and cache hits | `--variant stats` | 5M–10M | `read_path_summary.csv` |
| Table 3: compaction and live SSTs | `--variant fast` | Cumulative through 10M; SST snapshot at 10M | `compaction_storage_summary.csv` |
| Write-stall counts and duration | `--variant fast` | Cumulative through 10M | `leveldb_metrics.csv` |

The mode selects cases within the input report. A report containing both fast
and stats cases requires `--variant`; a single-mode report can omit it. Fast
LevelDB statistics are extracted without `read_stats`. Stats-mode compaction
statistics are also exported for diagnostics, but are not the source for the
paper's Table 3 or write-stall claims.

Use separate output directories for the two modes, as in the README.
JSON and detailed metric CSVs record `variant`, and Markdown summaries
identify the mode.
Fast runs have no detailed read counters: their JSON `read` and
`read_path_summary` values are `null`, and no `read_metrics.csv` or
`read_path_summary.csv` is emitted. If an output directory is reused for a
fast analysis, old read CSVs are removed so that stats results are not left
beside the new fast results. Summaries use case IDs when multiple selected
configurations share a scheme name.

For a block window `(start, end]`, cumulative counters at `start` are
subtracted from those at `end` before ratios are calculated. With
`start = 0`, the end checkpoint is used as-is.

## Read-path metrics

Let `R` be `ReadRequestCount`. `FakeLevels["0"]` is the L0 fake lookup count;
`FakeLevel0Attempts` is retained as a separate diagnostic counter.

- Negative SSTable lookups per read:
  `sum(FakeLevels[L0:]) / R`
- Fake disk lookups per read:
  `sum(FakeLevels[L0:]) / R`
- All fake lookups per read:
  `(sum(FakeMems) + sum(FakeLevels[L0:])) / R`
- Cache hit rate for data, filter, or index blocks:
  `100 * hits / (hits + misses)`, reported as a percentage
- Bloom false-positive rate:
  `BloomFalsePositiveCount / (BloomFalsePositiveCount + BloomMissCount)`
- Bloom positive predictive value:
  `1 - BloomFalsePositiveCount / BloomHitCount`
- Bloom skip rate:
  `BloomMissCount / (BloomHitCount + BloomMissCount)`

The read-path summary uses `fake (w/o mem, imm) / request`: it excludes
in-memory fake lookups but includes L0 and every lower on-disk level.
The L1-and-below subtotal remains available as `fake_non_l0_lookups`, but it is
not the summary's negative-lookup numerator. A zero denominator is emitted as
JSON `null`, CSV blank, and Markdown `N/A`.

### Read-path summary provenance

| Displayed field | Raw file | JSON field(s) | Calculation |
|---|---|---|---|
| Negative Lookups | `read_stats_*.json` | `ReadRequestCount`, `FakeLevels` | `sum(FakeLevels[L0:]) / ReadRequestCount` |
| Hit Rate (%) | `read_stats_*.json` | `CacheHitCounts["data-block"]`, `CacheMissCounts["data-block"]` | `100 * hit / (hit + miss)` |

## LevelDB metrics

Compaction time, compaction read/write volume, mem/L0/non-L0/seek compaction
counts, write delay, and total LevelDB I/O are cumulative counters. The script
exports their end values or window differences.

`compaction.total.tables` and `compaction.total.size_mb` describe the live
SSTables at the end checkpoint, summed over all levels. They are exported as
`sstable_count` and `sstable_size_mb` and are never subtracted between
checkpoints. These replace the misleading `compacted_tables` and
`compacted_size_mb` output names.

Non-compaction I/O fields are calculated as:

- Non-compaction read MB: `io.read_mb - compaction.total.read_mb`
- Non-compaction write MB: `io.write_mb - compaction.total.write_mb`

`opened_tables` is the table-cache population, not the total SSTable count.
It is retained as a separate end-checkpoint diagnostic and is not subtracted
between checkpoints. The compaction/storage summary converts decimal MB
fields to GB by dividing by 1,000. Its `Size (GB)` column uses the live SST
size for **every scheme**, rather than the whole DB directory size. This
excludes separate state-history files (including P's), WAL and metadata files.
`DiskSize - HistorySize` can still include non-SST files and is not an
alternative formula for this column.

The simulator's whole-directory byte measurement is retained as
`disk_size_bytes` in `leveldb_metrics.csv`; divide it by 1,000,000,000 for GB.
It remains the source for results explicitly measuring total directory size,
including Table 4 at 9M. It need not round to the same value as the SST sum.
In short validation runs, the SST sum can be zero before any memtable flush,
even while WAL and other files give the directory a nonzero size.

### Compaction/storage summary provenance

| Displayed field | Raw file | JSON field | Calculation |
|---|---|---|---|
| Time (s) | `leveldb_stats_*.json` | `compaction.total.time_sec` | Direct |
| Read (GB) | `leveldb_stats_*.json` | `compaction.total.read_mb` | Divide by 1,000 |
| Write (GB) | `leveldb_stats_*.json` | `compaction.total.write_mb` | Divide by 1,000 |
| Mem | `leveldb_stats_*.json` | `compaction_count.mem_comp` | Direct |
| L0 | `leveldb_stats_*.json` | `compaction_count.level0_comp` | Direct |
| Non-L0 | `leveldb_stats_*.json` | `compaction_count.non_level0_comp` | Direct |
| # of SSTs | `leveldb_stats_*.json` | `compaction.total.tables` | End-checkpoint snapshot, summed over all levels |
| Size (GB) | `leveldb_stats_*.json` | `compaction.total.size_mb` | End-checkpoint live SST size across all levels; divide by 1,000 |

The script retains additional diagnostics in `read_metrics.csv` and
`leveldb_metrics.csv`. `read_path_summary.csv` and
`compaction_storage_summary.csv` contain the compact displayed fields.
The Table 3 summary follows the manuscript's row order:
H, PH, PV, PV*, VH, VP, VP*, P, retaining only the available schemes.

The write-stall claims in §5.1 use the fast run's `write_delay.delay_n` and
`write_delay.delay_sec`, exported in `leveldb_metrics.csv` as
`write_delay_count` and `write_delay_seconds`. Use the paper's cumulative
endpoint for cumulative claims, rather than applying the performance window
to every storage metric.

## Backend and compression storage (Table 4)

`analysis/extract_backend_storage.py` reads the E1 H/PV*/VP* fast cases and
the six E6 cases. It extracts `simBlocks.DiskSize` at the selected block and
divides bytes by `10^12` for decimal TB. This works for both LevelDB and
Pebble without requiring LevelDB-specific statistics.

Before SST flushes occur, this directory size can be dominated by WAL files.
At such short endpoints, it does not demonstrate the schemes' SST compression
or storage-size ordering. Compare all nine cases at a larger common block
number to observe those effects.

The README's paper-scale command selects 10M. The manuscript's Table 4 used
9M; select `--end-block 9000000` to compare with those numbers. Without an
explicit `--end-block`, the extractor uses the shared replay target, including
50K for standard validation runs.

`backend_storage.csv` and `.json` contain all nine measurements, their block
number, case IDs and source paths. `backend_storage.md` arranges the values
in the manuscript's order: rows H, VP*, PV*; columns LevelDB/Snappy,
Pebble/Snappy, Pebble/zstd. All nine cases must contain the requested
checkpoint; the extractor does not substitute an earlier block.

## Longer smoke runs for Tables 2–4

`scripts/run_core_smoke.sh` runs H, PV*, and VP* in stats mode through 1M.
Its report supplies the read, compaction, and live-SST measurements for the
smaller-scale Tables 2–3 in the README. Table 3 here is a stats-mode example;
the paper's Table 3 still uses the fast E1 cases.

`scripts/run_table4_smoke.sh` checks for those LevelDB runs' 250K `DiskSize`
checkpoints. If all three are valid, it reuses them; otherwise, it runs
`E1_H`, `E1_PVstar`, and `E1_VPstar` in fast mode through 250K. It then runs
the six E6 Pebble configurations through 250K. Table 4 can therefore run
independently with input prepared only through 250K: six replays when
reusing the 1M smoke, or nine 250K replays without it.

New runs are stored under `runtime/table4-smoke-250000/validation/E1/`
and `E6/`, separately from ordinary validation results. Table 4 is created
in `runtime/table4-smoke-250000/table4/`. All nine sizes refer to the same
250K block, not the final size of any reused 1M run.

Reused LevelDB checkpoints come from stats runs; newly executed cases use
fast mode. Each CSV/JSON row records its actual variant, source case, and
checkpoint; the Markdown table labels the modes and uses MB for readability. Directory
size still includes SSTs, WAL, and metadata, using `simBlocks.DiskSize`.
It does not use compaction counters or replace directory size with SST size.
The runner selects MB with `--unit MB`. The default E1/E6 extractor continues
to require fast cases and display TB.

On the measured host, 250K was beyond the first SST flush for every case
and exposed the storage differences. Flush and compaction timing can vary;
some individual counters, such as non-L0 compactions, may still be zero.
The runner does not force a flush or change the database cache size.

To reuse an existing Pebble report without replaying, run:

```bash
python3 analysis/extract_backend_storage.py \
  runtime/table4-smoke-250000/validation/E6/run-report.json \
  --leveldb-smoke-report runtime/core-smoke-1000000/smoke-report.json \
  --end-block 250000 --output-dir runtime/table4-smoke-250000/table4
```

The runner accepts an alternate smoke report as its first argument and a
replay endpoint via `TARGET_BLOCK`. Missing, incomplete, or unusable smoke
reports trigger the three LevelDB replays. The original smoke files are
preserved. A reusable report must contain completed runs and nonzero
directory-size measurements at the exact selected block. `DiskSize=0`
marks an unsampled block and is rejected. The endpoint must be a multiple
of `SIMULATOR_DISK_SIZE_INTERVAL` (10K by default).
