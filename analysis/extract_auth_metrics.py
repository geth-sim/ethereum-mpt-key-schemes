#!/usr/bin/env python3
"""Extract authentication counters for paper §§5.3.1–5.3.2 (not timings)."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from extract_storage_metrics import (
    derive_read_metrics,
    display,
    load_json,
    portable_path,
    ratio,
    read_stats_checkpoint,
    resolve_path,
    sha256_file,
    simblock_checkpoint,
    subtract_read_stats,
    write_csv,
)


CHILD_FIELDS = {
    "HashedFullNodeNum": "branch_nodes",
    "HashedShortNodeNum": "short_nodes",
    "HashedLeafNodeNum": "leaf_nodes",
    "WrittenTrieNodeNum": "written_trie_nodes",
}
READ_FIELDS = {
    "NodeReadFuncCnt": "node_reads",
    "AdditionalNodeReadFuncCnt": "additional_node_reads",
    "ChildReadStateHit": "myhash_state_hits",
    "ChildReadStateMiss": "myhash_state_misses",
    "ChildReadStorageHit": "myhash_storage_hits",
    "ChildReadStorageMiss": "myhash_storage_misses",
}


def counter(value: Any, name: str) -> int:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a non-negative integer, got {value!r}")
    return value


def child_checkpoints(path: Path) -> dict[int, dict[str, int]]:
    """Read Geth's cumulative child snapshots; ignore rounded printed ratios."""
    result: dict[int, dict[str, int]] = {}
    snapshot: dict[str, int] | None = None
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            match = re.fullmatch(r"Current Block Number: (\d+)\s*", line)
            if match:
                block = int(match[1])
                if block in result:
                    raise ValueError(f"duplicate child snapshot at block {block}: {path}")
                snapshot = result.setdefault(block, {})
                continue
            if snapshot is None:
                continue
            match = re.fullmatch(r"\s*(nil|clean|dirty)\s+childs:\s*(\d+)\s+->.*", line.rstrip())
            if match:
                snapshot[f"{match[1]}_children"] = int(match[2])
                continue
            match = re.fullmatch(r"\s*(\w+): (\d+)\s*", line)
            if match and match[1] in CHILD_FIELDS:
                key, value = CHILD_FIELDS[match[1]], int(match[2])
                # Geth prints HashedFullNodeNum twice in each snapshot.
                if key in snapshot and snapshot[key] != value:
                    raise ValueError(f"inconsistent {key} in {path}")
                snapshot[key] = value
    required = {*CHILD_FIELDS.values(), "nil_children", "clean_children", "dirty_children"}
    for block, values in result.items():
        missing = required - values.keys()
        if missing:
            raise ValueError(f"child snapshot {block} lacks {sorted(missing)}: {path}")
        if sum(values[f"{kind}_children"] for kind in ("nil", "clean", "dirty")) != 16 * values["branch_nodes"]:
            raise ValueError(f"child counts do not cover 16 pointers per branch at {block}: {path}")
    return result


def difference(end: dict, start: dict | None, fields: dict[str, str]) -> dict[str, int]:
    result = {}
    for raw, name in fields.items():
        value = counter(end[raw], raw)
        previous = counter(start[raw], raw) if start is not None else 0
        if previous > value:
            raise ValueError(f"{raw} decreased; checkpoints are not one cumulative run")
        result[name] = value - previous
    return result


def percent(hit: int, total: int) -> float | None:
    fraction = ratio(hit, total)
    return None if fraction is None else 100 * fraction


def derive_metrics(end_child: dict, start_child: dict | None, end_block: dict, start_block: dict | None) -> dict:
    fields = {name: name for name in end_child}
    child = difference(end_child, start_child, fields)
    reads = difference(end_block, start_block, READ_FIELDS)
    total_children = 16 * child["branch_nodes"]
    if sum(child[f"{kind}_children"] for kind in ("nil", "clean", "dirty")) != total_children:
        raise ValueError("child window does not contain 16 pointers per branch")
    result = child | reads
    for kind in ("nil", "clean", "dirty"):
        result[f"{kind}_children_percent"] = percent(child[f"{kind}_children"], total_children)
    total_hits = total_misses = 0
    for trie in ("state", "storage"):
        hits = reads[f"myhash_{trie}_hits"]
        misses = reads[f"myhash_{trie}_misses"]
        total_hits += hits
        total_misses += misses
        result[f"myhash_{trie}_hit_rate_percent"] = percent(hits, hits + misses)
    result["myhash_hit_rate_percent"] = percent(total_hits, total_hits + total_misses)
    result["additional_read_fraction"] = ratio(reads["additional_node_reads"], reads["node_reads"])
    # Storage estimates use the cumulative END count, even for a read window.
    written = end_child["written_trie_nodes"]
    result["written_trie_nodes_at_end"] = written
    result["estimated_hash_payload_tb"] = written * 32 / 1e12
    result["upper_bound_version4_payload_tb"] = written * 16 * 4 / 1e12
    result["upper_bound_version2_5_payload_tb"] = written * 16 * 2.5 / 1e12
    return result


def extract_case(case: dict, report: dict, start: int, end: int) -> tuple[dict, dict]:
    resolved = case.get("resolved", {})
    manifest = case.get("manifest_case", {})
    case_id = case["case_id"]
    for option in ("child_stats", "accurate_read_counters"):
        if resolved.get(option) is not True:
            raise ValueError(f"{case_id}: run report must confirm {option}=true")
    if case.get("status") not in ("complete", "PASS"):
        raise ValueError(f"{case_id}: authentication analysis requires a complete run")
    completed = resolved.get("completed_block", case.get("target_block", report.get("target_block")))
    if completed is None or end > completed:
        raise ValueError(f"{case_id}: end block {end} is beyond the completed run")
    outputs = case["outputs"]
    for name in ("simblocks", "additional_node_stats", "read_stats"):
        if not outputs.get(name):
            raise ValueError(f"{case_id}: missing {name} output")
    child_path = resolve_path(outputs["additional_node_stats"])
    sim_path = resolve_path(outputs["simblocks"])
    snapshots = child_checkpoints(child_path)
    if end not in snapshots or (start and start not in snapshots):
        raise ValueError(f"{case_id}: child checkpoints for ({start}, {end}] are unavailable; available: {sorted(snapshots)}")
    end_record = simblock_checkpoint(sim_path, end)
    start_record = simblock_checkpoint(sim_path, start) if start else None
    for number, record in ((end, end_record), (start, start_record)):
        if record is not None and record.get("Number") != number:
            raise ValueError(f"{case_id}: simBlocks Number mismatch at {number}")
    row = {
        "case_id": case_id,
        "scheme": case["scheme"],
        "start_block": start,
        "end_block": end,
        "myhash": manifest.get("myhash", False),
        "myhash_cache_mb": manifest.get("myhash_cache_mb", 0),
        "counter_baseline": manifest.get("counter_baseline"),
    }
    row.update(derive_metrics(snapshots[end], snapshots.get(start) if start else None, end_record, start_record))
    final_read = resolve_path(outputs["read_stats"])
    experiment_id = case["experiment_id"]
    read_end = read_stats_checkpoint(final_read, experiment_id, end)
    read_start = read_stats_checkpoint(final_read, experiment_id, start) if start else None
    read = derive_read_metrics(subtract_read_stats(load_json(read_end), load_json(read_start) if read_start else None))
    row["data_block_cache_hit_rate_percent"] = read["data_cache_hit_rate_percent"]
    provenance = {
        "case_id": case_id,
        "simblocks": portable_path(sim_path),
        "additional_node_stats": portable_path(child_path),
        "additional_node_stats_sha256": sha256_file(child_path),
        "end_read_stats": portable_path(read_end),
        "start_read_stats": portable_path(read_start) if read_start else None,
        "resolved": resolved,
        "manifest_case": manifest,
    }
    return row, provenance


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+", help="one combined report or multiple individual counter-case reports")
    parser.add_argument(
        "--start-block", type=int, default=0,
        help="subtract this cumulative checkpoint before calculating ratios; 0 uses end counts directly",
    )
    parser.add_argument(
        "--end-block", type=int,
        help="inclusive end checkpoint; use --start-block 5000000 --end-block 10000000 for the paper's child distribution",
    )
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    selected = {}
    source_reports = []
    for path in args.reports:
        report = load_json(path)
        source_reports.append(portable_path(path.resolve()))
        for case in report["cases"]:
            if case.get("manifest_case", {}).get("purpose") != "authentication-metrics":
                continue
            case_id = case["case_id"]
            if case_id in selected:
                raise ValueError(f"duplicate counter case {case_id}; supply each run once")
            selected[case_id] = case, report
    if not selected:
        raise ValueError("no authentication-metrics cases; run the E3 *_counters cases first")
    targets = {case.get("resolved", {}).get("target_block", report.get("target_block")) for case, report in selected.values()}
    if args.end_block is None and (len(targets) != 1 or None in targets):
        raise ValueError("--end-block is required when reports do not have one target")
    end = args.end_block if args.end_block is not None else next(iter(targets))
    if not 0 <= args.start_block < end:
        raise ValueError("require 0 <= start-block < end-block")
    rows, inputs = [], []
    for case, report in selected.values():
        row, provenance = extract_case(case, report, args.start_block, end)
        rows.append(row)
        inputs.append(provenance)
    by_id = {row["case_id"]: row for row in rows}
    missing_baselines = []
    for row in rows:
        baseline_id = row["counter_baseline"]
        baseline = by_id.get(baseline_id) if baseline_id else row
        row["node_reads_vs_baseline"] = None
        if baseline is None:
            missing_baselines.append(baseline_id)
        elif baseline["scheme"] != row["scheme"] or baseline["myhash"]:
            raise ValueError(f"invalid counter baseline for {row['case_id']}")
        else:
            row["node_reads_vs_baseline"] = ratio(row["node_reads"], baseline["node_reads"])
    output = args.output_dir or args.reports[0].parent / "auth-metrics"
    output.mkdir(parents=True, exist_ok=True)
    payload = {
        "source_reports": source_reports,
        "start_block": args.start_block,
        "end_block": end,
        "formula_reference": "docs/AUTHENTICATION_METRICS.md",
        "missing_baselines": sorted(set(missing_baselines)),
        "inputs": inputs,
        "cases": rows,
    }
    (output / "auth_metrics.json").write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    write_csv(output / "auth_metrics.csv", rows)
    lines = [
        "# Authentication counters",
        "",
        f"Cumulative through {end:,}" if not args.start_block else f"Window: ({args.start_block:,}, {end:,}]",
        "",
        "Child percentages use 100 * interval child count / (16 * interval branch count). "
        "Interval counts are end minus start cumulative counters; checkpoint percentages are not averaged or subtracted.",
        "",
        "Counter runs are not performance measurements. Payload estimates are uncompressed arithmetic estimates, not measured DB sizes.",
        "",
        "| Case | Nil (%) | Updated (%) | Non-updated (%) | myHash hit (%) | Data-block hit (%) | Reads / baseline | Written nodes at end |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    columns = ["case_id", "nil_children_percent", "dirty_children_percent", "clean_children_percent", "myhash_hit_rate_percent", "data_block_cache_hit_rate_percent", "node_reads_vs_baseline", "written_trie_nodes_at_end"]
    for row in rows:
        lines.append("| " + " | ".join(display(row[name]) for name in columns) + " |")
    if missing_baselines:
        lines.extend(["", "Include these baseline reports to compute read ratios: " + ", ".join(sorted(set(missing_baselines)))])
    (output / "auth_metrics.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Extracted {len(rows)} counter cases to {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error)) from error
