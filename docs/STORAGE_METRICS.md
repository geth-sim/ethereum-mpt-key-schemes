# Storage metric definitions

`analysis/extract_storage_metrics.py` implements the aggregation formulas used
for the paper's LevelDB and read-path results. It reads simulator JSON directly
and does not require manual spreadsheet input.

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

The script exports the cumulative or window-delta values for compacted table
count and size, compaction time, compaction read/write volume, mem/L0/non-L0/
seek compaction counts, write delay, total LevelDB I/O, and opened tables.

Non-compaction I/O fields are calculated as:

- Non-compaction read MB: `io.read_mb - compaction.total.read_mb`
- Non-compaction write MB: `io.write_mb - compaction.total.write_mb`

`opened_tables` is an end-checkpoint snapshot and is therefore not subtracted
between checkpoints. The compaction/storage summary converts LevelDB MB
counters to GB by dividing by 1,000 and database bytes to GB by dividing by
1,000,000,000, which matches the manuscript's displayed units.

### Compaction/storage summary provenance

| Displayed field | Raw file | JSON field | Calculation |
|---|---|---|---|
| Time (s) | `leveldb_stats_*.json` | `compaction.total.time_sec` | Direct |
| Read (GB) | `leveldb_stats_*.json` | `compaction.total.read_mb` | Divide by 1,000 |
| Write (GB) | `leveldb_stats_*.json` | `compaction.total.write_mb` | Divide by 1,000 |
| Mem | `leveldb_stats_*.json` | `compaction_count.mem_comp` | Direct |
| L0 | `leveldb_stats_*.json` | `compaction_count.level0_comp` | Direct |
| Non-L0 | `leveldb_stats_*.json` | `compaction_count.non_level0_comp` | Direct |
| # of SSTs | `leveldb_stats_*.json` | `opened_tables` | End-checkpoint snapshot |
| Size (GB) | `simBlocks/*.json` | final checkpoint's `DiskSize` | Divide by 1,000,000,000 |

The script retains additional diagnostics in `read_metrics.csv` and
`leveldb_metrics.csv`. `read_path_summary.csv` and
`compaction_storage_summary.csv` contain the compact displayed fields.
