# Graph analysis and partial runs

Use the existing `scripts/generate_experiment_graphs.sh` commands for E1 and
E3–E7. The figure selections and H baselines are unchanged. The lower-level
`scripts/generate_graphs.sh` still accepts explicit reports and case labels.

## Paper figure formatting

The [README's figure table](../README.md#figures) maps Figures 5(a)–11 to
commands and output files. Each command writes separate metric plots, including
additional plots beyond those shown in the paper. Figure 5(a) and (b) are
separate files; Figure 11 uses the E6 `pebble-overview` execution-time plot.

The generated plots use block numbers and nanoseconds on linear axes.
The manuscript uses millions of blocks, milliseconds and logarithmic time
axes in Figures 5(a), 6, 7 and 11. The mapping identifies the corresponding
measurements; it does not reproduce the manuscript's typography or panel layout.

## Sequential input processing

The pinned analysis code processes one case at a time. It incrementally decodes
one block record from that case's JSON, validates the contiguous 0–completed
prefix, and maintains only the rolling timing window. This also avoids loading
one multi-GB JSON in full.

Four float64 columns are written to `plot-data/case-XX.npy`: execution-time
mean, read-time mean, write-time mean and sampled disk bytes. Rows correspond
to the requested plotting range. The arrays are then read through memory maps,
and each figure is completed and closed before drawing the next figure. Raw
records from multiple experiments are never held together.

Compact arrays use about 32 bytes per plotted block per case: a 5M-block
plotting range needs about 160 MB per case (decimal units), in addition to the
existing raw logs. Plot rendering still requires memory for numeric curves;
the entire plotting process is not claimed to use constant memory.

## Partial results

A partial case supplies `status: partial`, its actual `completed_block`, and a
valid saved `simBlocks` JSON through that checkpoint. The following rules apply:

- Every timing/storage curve uses its own completed range.
- A speedup curve uses the common range of that case and the selected baseline.
- The common x-axis still extends to the planned target, showing missing tails.
- Partial cases are identified in the legend and analysis manifest.
- A case ending before the plotting start contributes no fabricated samples.
- Missing intermediate blocks, duplicate records, truncated JSON and endpoint
  mismatches are errors. A partial run is not permission to ignore corrupt data.

`analysis-manifest.json` records each case's status, completed endpoint, missing
interval, speedup endpoint and numeric curve file. A successful analysis
manifest is written only after input validation and plot generation complete.

## Preserved calculations

Execution/read/write curves use full-window trailing means, starting within
the requested plotting range. Speedup is the baseline execution mean divided
by the case's execution mean at the same block. Missing values are not filled.

The legacy read plot includes `AccountHashes + StorageHashes` when its label
contains `myHash`; the CSV read summary excludes those fields. This existing
distinction is retained. Write time sums account, storage, snapshot, trie DB
and disk commits. Disk size uses positive `DiskSize` measurements; disk-growth
plots average consecutive size differences over up to ten samples.

`core-window-summary.csv` retains non-overlapping windows, including a final
short window. It is not a list of every rolling-mean point. For example, its
final row may contain only the 10M block; do not use that row as the average
over 9.9M–10M. Use the numeric curve at the intended block for trailing means,
and exact raw checkpoints for endpoint disk measurements.
