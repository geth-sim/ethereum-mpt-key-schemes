# Ethereum MPT Key-Scheme Artifact

This artifact replays real Ethereum mainnet blocks to compare MPT key schemes,
authentication costs, and storage configurations. It provides the implementations,
input preparation, experiment runners, and analysis needed to reproduce the
paper's experiments.

Start with the [quick check](#quick-check) to build, download input, and try a
short replay. Then [prepare Ethereum data](#prepare-ethereum-data) for your chosen
experiments, [run them](#run-experiments), and [analyze their results](#analyze-results).
Run all commands from this repository root, including in additional terminals.

## Requirements

- Ubuntu 22.04 LTS, x86-64; Python 3.10+; outbound HTTPS access.
- At least 8 GB RAM and about 5 GB free disk for the quick check; at least
  16 GB RAM for reduced multi-case runs.
- Allow about 100 GB of free disk space for artifact evaluation, excluding
  paper-scale reproduction.
- Git, GNU Make, a C compiler, `curl`, `jq`, and an open-file limit above 1,000.
- MariaDB 10.6+ and PyMySQL for custom runs and paper experiments. The server uses artifact-local data files.

Install the Ubuntu/Debian packages and check the file limit:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git curl jq python3 python3-pip python3-venv \
  mariadb-server python3-pymysql
ulimit -n
```

The build scripts fetch pinned source commits and obtain the required Go
toolchains automatically. Versions, block hashes and defaults are in
[`config.env`](config.env); experiment cases are in
[`experiments/paper-experiments.json`](experiments/paper-experiments.json).
Full-scale cases can take several days each and require much more storage.
The paper's hardware and common settings are listed in the
[experiment guide](docs/EXPERIMENT_COVERAGE.md#common-paper-configuration).

## Quick check

Run this first to check that the artifact builds and executes on your machine.
No Ethereum data needs to be prepared beforehand. With the default settings,
the command automatically:

1. Builds the pinned Geth and simulator dependencies.
2. Downloads or reuses Ethereum mainnet data through **50K**, verifies the
   genesis and target block hashes, and starts a local RPC.
3. Replays blocks **0–50K** with scheme **H**, LevelDB, and Snappy.
4. Checks that the saved results cover the expected block range and contain
   the expected number of transactions.

```bash
./scripts/quick_check.sh
```

This checks installation and basic execution. The quick check reads input
directly from the local RPC and does not require MariaDB. Runtime depends on
the host, network and storage.
All steps have passed when the final status is:

```text
REPRODUCIBILITY QUICK CHECK: PASS
```

If it fails, check the terminal error and the [failure diagnostics](#if-a-run-fails).

## Prepare Ethereum data

Download canonical Ethereum mainnet blocks and transactions, then load them
into MariaDB for custom runs or paper experiments. Each experiment reads the needed
block range from MariaDB and replays the transactions to build its own state database.

If you skipped the quick check, build the dependencies first:

```bash
./scripts/build.sh
```

The data-preparation and replay targets are pinned in [`config.env`](config.env):

| Use | Target block | Target block hash |
|---|---|---|
| Quick check and short validation runs | 50,000 (50K) | `0x0e30a7c0c1cee426011e274abc746c1ad3c48757433eb0139755658482498aa9` |
| Optional Table 4 storage comparison | 250,000 (250K) | `0x8078cc5a09d917be6300aef3043695b9be6da9bb4178ec9895c99fefd96660c7` |
| Optional shorter run | 500,000 (500K) | `0xac8e95f7483f7131261bcc0a70873f8236c27444c940defc677f74f281220193` |
| Optional H/PV*/VP* statistics smoke replay | 1,000,000 (1M) | `0x8e38b4dbf6b11fcc3b9dee84fb7986e29ca0a02cecd8977c161ff7333329681e` |
| Paper-scale input | 10,000,000 (10M) | `0xaa20f7bde5be60603f11a45fc4923aab7552be775403fc00c2e6b805e6297dbe` |

Set `TARGET_BLOCK_NUMBER` and `TARGET_BLOCK_HASH` to your desired block number
and its matching hash from the table above, then run:

```bash
source config.env
TARGET_BLOCK="$TARGET_BLOCK_NUMBER" TARGET_HASH="$TARGET_BLOCK_HASH" \
  ./scripts/prepare_ethereum_data.sh
```

This command downloads the data, starts MariaDB, and imports the blocks in
one terminal. When it prints `READY`, continue with the experiments below.
The RPC stops automatically; MariaDB stays running in the background.

Preparing data through 1M takes about 15 minutes and stores about 3 GB of input data.

By default, the scripts download historical block archives (Era1) over HTTPS
and import them into Geth, falling back to P2P target sync if this fails.
To use P2P target sync directly for a new download, add
`INPUT_ACQUISITION_METHOD=target-sync` to the environment assignments above.

## Run experiments

### Run a simulation with your own options

For example, run PV* with LevelDB and Snappy by starting the simulator in one
terminal. Change the scheme and options in this command as needed:

```bash
SIMULATOR_SCHEME=PVstar SIMULATOR_STATE_MODE=auto \
SIMULATOR_DB_BACKEND=leveldb SIMULATOR_COMPRESSION=snappy \
SIMULATOR_VARIANT=fast \
SIMULATOR_WORKDIR="$PWD/runtime/custom/output" \
SIMULATOR_DB="$PWD/runtime/custom/database" \
  ./scripts/run_simulator.sh
```

<details>
<summary>Scheme and option values</summary>

Set these variables on the simulator command. Defaults and further options,
including cache layout, node padding, and detailed counters, are in
[`config.env`](config.env).

| Variable | Values |
|---|---|
| `SIMULATOR_SCHEME` | `H`, `P`, `PH`, `PV`, `PVstar`, `VH`, `VP`, `VPstar`; `PVstar`/`VPstar` denote PV*/VP*. |
| `SIMULATOR_STATE_MODE` | `auto`, `archive`, `non-archive`. `auto` selects non-archive for P and archive for the others; P requires `auto` or `non-archive`. |
| `SIMULATOR_DB_BACKEND` | `leveldb`, `pebbledb` |
| `SIMULATOR_COMPRESSION` | `snappy`, `none`, or `zstd`; zstd requires `pebbledb`. |
| `SIMULATOR_VARIANT` | `fast` for timing; `stats` for detailed LevelDB read counters. |
| `SIMULATOR_MYHASH` | `false` or `true`; myHash is supported for PVstar/VPstar. |
| `SIMULATOR_MYHASH_CACHE_MB` | Cache size, such as `0` or `4096`; a nonzero size requires `SIMULATOR_MYHASH=true`. |
| `SIMULATOR_VERSION_WRAP` | `none`, `0xffff` (16-bit), or `0xfffff` (20-bit); wrapping requires VH. |

</details>

Once the simulator is listening, set `TARGET_BLOCK_NUMBER` in another terminal
and replay through that block, using the same database path:

```bash
TARGET_BLOCK="$TARGET_BLOCK_NUMBER" \
SIMULATOR_DB="$PWD/runtime/custom/database" \
  ./scripts/run_mariadb_client.sh
```

The client recreates the specified state database and replays from genesis.
Raw results are under `runtime/custom/output/logFiles/evm/runs/`.
Stop the simulator after the client finishes; use a different custom directory
for each run you want to retain.

### Reproduce the paper experiments (E1–E7)

The artifact organizes the paper's experiments into seven groups, labeled
**E1–E7** in the table below. These IDs are used in the commands that follow.
The runners select each group's configurations and collect their results
automatically.

| Experiment | What it tests | Results and paper location |
|---|---|---|
| E1 | Compare H, P, PH, PV, PV*, VH, VP, and VP* to measure how the key scheme affects execution cost and storage. | Execution and read/write times, cache/lookup statistics, compaction and storage; Figures 5–7, Tables 2–3 |
| E2 | Randomize keys, values, or both in the PV* database to separate their contributions to compression. | Rewritten database sizes; §5.2 |
| E3 | Add myHash to PV*/VP* and vary its cache to measure authentication overhead and the benefit of caching. | Execution times, child distributions, cache hits and node reads/writes; Figure 8 and §5.3 |
| E4 | Approximate decoupled-authentication costs by padding PV*/VP* nodes and disabling compression. | Execution time and storage under the approximation; Figure 9 |
| E5 | Limit VH versions to 16 or 20 bits to measure the performance effect of version reuse after wraparound. | Execution times compared with unwrapped VH; Figure 10 |
| E6 | Compare LevelDB/Pebble and Snappy/zstd to see how the backend and compression affect key-scheme results. | Backend/compression performance and storage; Figure 11, Table 4 |
| E7 | Run H/PV*/VP* in non-archive mode to examine how state retention affects execution and storage. | Execution times and storage, with E1 archive baselines; §5.4 |

Exact cases and result mappings are in [the experiment guide](docs/EXPERIMENT_COVERAGE.md).
The second argument selects what the runner does:

| Argument | Default behavior |
|---|---|
| `list` | Show the experiment's case IDs (first column) and configurations without running them. No Ethereum input is needed. |
| `validation` | Run the validation cases to check execution and analysis, with replays covering **0–50K** by default. These runs do not reproduce the paper-scale numbers. |
| `paper` | Run all cases for the experiment, with replays covering **0–10M** by default. |

Running all E1–E7 groups with the default `validation` profile takes about
20 minutes and uses about 40 GB for experiment databases, logs, and results.

For replay experiments, first prepare and import Ethereum data through
your chosen end block into MariaDB.

List the available cases, then run a family with the desired profile:

```bash
./scripts/run_paper_experiment.sh E1 list
./scripts/run_paper_experiment.sh E1 validation
```

Replace `E1` with any experiment ID from `E2` to `E7` to run another family.
For a full-scale family, use `paper` after preparing the 10M input:

```bash
./scripts/run_paper_experiment.sh E1 paper
```

To choose your own end block, pass only the block number to the runner:

```bash
TARGET_BLOCK="$TARGET_BLOCK_NUMBER" \
  ./scripts/run_paper_experiment.sh E1 paper
```

With `TARGET_BLOCK` set, `paper` replays from genesis only through the
specified block, overriding the default of 10M. MariaDB must already contain
all blocks from genesis through that block.

To run just one case, append its ID from the first column of `list` output.
For example:

```bash
./scripts/run_paper_experiment.sh E1 validation E1_PVstar
```

All experiment results are under `runtime/paper-experiments/<profile>/<experiment>/`:

| Output | Contents |
|---|---|
| `run-report.json` | Family results, effective settings and paths used by analysis |
| `run-report_<case-id>.json` | Report when an individual case is selected |
| `<case-id>/output/` | Block timing/storage records and enabled statistics |
| `<case-id>/database/` | Replay database; E2 uses the E1 PV* database |
| `<case-id>/simulator.log`, `<case-id>/client.log` | Progress and diagnostics |
| `rewrite-report.json` (E2) | Rewritten database sizes and entry counts |
| `rewrite-report_<case-id>.json` (E2) | Report when an individual rewrite case is selected |

## Analyze results

### Figures

Install the plotting dependencies once:

```bash
python3 -m venv runtime/analysis-venv
runtime/analysis-venv/bin/pip install \
  -r sources/data-analysis/requirements-artifact.txt
```

After running the corresponding experiment groups without a case ID, use the
commands below to generate figures. Each command generates all plots for its
experiment:

| Paper figure | Command | Corresponding output |
|---|---|---|
| Figure 5(a–b): block execution time and speedup relative to H | `./scripts/generate_experiment_graphs.sh E1 validation` | `compare_block_execute_time.png`, `compare_block_speedup.png` |
| Figure 6: read time | `./scripts/generate_experiment_graphs.sh E1 validation` | `compare_read_time.png` |
| Figure 7: write time | `./scripts/generate_experiment_graphs.sh E1 validation` | `compare_write_time.png` |
| Figure 8: myHash and caching | `./scripts/generate_experiment_graphs.sh E3 validation` | `compare_block_speedup.png` |
| Figure 9: authentication-cost approximation | `./scripts/generate_experiment_graphs.sh E4 validation` | `compare_block_speedup.png` |
| Figure 10: version sizes | `./scripts/generate_experiment_graphs.sh E5 validation` | `compare_block_speedup.png` |
| Figure 11: Pebble with Snappy/zstd | `./scripts/generate_experiment_graphs.sh E6 validation` | `pebble-overview/compare_block_execute_time.png` |
| §5.4 non-archive comparison (supplementary plots) | `./scripts/generate_experiment_graphs.sh E7 validation` | `compare_block_execute_time.png`, `compare_disk_size.png` |

Replace `validation` with `paper` for the paper's 5M–10M range. Output paths
are relative to `runtime/paper-experiments/<profile>/<experiment>/graphs/`.

Graphs for E3–E6 (Figures 8–11) also use E1 results. If you have not already
run E1, run it once with the same profile and end block:

```bash
./scripts/run_paper_experiment.sh E1 validation
```

### Tables 2–4 and storage statistics

For Tables 2–3, use the E1 results:

```bash
# Validation
./scripts/analyze_storage_metrics.sh \
  runtime/paper-experiments/validation/E1/run-report.json --variant stats \
  --output-dir runtime/paper-experiments/validation/E1/table2

./scripts/analyze_storage_metrics.sh \
  runtime/paper-experiments/validation/E1/run-report.json --variant fast \
  --output-dir runtime/paper-experiments/validation/E1/table3

# Paper-scale
./scripts/analyze_storage_metrics.sh \
  runtime/paper-experiments/paper/E1/run-report.json --variant stats \
  --start-block 5000000 --end-block 10000000 \
  --output-dir runtime/paper-experiments/paper/E1/table2

./scripts/analyze_storage_metrics.sh \
  runtime/paper-experiments/paper/E1/run-report.json --variant fast \
  --start-block 0 --end-block 10000000 \
  --output-dir runtime/paper-experiments/paper/E1/table3
```

Table 2 is in `table2/read_path_summary.csv`; Table 3 is in
`table3/compaction_storage_summary.csv`. Write-stall statistics are in
`table3/leveldb_metrics.csv`.

For Table 4, use the E1 and E6 results:

```bash
# Validation
python3 analysis/extract_backend_storage.py \
  runtime/paper-experiments/validation/E1/run-report.json \
  runtime/paper-experiments/validation/E6/run-report.json \
  --output-dir runtime/paper-experiments/validation/E6/table4

# Paper-scale comparison at 10M
python3 analysis/extract_backend_storage.py \
  runtime/paper-experiments/paper/E1/run-report.json \
  runtime/paper-experiments/paper/E6/run-report.json \
  --end-block 10000000 \
  --output-dir runtime/paper-experiments/paper/E6/table4
```

The `table4/` directory contains `backend_storage.csv`, `.json`, and `.md`.
Source fields and size definitions are in [storage metrics](docs/STORAGE_METRICS.md).

### Optional: longer runs for Tables 2–4

The default 50K validation run is too small to exercise much disk read/write
activity, so Tables 2–4 may show N/A, zeros, or little difference between schemes.
For more substantial storage results, run the following experiments. Prepare
Ethereum data through 1M for Tables 2–3, or through 250K for Table 4 alone:

```bash
# Tables 2–3: H/PV*/VP* with detailed statistics through 1M
./scripts/run_core_smoke.sh
./scripts/analyze_storage_metrics.sh \
  runtime/core-smoke-1000000/smoke-report.json --variant stats \
  --output-dir runtime/core-smoke-1000000/tables2-3

# Table 4: compare backends and compression at 250K
./scripts/run_table4_smoke.sh
```

Allow about 1 hour and 20 GB for the 1M smoke, and 30 minutes and 25 GB for
standalone Table 4. These sizes cover experiment databases, logs, and results.

| Paper table | Result |
|---|---|
| 2 | `runtime/core-smoke-1000000/tables2-3/read_path_summary.csv` |
| 3 | `runtime/core-smoke-1000000/tables2-3/compaction_storage_summary.csv` |
| 4 | `runtime/table4-smoke-250000/table4/backend_storage.csv` |

### Authentication statistics

Use the E3 results to extract child distributions, cache hits, node reads/writes
and node-count-based storage estimates:

```bash
# Validation
python3 analysis/extract_auth_metrics.py \
  runtime/paper-experiments/validation/E3/run-report.json

# Paper-scale (5M–10M)
python3 analysis/extract_auth_metrics.py \
  runtime/paper-experiments/paper/E3/run-report.json \
  --start-block 5000000 --end-block 10000000
```

The `auth-metrics/` directory under E3 contains `auth_metrics.csv`,
`auth_metrics.json`, and `auth_metrics.md`. Metric definitions are in
[authentication metrics](docs/AUTHENTICATION_METRICS.md).

## If a run fails

For the quick check, build, replay-client, and result-check errors appear in
the terminal. Check `logs/sync-and-rpc.console.log` for data-preparation/RPC
failures and `logs/simulator.console.log` for simulator failures. If a port is
already in use, stop the existing RPC or simulator before retrying.

For Ethereum data preparation, import errors appear in the terminal. Check
`logs/prepare-ethereum-rpc.log` for download/RPC failures and
`logs/mariadb.console.log` or `logs/mariadb.log` for MariaDB startup failures.

For paper experiments, check the case's `simulator.log` and `client.log`, or `logs/mariadb.log` for
input-cache problems. Input acquisition logs are `logs/era-download.log`,
`logs/era-import.log`, and `logs/era-verify.log`. Acquisition falls back to P2P
sync when needed; this requires outbound Ethereum TCP/UDP access and logs to
`logs/geth-target-sync.log`. Use the block/hash pairs pinned in `config.env`.

<details>
<summary>Optional cleanup</summary>

After finishing your experiments, stop MariaDB with:

```bash
mariadb-admin --no-defaults --socket="$PWD/runtime/mariadb.sock" -u root shutdown
```

Run the preparation command again when you need MariaDB for another session.

Stop MariaDB and any running experiments before cleanup.
`./scripts/clean_runtime.sh` removes `runtime/`.
`./scripts/clean_all_generated.sh` removes downloaded sources, binaries,
runtime data and logs. Both delete generated experiment data; run them only
when those results are no longer needed.

</details>
