# Ethereum MPT Key-Scheme Artifact

This repository downloads a pinned Ethereum mainnet prefix, replays it from
genesis under multiple MPT key schemes, and produces timing, storage, LevelDB,
and read-path statistics.

Reduced runs are functional checks. The paper reports trends over blocks
5M–10M; use the full-scale E1–E7 profiles to evaluate those trends.

## Execution profiles

| Profile | Range | Purpose | Reference time |
|---|---:|---|---:|
| Quick check | 0–100K | Build, prepare the shared 1M input, replay H, and validate output | About 5–10 minutes |
| Stats smoke | 0–500K | Run H, PV*, and VP* with detailed LevelDB instrumentation | About 30 minutes after input preparation |
| Extended stats | 0–1M | Exercise the wider read-stat counter set | About 65 minutes after input preparation |
| E1–E7 validation | 0–50K | Check every experiment configuration with real transactions | About 30 minutes |
| E1–E7 paper | 0–10M | Reproduce the paper-scale experiments | Several days per case |

Measured times are host and storage dependent and are not pass/fail criteria.

## Requirements

Tested environment:

- Ubuntu 22.04 LTS, x86-64
- at least 8 GB RAM for the quick check
- at least 16 GB RAM for the reduced multi-case runs
- Go with automatic toolchain selection support
- Python 3.10 or later
- Git, GNU Make, a C compiler, `curl`, and `jq`
- outbound HTTPS access; outbound Ethereum P2P access is used only by the
  fallback input method
- an open-file limit above 1,000
- MariaDB 10.10+ and PyMySQL for stats and E1–E7 runs
- about 5 GB free space for the quick check, 20 GB for the 1M stats smoke,
  and 60 GB when retaining every 100K E1–E7 validation database

Ubuntu/Debian packages:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git curl jq python3 python3-pip python3-venv \
  mariadb-server python3-pymysql
ulimit -n
```

The scripts pin:

- upstream geth v1.17.3 for input acquisition;
- the modified geth artifact commit;
- fast and instrumented goleveldb commits;
- Go 1.24.13 for the sync client and Go 1.21.13 for the simulator; and
- the data-analysis commit and its Python dependencies.

Exact revisions and canonical block hashes are in
[`config.env`](config.env).

## Quick check

From the repository root:

```bash
./scripts/reproduce.sh
```

This command builds every dependency, downloads and imports a checksum-verified
Ethereum mainnet ERA prefix through block 1M, starts a local RPC and simulator,
replays H from genesis through block 100K, and validates the result structure.
The prepared 1M input is reused by all reduced profiles.

Success ends with:

```text
QUICK REPLAY: PASS
REPRODUCIBILITY QUICK CHECK: PASS
```

The state root is not a pass condition because it depends on the selected key
scheme.

Primary outputs:

```text
runtime/quick-summary.json
runtime/phase-timings.json
runtime/simulator-db/
runtime/simulator/logFiles/evm/runs/H_archive_leveldb_snappy_fast/
logs/era-download.log
logs/era-import.log
logs/simulator.console.log
```

## Input preparation and replay ranges

Prepare the shared input without starting a long-lived RPC:

```bash
./scripts/build.sh
./scripts/prepare_input.sh
```

For every requested target up to 1M, this prepares blocks 0–1M once. Clients
then select only the range needed by their profile:

```text
quick check       0–100K
stats smoke       0–500K
extended stats    0–1M
E1–E7 validation  0–50K
```

Input acquisition uses these deterministic stages:

```text
checksum-verified ERA download and import
  → retry the configured ERA endpoint(s)
  → P2P target sync fallback
  → pinned genesis and acquisition-target hash verification
```

ERA and fallback settings are in `config.env`. To disable the P2P fallback:

```bash
INPUT_ACQUISITION_FALLBACK=none ./scripts/prepare_input.sh
```

Start an offline RPC for any supported replay endpoint. The underlying 1M
input is reused:

```bash
source config.env
TARGET_BLOCK="$TARGET_500K_BLOCK" TARGET_HASH="$TARGET_500K_HASH" \
  ./scripts/sync_and_serve.sh
```

If a requested target is larger than 1M, such as the paper-scale 10M endpoint,
input preparation automatically raises the acquisition range to that target.

On the validation host, ERA download, import, and verification took about four
minutes through 1M. Network and storage conditions can change this time.

## MariaDB input cache

Stats and E1–E7 runs reuse a local MariaDB copy of the canonical blocks and
transactions. Start the artifact-local server in a separate terminal:

```bash
./scripts/start_mariadb.sh
```

With the matching geth RPC still open, import 1M once so every reduced profile
can select its own prefix:

```bash
source config.env
TARGET_BLOCK="$TARGET_1M_BLOCK" TARGET_HASH="$TARGET_1M_HASH" \
  ./scripts/import_mariadb.sh
```

The importer is resumable. A smaller import may still be requested with the
matching `TARGET_100K_*` or `TARGET_500K_*` values, and a later 1M import starts
after the last stored block. Use `TARGET_10M_*` for paper-scale input.

## Stats smoke

After preparing MariaDB through at least 500K:

```bash
./scripts/run_core_smoke.sh
```

This runs H, PV*, and VP* with the instrumented binary. Each case produces:

- per-block `simBlocks`;
- cumulative `leveldb_stats`; and
- detailed `read_stats` checkpoints.

Outputs are isolated under:

```text
runtime/core-smoke-500000/
├── databases/
├── logs/
├── simulator-output/logFiles/evm/runs/
└── smoke-report.json
```

To run the optional 1M version after importing MariaDB through 1M:

```bash
source config.env
TARGET_BLOCK="$TARGET_1M_BLOCK" TARGET_HASH="$TARGET_1M_HASH" \
  ./scripts/run_core_smoke.sh
```

## E1–E7 experiments

The case matrix is
[`experiments/paper-experiments.json`](experiments/paper-experiments.json).
List a family with:

```bash
./scripts/run_paper_experiment.sh E1 list
```

The `validation` profile uses blocks 0–50K. This prefix includes 1,871
transactions and is sufficient to check configuration and output paths. Any
MariaDB prefix of at least 50K can be reused.

Run every validation family:

```bash
for experiment in E1 E3 E4 E5 E6 E7; do
  ./scripts/run_paper_experiment.sh "$experiment" validation
done
./scripts/run_e2_db_rewrites.sh validation
```

Run a paper-scale family or a single case:

```bash
./scripts/run_paper_experiment.sh E1 paper
./scripts/run_paper_experiment.sh E1 paper E1_PVstar
./scripts/run_e2_db_rewrites.sh paper
```

E2 consumes the corresponding E1 PV* database, so run E1 before E2.

| ID | Configurations | Result category |
|---|---|---|
| E1 | H, P, PH, PV, PV*, VH, VP, and VP*; fast and stats variants | Core execution, read/write, storage, and detailed LevelDB/read-path metrics |
| E2 | PV* database with randomized keys, values, or both | Compression-source text |
| E3 | PV*/VP* myHash and cache configurations | myHash and cache execution comparison |
| E4 | PV*/VP* without compression and with 1.125 padding | Decoupled-authentication approximation |
| E5 | VH with 20-bit and 16-bit version wrapping | Version-size sensitivity |
| E6 | H/PV*/VP* with Pebble Snappy and zstd | Backend, compression, execution, and storage comparison |
| E7 | H/PV*/VP* in non-archive mode | Non-archive execution and storage comparison |

P uses its paper configuration, including state history, in the `paper`
profile. The reduced validation profile disables its state history only to
avoid spending most of the functional check on persistence unrelated to key
scheme execution. Both profiles retain the simulator's original P cache
allocation; there are no separate buffered/unbuffered P configurations.

Each case keeps its database, simulator output, and logs under:

```text
runtime/paper-experiments/<profile>/<experiment>/<case-id>/
```

Pebble preallocates WAL space: the measured 100K E6 databases occupied about
40 GB on disk although their `simBlocks.DiskSize` values were much smaller.

If a case stops before its requested end block, its logs and any completed
checkpoint outputs must be retained and the runner proceeds to the next case.

Detailed scheme and experiment settings are summarized in
[`docs/EXPERIMENT_COVERAGE.md`](docs/EXPERIMENT_COVERAGE.md).

## Result analysis

### Block execution, speedup, read/write time, and disk size

Install the pinned plotting dependencies once:

```bash
python3 -m venv runtime/analysis-venv
runtime/analysis-venv/bin/pip install \
  -r sources/data-analysis/requirements-artifact.txt
```

Generate the six standard plots from the stats smoke:

```bash
ANALYSIS_PYTHON=runtime/analysis-venv/bin/python \
  ./scripts/generate_graphs.sh \
  runtime/core-smoke-500000/smoke-report.json \
  runtime/core-smoke-500000/graphs
```

The plots are:

```text
compare_block_execute_time.png
compare_block_speedup.png
compare_read_time.png
compare_write_time.png
compare_disk_size.png
compare_disk_size_diff_mavg.png
```

The same simulator fields are used for E1, E3–E7. Experiment-specific figures
are generated with the paper-defined baseline and case ordering:

```bash
./scripts/generate_experiment_graphs.sh E1 validation
./scripts/generate_experiment_graphs.sh E3 validation
./scripts/generate_experiment_graphs.sh E4 validation
./scripts/generate_experiment_graphs.sh E5 validation
./scripts/generate_experiment_graphs.sh E6 validation
./scripts/generate_experiment_graphs.sh E7 validation
```

Replace `validation` with `paper` for blocks 5M–10M. E6 creates separate
overview, compression-specific speedup, and per-scheme backend/compression
directories so each speedup uses the matching H baseline. E2 is a database
rewrite and has no block-execution graph family.

### LevelDB and read metrics

Generate the read-path and compaction/storage summaries:

```bash
./scripts/analyze_storage_metrics.sh \
  runtime/core-smoke-500000/smoke-report.json
```

For a 1M cumulative checkpoint or a sub-window:

```bash
./scripts/analyze_storage_metrics.sh \
  runtime/core-smoke-1000000/smoke-report.json \
  --end-block 1000000

./scripts/analyze_storage_metrics.sh \
  runtime/core-smoke-1000000/smoke-report.json \
  --start-block 500000 --end-block 1000000
```

Outputs include:

```text
storage_metrics.json
leveldb_metrics.csv
read_metrics.csv
read_path_summary.csv
compaction_storage_summary.csv
storage_metric_summaries.md
```

The read-path summary calculates negative lookups as all on-disk fake lookups,
including L0, divided by read requests. Data-block cache hit rate is reported
as a percentage. The compaction/storage summary reads size from the final
requested checkpoint's `simBlocks.DiskSize`.

Definitions and source fields are in
[`docs/STORAGE_METRICS.md`](docs/STORAGE_METRICS.md).

## Generated files

Simulator results follow:

```text
runtime/.../logFiles/evm/runs/<experiment-id>/
├── simBlocks/
│   └── evm_simulation_result_<experiment-id>_0_<end>.json
└── leveldbStats/
    ├── leveldb_stats_<experiment-id>_0_<end>.json
    └── read_stats_<experiment-id>_<checkpoint>.json
```

The simulator database is separate from the input geth datadir:

```text
runtime/geth/                 canonical Ethereum input (1M by default)
runtime/input-acquisition/    temporary ERA or P2P fallback work
runtime/simulator-db/         quick-check replay state
runtime/core-smoke-*/databases/
runtime/paper-experiments/*/*/*/database/
```

The experiment ID always includes scheme, archive mode, backend, compression,
binary variant, and active optional features, preventing output collisions.

## Re-running and cleanup

Remove runtime data while keeping sources and binaries:

```bash
./scripts/clean_runtime.sh
```

Remove all reproducible downloads, builds, runtime data, logs, and Python
bytecode:

```bash
./scripts/clean_all_generated.sh
```

The next `./scripts/reproduce.sh` clones, rebuilds, reacquires input, and
replays from scratch.

## Troubleshooting

If ERA input preparation fails, inspect:

```bash
tail -n 100 logs/era-download.log
tail -n 100 logs/era-import.log
tail -n 100 logs/era-verify.log
```

The script then tries the configured P2P fallback. If that also fails, confirm
that outbound Ethereum TCP/UDP traffic is allowed and inspect:

```bash
tail -n 100 logs/geth-target-sync.log
```

If a target hash check fails, stop the run. Use only the block/hash pairs
pinned in `config.env`.

If the simulator exits, inspect the case-specific simulator and client logs.
Completed result checkpoints are not invalidated merely because a later block
failed.

The default ports are geth RPC `28545`, geth P2P `30333`, MariaDB `23306`, and
simulator `28889`. They can be overridden through environment variables.
