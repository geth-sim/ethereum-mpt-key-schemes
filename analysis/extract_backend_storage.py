#!/usr/bin/env python3
"""Extract the backend/compression storage comparison used by Table 4."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from extract_storage_metrics import (
    load_json,
    portable_path,
    resolve_path,
    simblock_checkpoint,
    write_csv,
)


# Table 4's row order in the submitted manuscript.
SCHEMES = ("H", "VPstar", "PVstar")
CONFIGURATIONS = (
    ("leveldb", "snappy", "LevelDB / Snappy", "E1_{scheme}"),
    ("pebbledb", "snappy", "Pebble / Snappy", "E6_{scheme}_pebble_snappy"),
    ("pebbledb", "zstd", "Pebble / zstd", "E6_{scheme}_pebble_zstd"),
)
EXPECTED = {
    template.format(scheme=scheme): (scheme, backend, compression)
    for scheme in SCHEMES
    for backend, compression, _, template in CONFIGURATIONS
}


def storage_row(case: dict, report_path: Path, end_block: int) -> dict:
    completed = case.get("resolved", {}).get("completed_block", case.get("target_block"))
    if type(completed) is not int or completed < end_block:
        raise ValueError(f"{case['case_id']}: replay has not reached block {end_block}")
    source = resolve_path(case["outputs"]["simblocks"])
    size = simblock_checkpoint(source, end_block)["DiskSize"]
    if type(size) is not int or size < 0:
        raise ValueError(f"{case['case_id']}: DiskSize must be a non-negative byte count")
    if size == 0:
        raise ValueError(
            f"{case['case_id']}: no directory-size measurement at block {end_block} "
            "(DiskSize=0); select a block sampled by --disk-size-interval"
        )
    return {
        "case_id": case["case_id"], "scheme": case["scheme"],
        "backend": case["backend"], "compression": case["compression"],
        "variant": case["variant"], "block": end_block,
        "disk_size_bytes": size, "disk_size_mb": size / 1e6,
        "disk_size_tb": size / 1e12,
        "source_report": portable_path(report_path), "simblocks": portable_path(source),
    }


def smoke_storage(report_path: Path, end_block: int) -> list[dict]:
    """Validate and read the three LevelDB checkpoints without launching replays."""
    if type(end_block) is not int or end_block <= 0:
        raise ValueError("--end-block must be a positive integer for smoke results")
    report = load_json(report_path)
    if report.get("status") != "PASS":
        raise ValueError("LevelDB smoke report must be complete (status=PASS)")
    selected = {}
    for case in report["cases"]:
        scheme = case.get("scheme")
        if scheme not in SCHEMES:
            continue
        if scheme in selected:
            raise ValueError(f"duplicate smoke scheme: {scheme}")
        settings = {
            "case_id": f"smoke_{scheme}", "variant": "stats",
            "experiment_id": f"{scheme}_archive_leveldb_snappy_stats",
        }
        for key, value in settings.items():
            if case.get(key) != value:
                raise ValueError(f"{scheme}: expected {key}={value} in smoke report")
        # Older smoke reports encode these settings only in experiment_id.
        for key, value in {"backend": "leveldb", "compression": "snappy",
                           "state_mode": "archive"}.items():
            if case.get(key, value) != value:
                raise ValueError(f"{scheme}: expected {key}={value} in smoke report")
        selected[scheme] = storage_row(
            {**case, "backend": "leveldb", "compression": "snappy"},
            report_path, end_block,
        )
    missing = set(SCHEMES) - selected.keys()
    if missing:
        raise ValueError(f"missing smoke schemes: {', '.join(sorted(missing))}")
    return [selected[scheme] for scheme in SCHEMES]


def collect_storage(
    reports: list[Path], end_block: int | None, leveldb_smoke_report: Path | None = None,
) -> tuple[int, list[dict]]:
    smoke_rows = smoke_storage(leveldb_smoke_report, end_block) if leveldb_smoke_report else []
    expected = {
        key: settings for key, settings in EXPECTED.items()
        if not leveldb_smoke_report or settings[1] != "leveldb"
    }
    selected = {}
    for report_path in reports:
        report = load_json(report_path)
        for case in report["cases"]:
            case_id = case["case_id"]
            if case_id not in EXPECTED:
                continue
            if case_id not in expected:
                raise ValueError("use either E1 fast cases or a LevelDB smoke report, not both")
            if case_id in selected:
                raise ValueError(f"duplicate case: {case_id}")
            scheme, backend, compression = EXPECTED[case_id]
            settings = {
                "scheme": scheme, "backend": backend, "compression": compression,
                "variant": "fast", "state_mode": "archive",
            }
            for key, value in settings.items():
                if case.get(key) != value:
                    raise ValueError(f"{case_id}: expected {key}={value}")
            target = case["resolved"].get("target_block", report.get("target_block"))
            selected[case_id] = (case, report_path, target)

    missing = expected.keys() - selected.keys()
    if missing:
        raise ValueError(f"missing comparison cases: {', '.join(sorted(missing))}")
    if end_block is None:
        targets = {entry[2] for entry in selected.values()}
        if len(targets) != 1 or None in targets:
            raise ValueError("set --end-block when reports do not share one target block")
        end_block = targets.pop()
    if type(end_block) is not int or end_block <= 0:
        raise ValueError("--end-block must be a positive integer")

    rows = list(smoke_rows)
    for case_id in expected:
        case, report_path, _ = selected[case_id]
        rows.append(storage_row(case, report_path, end_block))
    order = {settings: index for index, settings in enumerate(EXPECTED.values())}
    rows.sort(key=lambda row: order[(row["scheme"], row["backend"], row["compression"])])
    return end_block, rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+", help="E1 and E6 run reports")
    parser.add_argument("--end-block", type=int, help="checkpoint (default: shared replay target)")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--unit", choices=("MB", "TB"),
                        help="display unit (default: MB with smoke checkpoints, otherwise TB)")
    parser.add_argument("--leveldb-smoke-report", type=Path,
                        help="reuse stats smoke checkpoints instead of E1; requires --end-block")
    args = parser.parse_args()
    reports = [path.resolve() for path in args.reports]
    try:
        block, rows = collect_storage(reports, args.end_block, args.leveldb_smoke_report)
    except (OSError, KeyError, ValueError, TypeError) as exc:
        parser.exit(1, f"error: {exc}\n")

    output = args.output_dir or reports[-1].parent / "table4"
    output.mkdir(parents=True, exist_ok=True)
    write_csv(output / "backend_storage.csv", rows)
    smoke = args.leveldb_smoke_report is not None
    display_unit = args.unit or ("MB" if smoke else "TB")
    unit = "MB (10^6 bytes)" if display_unit == "MB" else "TB (10^12 bytes)"
    field = "disk_size_mb" if display_unit == "MB" else "disk_size_tb"
    (output / "backend_storage.json").write_text(
        json.dumps({"block": block, "unit": unit, "cases": rows}, indent=2)
        + "\n", encoding="utf-8",
    )
    sizes = {(row["scheme"], row["backend"], row["compression"]): row[field] for row in rows}
    lines = [
        "# Backend and compression storage", "",
        f"Block: {block:,}. Sizes in {unit}, from simBlocks.DiskSize.", "",
    ]
    if smoke:
        lines += [
            "Smoke results: LevelDB uses stats-mode checkpoints from the longer smoke run; "
            "Pebble uses fast-mode replays. All sizes are measured at the block above.", "",
        ]
    else:
        lines += ["Measurement variant: fast for all cases.", ""]
    lines += [
        "| Scheme | LevelDB (Snappy) | Pebble (Snappy) | Pebble (zstd) |",
        "|---|---:|---:|---:|",
    ]
    for scheme in SCHEMES:
        cells = [
            f"{sizes[(scheme, backend, compression)]:.6g}"
            for backend, compression, _, _ in CONFIGURATIONS
        ]
        label = scheme.replace("star", "*")
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    (output / "backend_storage.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Extracted {len(rows)} storage measurements at block {block}: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
