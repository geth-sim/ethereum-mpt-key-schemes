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

- Fast runs provide block execution, speedup, read, write, and disk-size data.
- Stats runs additionally provide the LevelDB/read counters used for the
  read-path and compaction/storage summaries.
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

The report records entry counts and resulting database sizes. This supports
the compression-source discussion in the paper text; no separate paper table
is required.

```bash
./scripts/run_e2_db_rewrites.sh validation
./scripts/run_e2_db_rewrites.sh paper
```

## E3: myHash and cache

E3 adds PV*/VP* cases with:

- myHash and no cache;
- a unified 4 GiB myHash cache;
- a split 2 GiB + 2 GiB myHash cache; and
- a unified 8 GiB cache for the supplementary paper profile.

Together with the relevant E1 baselines, their block execution times provide
the myHash and cache comparison.

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

The generated `core-window-summary.csv` also contains `disk_size_bytes` at
each aggregation checkpoint. Storage comparisons select their requested
checkpoint rows from this CSV; no separate database-directory size scan is
required.
