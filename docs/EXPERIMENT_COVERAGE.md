# Experiment coverage

This document maps the paper experiments to the runnable artifact profiles.
All workloads replay canonical Ethereum mainnet blocks from genesis in their
original order.

## Common paper configuration

| Item | Value |
|---|---|
| Input range | Blocks 0–10,000,000 |
| Reported performance window | Blocks 5,000,000–10,000,000 |
| Primary state mode | Archive |
| Primary backend | LevelDB |
| Primary compression | Snappy |
| Aggregation interval | 100,000 blocks |
| Paper host | Ubuntu 22.04, AMD Ryzen 9 7950X, 128 GB RAM, SSD |

Canonical target hashes, source commits, toolchains, and default simulator
options are pinned in `config.env`.

## Paper results and analysis

E1–E7 follow the revision manuscript's evaluation order. The table adds exact
paper locations to the existing experiment families. All performance analyses
must use the matching baseline, window, and aggregation definition; an overall
speedup and a maximum speedup are different calculations.

| Paper result | Cases / inputs | Output and analysis |
|---|---|---|
| §5.1, Figure 5(a): block execution time | E1 fast | `generate_experiment_graphs.sh E1 paper`; `E1/graphs/compare_block_execute_time.png` |
| §5.1, Figure 5(b): speedup relative to H | E1 fast; H baseline | Same E1 command; `E1/graphs/compare_block_speedup.png`; matching-window H/case ratios |
| §5.1, Figure 6: read time | E1 fast | Same E1 command; `E1/graphs/compare_read_time.png` |
| §5.1, Figure 7: write time | E1 fast | Same E1 command; `E1/graphs/compare_write_time.png` |
| §5.1, Table 2: negative lookups and data-block cache hits | E1 stats; read-stat checkpoints at 5M and 10M | `analyze_storage_metrics.sh <E1-report> --variant stats --start-block 5000000 --end-block 10000000`; `read_path_summary.csv` |
| §§5.1–5.2, Table 3: compaction, SST count, SST size | E1 fast at 10M | `analyze_storage_metrics.sh <E1-report> --variant fast --start-block 0 --end-block 10000000`; `compaction_storage_summary.csv`; endpoint `compaction.total.size_mb / 1000` for GB |
| §5.1, write-stall counts and duration in text | E1 fast at 10M | Same fast-mode command as Table 3; `write_delay_count` and `write_delay_seconds` in `leveldb_metrics.csv`; cumulative endpoint for cumulative claims |
| §5.2, randomized-key/value compression analysis | E2 using E1 PV* database | `rewrite-report.json`: rewrite configuration, entry count and database bytes; bytes / `10^12` for TB |
| §5.3.1, Figure 8: myHash/cache timing | E3 fast plus E1 H/PV*/VP* | `generate_experiment_graphs.sh E3 paper`; `E3/graphs/compare_block_speedup.png`; H baseline; counter-case timings are excluded |
| §5.3.1, child distribution, cache hits and node writes | E3 `*_counters` | `analysis/extract_auth_metrics.py <counter-reports> --start-block 5000000 --end-block 10000000` for the paper's child interval; read/cache metrics share the window, payload estimates use the end count; see [AUTHENTICATION_METRICS.md](AUTHENTICATION_METRICS.md) |
| §5.3.1, approximately 2.7-fold reads with myHash cache | E3 `E3_PVstar_myhash_cache4g_counters` and `E3_PVstar_counters` | Ratio of 5M–10M `ReadRequestCount` differences: read requests issued to LevelDB. Use the storage extractor's `read_metrics.csv` / `read_requests`; see [the calculation commands](AUTHENTICATION_METRICS.md#leveldb-read-requests-for-the-papers-read-ratio). The authentication summary's total-node-read ratio is a separate metric. |
| §5.3.2, Figure 9: authentication-cost approximation | E4 plus E1 H/PV*/VP* | `generate_experiment_graphs.sh E4 paper`; `E4/graphs/compare_block_speedup.png`; Snappy off and 1.125 node-size multiplier |
| §5.3.2, Figure 10: version wrapping | E5 plus E1 H/VH | `generate_experiment_graphs.sh E5 paper`; `E5/graphs/compare_block_speedup.png`; 16-bit / 20-bit wrap compared with unwrapped VH |
| §5.3.2, 0.70/0.43 TB payload estimates | End-point node count from E3 counters | `upper_bound_version4_payload_tb` / `upper_bound_version2_5_payload_tb` in `auth_metrics.csv`; arithmetic upper bounds, not measured disk sizes |
| §5.4, Figure 11: Pebble with Snappy/zstd | E6; the graph command also uses E1 baselines for additional backend comparisons | `generate_experiment_graphs.sh E6 paper`; `E6/graphs/pebble-overview/compare_block_execute_time.png` |
| §5.4, Table 4: backend/compression storage | E6 and corresponding E1 fast cases | `analysis/extract_backend_storage.py <E1-report> <E6-report>`; the artifact's comparison uses 10M, while the manuscript's Table 4 uses 9M |
| §5.4, non-archive text | E7; corresponding E1 cases for archive comparison | `generate_experiment_graphs.sh E7 paper` uses non-archive H; end-point `DiskSize` for storage |

Script names in this table are under `scripts/` unless an `analysis/` path is
shown. Reports reside under `runtime/paper-experiments/<profile>/<E-number>/`;
graph paths above are relative to `runtime/paper-experiments/<profile>/`.
`validation` uses a reduced prefix; it is not a numerical reproduction of
the paper's 5M–10M performance window.

For Table 3, for example:

```bash
./scripts/analyze_storage_metrics.sh \
  runtime/paper-experiments/paper/E1/run-report.json --variant fast \
  --start-block 0 --end-block 10000000 \
  --output-dir runtime/paper-experiments/paper/E1/table3
```

Fast runs already record LevelDB compaction, SST and write-stall statistics;
these do not require detailed read instrumentation. Table 2 uses the separate
stats runs. Keep the two analyses in separate output directories, as shown in
the README. A report containing both modes requires an explicit `--variant`.

**Checkpoint cadence:** E1–E7 use `SIMULATOR_RESULT_SAVE_INTERVAL` (500K by
default) for both the Python client's `simBlocks` saves and Geth's cumulative
read/child/LevelDB snapshots. The final endpoint is also captured when it is
not an exact multiple, including short validation runs. Coincident periodic
and final saves do not append duplicate child snapshots.

Thus the standard paper profile produces both the 5M and 10M read snapshots
needed by Table 2. The analysis subtracts counters before calculating ratios.
Older runs that lack a boundary must supply the original matching statistics
or be rerun; changing the script cannot reconstruct an unrecorded checkpoint.
Table 3 uses cumulative compaction work through 10M and the live SST count
and size at 10M. SST count and size are endpoint snapshots, not differences.

**Exact storage endpoints:** the paper uses 10M for Table 3 and 9M for Table 4.
Table 3's `Size (GB)` is `compaction.total.size_mb / 1000` at 10M for every
scheme. It excludes separate history, WAL and metadata files. Table 4 uses
the exact `simBlocks.DiskSize` record for H/PV*/VP* under LevelDB/Snappy,
Pebble/Snappy and Pebble/zstd. The artifact runs this comparison at 10M:

```bash
python3 analysis/extract_backend_storage.py \
  runtime/paper-experiments/paper/E1/run-report.json \
  runtime/paper-experiments/paper/E6/run-report.json \
  --end-block 10000000 \
  --output-dir runtime/paper-experiments/paper/E6/table4
```

The extractor reads exact checkpoints without loading entire JSON files and
writes CSV, JSON and a Markdown comparison table, labeled with the selected
block. For a numerical comparison with the manuscript's Table 4, change
`--end-block` to `9000000`.

The graph wrapper processes complete or valid partial checkpoints sequentially.
Each curve stops at its completed block, and speedup is limited to the overlap
with the selected baseline. The planned target remains the common x-axis limit.
See [GRAPH_ANALYSIS.md](GRAPH_ANALYSIS.md) for processing and validation details.

## Scheme names

| Paper name | Simulator CLI | Internal method |
|---|---|---|
| H | `H` | `none` |
| P | `P` | `PBSS` |
| PH | `PH` | `HalfPath` |
| PV | `PV` | `PrefixTree` |
| PV* | `PVstar` | `PrefixTree_fixed` |
| VH | `VH` | `TH` |
| VP | `VP` | `JMT` |
| VP* | `VPstar` | `JMT_fixed` |

Reviewers select schemes through the manifest or CLI; no source editing is
required.

## E1: Core schemes

E1 runs H, P, PH, PV, PV*, VH, VP, and VP*.

- Fast runs provide block execution, speedup, read, write, and disk-size data,
  plus the LevelDB compaction/SST/write-stall metrics for Table 3 and the text.
- Stats runs additionally provide the detailed read counters for Table 2's
  negative lookups and cache hits. Their compaction metrics remain available
  as diagnostics; the paper's Table 3 uses fast runs.
- H, PH, PV, PV*, VH, VP, and VP* use archive LevelDB/Snappy.
- P uses its native non-archive PBSS configuration and paper state-history
  setting with the simulator's original cache allocation. Validation changes
  only state-history persistence; it does not define another P cache profile.

```bash
./scripts/run_paper_experiment.sh E1 validation
./scripts/run_paper_experiment.sh E1 paper
```

## E2: Compression source

E2 starts from the corresponding E1 PV* database and creates deterministic
seed-1 rewrites with:

1. randomized keys;
2. randomized values; and
3. randomized keys and values.

Before size measurement, each rewritten database is closed and reopened with
the same LevelDB options as the source to recover pending writes into compressed
SST files, then closed again. The report records entry counts and resulting
database directory sizes. This supports the compression-source discussion in
the paper text; no separate paper table is required.

E2 reuses a completed `E1_PVstar` database from the same profile. If it is
missing, the runner automatically runs just `E1_PVstar` before rewriting it.
This initial replay requires the Ethereum input in MariaDB; reuse does not
require MariaDB to be running.

`TARGET_BLOCK` also works with E2: it sets the end block of the automatic E1
replay, or checks that an existing database ends at that block. Without an
override, E2 uses an existing database's completed range, or the profile's
default range for a new replay. The source report and block number are
recorded in the rewrite report. An existing database with an incomplete,
stale, or mismatched report is left unchanged and reported as an error.

```bash
./scripts/run_paper_experiment.sh E2 validation
./scripts/run_paper_experiment.sh E2 paper
```

Use `./scripts/run_paper_experiment.sh E2 list` to see the rewrite case IDs.
Append a case ID to run just that rewrite, for example:

```bash
./scripts/run_paper_experiment.sh E2 validation E2_random_values
```

An individual rewrite writes `rewrite-report_<case-id>.json` and
`simulator_<case-id>.log` under the E2 result directory.

Simulator progress (every 100,000 entries: processed nodes, key/value bytes
and elapsed time) is streamed to the terminal and also retained in
`runtime/paper-experiments/<profile>/E2/simulator.log`. The client labels each
of the three stages and prints its final size, entry count and elapsed time.

For another terminal:

```bash
tail -f runtime/paper-experiments/paper/E2/simulator.log
jq '{status, current_stage, completed_rewrites: (.rewrites | length)}' \
  runtime/paper-experiments/paper/E2/rewrite-report.json
```

The report is updated after each stage and retains completed stages on an
error or interruption. Progress is an entry count rather than a claimed
percentage: the runner does not scan the full source DB just to count entries.
Ctrl-C can stop the run.

## E3: myHash and cache

E3 adds PV*/VP* cases with:

- myHash and no cache;
- a unified 4 GiB myHash cache;
- a split 2 GiB + 2 GiB myHash cache; and
- a unified 8 GiB cache for the supplementary paper profile.

Together with the relevant E1 baselines, their block execution times provide
the myHash and cache comparison.

Separate `E3_<scheme>_counters`, `E3_<scheme>_myhash_counters`, and
`E3_<scheme>_myhash_cache4g_counters` cases enable the existing child/read
instrumentation for the text measurements in §5.3.1. All use the stats build.
Their timings are excluded from the Figure 8 comparison. The options, raw
files, and analysis commands are documented in
[AUTHENTICATION_METRICS.md](AUTHENTICATION_METRICS.md).

```bash
./scripts/run_paper_experiment.sh E3 validation
./scripts/run_paper_experiment.sh E3 paper
```

## E4: Decoupled-authentication approximation

E4 runs PV* and VP* with Snappy disabled and random padding that multiplies
each serialized trie node size by 1.125. Together with the relevant E1
baselines, these runs provide the decoupled-authentication approximation.

```bash
./scripts/run_paper_experiment.sh E4 validation
./scripts/run_paper_experiment.sh E4 paper
```

## E5: Version-size sensitivity

E5 runs VH with:

- `0xfffff` wrapping for a 20-bit version space; and
- `0xffff` wrapping for a 16-bit version space.

The E1 VH case is the unwrapped baseline for the version-size comparison.

```bash
./scripts/run_paper_experiment.sh E5 validation
./scripts/run_paper_experiment.sh E5 paper
```

A validation range must exceed 65,535 blocks to observe the 16-bit wrap and
approximately 1M blocks to observe the 20-bit wrap. The default 50K profile
checks configuration and execution only.

## E6: PebbleDB and compression

E6 runs:

| Scheme | Pebble + Snappy | Pebble + zstd |
|---|---:|---:|
| H | yes | yes |
| PV* | yes | yes |
| VP* | yes | yes |

Together with the corresponding E1 LevelDB cases, these runs provide backend,
compression, execution-time, speedup, and storage comparisons. Disk size is
read from `simBlocks.DiskSize` at the requested paper checkpoint.

```bash
./scripts/run_paper_experiment.sh E6 validation
./scripts/run_paper_experiment.sh E6 paper
```

If a host cannot complete a case, the runner retains its logs and completed
checkpoint files and continues with the remaining configurations.

## E7: Non-archive

E7 runs H, PV*, and VP* with non-archive LevelDB/Snappy. Together with the
archive E1 baselines, these runs provide non-archive execution and storage
comparisons. Storage size uses `simBlocks.DiskSize`.

```bash
./scripts/run_paper_experiment.sh E7 validation
./scripts/run_paper_experiment.sh E7 paper
```

## Output classes

Replay cases write:

- `simBlocks`: per-block execution, read/write, and disk-size fields;
- `leveldb_stats`: cumulative LevelDB properties and compaction metrics;
- `read_stats`: detailed lookup/cache/Bloom counters for stats cases;
- `additional_node_stats.txt`: child-pointer and node-write snapshots when
  `child_stats` is enabled, recorded in the run report;
- the simulator database; and
- simulator/client diagnostic logs.

Experiment and output paths are defined by
`experiments/paper-experiments.json` and the generated case directories.

Metric formulas and raw field provenance are documented in
`docs/STORAGE_METRICS.md`.

## Plotting experiment families

The wrapper selects the paper-defined cases and speedup baseline:

```bash
./scripts/generate_experiment_graphs.sh E1 paper
./scripts/generate_experiment_graphs.sh E3 paper
./scripts/generate_experiment_graphs.sh E4 paper
./scripts/generate_experiment_graphs.sh E5 paper
./scripts/generate_experiment_graphs.sh E6 paper
./scripts/generate_experiment_graphs.sh E7 paper
```

Use `validation` instead of `paper` for reduced runs. E6 is split into an
all-Pebble overview, Snappy/zstd speedup comparisons, and per-scheme
backend/compression directories because each speedup must use its corresponding
H run as the baseline. The underlying `scripts/generate_graphs.sh` remains
available for custom case selections.

The generated `core-window-summary.csv` also contains `disk_size_bytes` for
each aggregation window. Check the row's `block_end` before using it for a
paper checkpoint. For the backend/compression storage comparison, use
`analysis/extract_backend_storage.py` as shown above; no separate
database-directory scan is needed.
