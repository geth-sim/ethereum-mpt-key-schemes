#!/usr/bin/env python3
"""Extract paper-facing LevelDB and read-path metrics from simulator JSON."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import mmap
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def level_number(key: str) -> int:
    match = re.search(r"\d+", str(key))
    if not match:
        raise ValueError(f"cannot determine level number from {key!r}")
    return int(match.group())


def sum_map(values: dict[str, int], minimum_level: int | None = None) -> int:
    if minimum_level is None:
        return sum(values.values())
    return sum(value for key, value in values.items() if level_number(key) >= minimum_level)


def subtract_read_stats(end: dict[str, Any], start: dict[str, Any] | None) -> dict[str, Any]:
    if start is None:
        return end
    result: dict[str, Any] = {}
    for key, end_value in end.items():
        start_value = start.get(key, {} if isinstance(end_value, dict) else 0)
        if isinstance(end_value, dict):
            result[key] = {
                subkey: value - start_value.get(subkey, 0)
                for subkey, value in end_value.items()
            }
        elif isinstance(end_value, (int, float)) and not isinstance(end_value, bool):
            result[key] = end_value - start_value
        else:
            result[key] = end_value
    return result


def derive_read_metrics(raw: dict[str, Any]) -> dict[str, Any]:
    fake_mems = raw.get("FakeMems", {})
    fake_levels = raw.get("FakeLevels", {})
    real_mems = raw.get("RealMems", {})
    real_levels = raw.get("RealLevels", {})
    requests = raw.get("ReadRequestCount", 0)

    fake_non_l0 = sum_map(fake_levels, 1)
    fake_disk = sum_map(fake_levels)
    fake_total = sum_map(fake_mems) + fake_disk
    real_disk = sum_map(real_levels)
    real_total = sum_map(real_mems) + real_disk

    real_l0_attempts = raw.get("RealLevel0Attempts", 0)
    hits = raw.get("CacheHitCounts", {})
    misses = raw.get("CacheMissCounts", {})
    bloom_hit = raw.get("BloomHitCount", 0)
    bloom_miss = raw.get("BloomMissCount", 0)
    bloom_false_positive = raw.get("BloomFalsePositiveCount", 0)

    result: dict[str, Any] = {
        "read_requests": requests,
        "fake_mem_lookups": sum_map(fake_mems),
        "fake_l0_lookups": fake_levels.get("0", 0),
        "fake_non_l0_lookups": fake_non_l0,
        "fake_disk_lookups": fake_disk,
        "fake_total_lookups": fake_total,
        "real_mem_lookups": sum_map(real_mems),
        "real_l0_lookups": real_levels.get("0", 0),
        "real_non_l0_lookups": sum_map(real_levels, 1),
        "real_disk_lookups": real_disk,
        "real_total_lookups": real_total,
        "fake_l0_attempts": raw.get("FakeLevel0Attempts", 0),
        "real_l0_attempts": real_l0_attempts,
        "not_found": raw.get("NotFoundCount", 0),
        # The compact read-path summary excludes mem/imm but includes every
        # on-disk level, including L0 ("fake (w/o mem, imm) / request").
        "negative_sstable_lookups_per_read": ratio(fake_disk, requests),
        "fake_disk_lookups_per_read": ratio(fake_disk, requests),
        "fake_total_lookups_per_read": ratio(fake_total, requests),
        "bloom_hits": bloom_hit,
        "bloom_misses": bloom_miss,
        "bloom_false_positives": bloom_false_positive,
        "bloom_false_positive_rate": ratio(
            bloom_false_positive, bloom_false_positive + bloom_miss
        ),
        "bloom_positive_predictive_value": (
            1 - bloom_false_positive / bloom_hit if bloom_hit else None
        ),
        "bloom_skip_rate": ratio(bloom_miss, bloom_hit + bloom_miss),
    }
    for block_type in ("data-block", "filter-block", "index-block"):
        short = block_type.removesuffix("-block")
        hit = hits.get(block_type, 0)
        miss = misses.get(block_type, 0)
        result[f"{short}_cache_hits"] = hit
        result[f"{short}_cache_misses"] = miss
        hit_rate = ratio(hit, hit + miss)
        result[f"{short}_cache_hit_rate_percent"] = (
            hit_rate * 100 if hit_rate is not None else None
        )
    return result


def subtract_number(end: dict[str, Any], start: dict[str, Any], key: str) -> float:
    return end.get(key, 0) - start.get(key, 0)


def derive_leveldb_metrics(
    end: dict[str, Any], start: dict[str, Any] | None
) -> dict[str, Any]:
    start = start or {}
    end_compaction = end.get("compaction", {}).get("total", {})
    start_compaction = start.get("compaction", {}).get("total", {})
    end_io = end.get("io", {})
    start_io = start.get("io", {})
    end_delay = end.get("write_delay", {})
    start_delay = start.get("write_delay", {})
    end_counts = end.get("compaction_count", {})
    start_counts = start.get("compaction_count", {})

    compaction_read = subtract_number(end_compaction, start_compaction, "read_mb")
    compaction_write = subtract_number(end_compaction, start_compaction, "write_mb")
    io_read = subtract_number(end_io, start_io, "read_mb")
    io_write = subtract_number(end_io, start_io, "write_mb")
    mem = subtract_number(end_counts, start_counts, "mem_comp")
    level0 = subtract_number(end_counts, start_counts, "level0_comp")
    non_level0 = subtract_number(end_counts, start_counts, "non_level0_comp")
    seek = subtract_number(end_counts, start_counts, "seek_comp")

    return {
        "compacted_tables": subtract_number(end_compaction, start_compaction, "tables"),
        "compacted_size_mb": subtract_number(end_compaction, start_compaction, "size_mb"),
        "compaction_time_seconds": subtract_number(
            end_compaction, start_compaction, "time_sec"
        ),
        "compaction_read_mb": compaction_read,
        "compaction_write_mb": compaction_write,
        "mem_compactions": mem,
        "level0_compactions": level0,
        "non_level0_compactions": non_level0,
        "seek_compactions": seek,
        "total_compactions": mem + level0 + non_level0 + seek,
        "write_delay_count": subtract_number(end_delay, start_delay, "delay_n"),
        "write_delay_seconds": subtract_number(end_delay, start_delay, "delay_sec"),
        "io_read_mb": io_read,
        "io_write_mb": io_write,
        "non_compaction_read_mb": io_read - compaction_read,
        "non_compaction_write_mb": io_write - compaction_write,
        # opened_tables is an end-of-window snapshot, not a cumulative counter.
        "opened_tables": end.get("opened_tables", 0),
    }


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def simblock_checkpoint(path: Path, block: int) -> dict[str, Any]:
    """Read one keyed simBlocks record without loading the multi-GB JSON file."""
    marker = f'"{block:08d}":'.encode()
    with path.open("rb") as stream:
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
            marker_pos = mapped.rfind(marker)
            if marker_pos < 0:
                raise KeyError(f"simBlocks checkpoint {block} is not present in {path}")
            pos = marker_pos + len(marker)
            while mapped[pos] in b" \t\r\n":
                pos += 1
            if mapped[pos] != ord("{"):
                raise ValueError(f"simBlocks checkpoint {block} is not a JSON object")
            start = pos
            depth = 0
            in_string = False
            escaped = False
            while pos < len(mapped):
                byte = mapped[pos]
                if in_string:
                    if escaped:
                        escaped = False
                    elif byte == ord("\\"):
                        escaped = True
                    elif byte == ord('"'):
                        in_string = False
                elif byte == ord('"'):
                    in_string = True
                elif byte == ord("{"):
                    depth += 1
                elif byte == ord("}"):
                    depth -= 1
                    if depth == 0:
                        return json.loads(mapped[start : pos + 1])
                pos += 1
    raise ValueError(f"unterminated simBlocks checkpoint {block} in {path}")


def resolve_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def portable_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def checkpoint(data: dict[str, Any], block: int) -> dict[str, Any]:
    for key in (f"{block:08d}", str(block)):
        if key in data:
            return data[key]
    for value in data.values():
        if isinstance(value, dict) and value.get("block_num") == block:
            return value
    raise KeyError(f"LevelDB checkpoint {block} is not present")


def read_stats_checkpoint(final_path: Path, experiment_id: str, block: int) -> Path:
    path = final_path.parent / f"read_stats_{experiment_id}_{block}.json"
    if not path.is_file():
        raise FileNotFoundError(f"read-stats checkpoint does not exist: {path}")
    return path


def normalized_case(case: dict[str, Any], report_target: int | None) -> dict[str, Any]:
    manifest = case.get("manifest_case", {})
    resolved = case.get("resolved", {})
    outputs = case.get("outputs", {})
    return {
        "case_id": case.get("case_id") or manifest.get("id") or resolved.get("id"),
        "experiment_id": (
            case.get("experiment_id")
            or resolved.get("experiment_id")
            or manifest.get("experiment_id")
        ),
        "scheme": case.get("scheme") or resolved.get("scheme") or manifest.get("scheme"),
        "target_block": (
            case.get("target_block")
            or resolved.get("target_block")
            or manifest.get("target_block")
            or report_target
        ),
        "database_bytes": case.get("database_bytes") or resolved.get("database_bytes"),
        "simblocks": outputs.get("simblocks"),
        "leveldb_stats": outputs.get("leveldb_stats"),
        "read_stats": outputs.get("read_stats"),
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    fields: list[str] = []
    for row in rows:
        fields.extend(key for key in row if key not in fields)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def display(value: Any) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, float):
        return f"{value:.6g}"
    return str(value)


def write_markdown(
    path: Path, start: int, end: int, leveldb_rows: list[dict[str, Any]],
    read_rows: list[dict[str, Any]]
) -> None:
    lines = [
        "# Storage metrics",
        "",
        (
            f"Window: blocks {start:,}–{end:,}. Cache hit rates are percentages; "
            "Bloom rates are fractions."
        ),
        "",
        "## Read path",
        "",
        "| Scheme | Requests | Negative SST/read | Data cache hit (%) | Bloom FPR | Bloom skip |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in read_rows:
        lines.append(
            "| {scheme} | {read_requests} | {negative_sstable_lookups_per_read} | "
            "{data_cache_hit_rate_percent} | "
            "{bloom_false_positive_rate} | {bloom_skip_rate} |".format(
                **{key: display(value) for key, value in row.items()}
            )
        )
    lines.extend(
        [
            "",
            "## LevelDB",
            "",
            "| Scheme | Compactions | Compaction time (s) | Compaction R/W (MB) | "
            "Total R/W (MB) | Non-compaction R/W (MB) | Opened tables |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for row in leveldb_rows:
        lines.append(
            "| {scheme} | {total_compactions} | {compaction_time_seconds} | "
            "{compaction_read_mb}/{compaction_write_mb} | {io_read_mb}/{io_write_mb} | "
            "{non_compaction_read_mb}/{non_compaction_write_mb} | {opened_tables} |".format(
                **{key: display(value) for key, value in row.items()}
            )
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def display_scheme(scheme: str) -> str:
    return {"PVstar": "PV*", "VPstar": "VP*"}.get(scheme, scheme)


def write_metric_summaries(
    output_dir: Path,
    end_block: int,
    leveldb_rows: list[dict[str, Any]],
    read_rows: list[dict[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    schemes = [display_scheme(row["scheme"]) for row in read_rows]
    read_summary_rows = [
        {
            "metric": "Negative Lookups",
            **{
                scheme: row["negative_sstable_lookups_per_read"]
                for scheme, row in zip(schemes, read_rows)
            },
        },
        {
            "metric": "Hit Rate (%)",
            **{
                scheme: row["data_cache_hit_rate_percent"]
                for scheme, row in zip(schemes, read_rows)
            },
        },
    ]
    read_summary = {
        "title": (
            "Average number of negative lookups per read and cache hit rate "
            f"through block {end_block}"
        ),
        "columns": ["metric", *schemes],
        "rows": read_summary_rows,
    }
    with (output_dir / "read_path_summary.csv").open(
        "w", newline="", encoding="utf-8"
    ) as stream:
        writer = csv.DictWriter(stream, fieldnames=read_summary["columns"])
        writer.writeheader()
        writer.writerows(read_summary_rows)

    compaction_summary_rows = []
    for leveldb in leveldb_rows:
        disk_size_bytes = leveldb.get("disk_size_bytes")
        compaction_summary_rows.append(
            {
                "Key": display_scheme(leveldb["scheme"]),
                "Time (s)": leveldb["compaction_time_seconds"],
                "Read (GB)": leveldb["compaction_read_mb"] / 1000,
                "Write (GB)": leveldb["compaction_write_mb"] / 1000,
                "Mem": leveldb["mem_compactions"],
                "L0": leveldb["level0_compactions"],
                "Non-L0": leveldb["non_level0_compactions"],
                "# of SSTs": leveldb["opened_tables"],
                "Size (GB)": (
                    disk_size_bytes / 1_000_000_000
                    if disk_size_bytes is not None
                    else None
                ),
            }
        )
    compaction_summary_columns = [
        "Key", "Time (s)", "Read (GB)", "Write (GB)", "Mem", "L0",
        "Non-L0", "# of SSTs", "Size (GB)",
    ]
    compaction_summary = {
        "title": (
            "Comparison of LevelDB compaction metrics and storage sizes "
            f"at block {end_block}"
        ),
        "columns": compaction_summary_columns,
        "rows": compaction_summary_rows,
    }
    with (output_dir / "compaction_storage_summary.csv").open(
        "w", newline="", encoding="utf-8"
    ) as stream:
        writer = csv.DictWriter(stream, fieldnames=compaction_summary_columns)
        writer.writeheader()
        writer.writerows(compaction_summary_rows)

    lines = [
        "# Storage metric summaries",
        "",
        f"## Read-path summary (through block {end_block:,})",
        "",
        "| Metric | " + " | ".join(schemes) + " |",
        "|---|" + "|".join("---:" for _ in schemes) + "|",
    ]
    for row in read_summary_rows:
        values = [
            (
                f"{row[scheme]:.2f}"
                if row["metric"] == "Hit Rate (%)"
                else f"{row[scheme]:.5g}"
            )
            if row[scheme] is not None
            else "N/A"
            for scheme in schemes
        ]
        lines.append(f"| {row['metric']} | " + " | ".join(values) + " |")
    lines.extend(
        [
            "",
            f"## Compaction/storage summary (at block {end_block:,})",
            "",
            "| Key | Time (s) | Read (GB) | Write (GB) | Mem | L0 | Non-L0 | # of SSTs | Size (GB) |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for row in compaction_summary_rows:
        lines.append(
            "| {Key} | {time:.2f} | {read:.3f} | {write:.3f} | {Mem} | "
            "{L0} | {Non-L0} | {sst} | {size} |".format(
                **row,
                time=row["Time (s)"],
                read=row["Read (GB)"],
                write=row["Write (GB)"],
                sst=row["# of SSTs"],
                size=(
                    f"{row['Size (GB)']:.3f}"
                    if row["Size (GB)"] is not None
                    else "N/A"
                ),
            )
        )
    (output_dir / "storage_metric_summaries.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )
    return read_summary, compaction_summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="smoke-report.json or run-report.json")
    parser.add_argument("--start-block", type=int, default=0)
    parser.add_argument("--end-block", type=int)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()

    report_path = args.report.resolve()
    report = load_json(report_path)
    end_block = args.end_block or report.get("target_block")
    if end_block is None:
        targets = {
            normalized_case(case, None)["target_block"] for case in report["cases"]
        }
        if len(targets) != 1:
            raise SystemExit("--end-block is required when cases have different targets")
        end_block = targets.pop()
    if args.start_block < 0 or args.start_block >= end_block:
        raise SystemExit("--start-block must be non-negative and less than --end-block")

    output_dir = (
        args.output_dir.resolve()
        if args.output_dir
        else report_path.parent / "storage-metrics"
    )
    output_dir.mkdir(parents=True, exist_ok=True)
    leveldb_rows: list[dict[str, Any]] = []
    read_rows: list[dict[str, Any]] = []
    provenance_rows: list[dict[str, Any]] = []

    for original in report["cases"]:
        case = normalized_case(original, report.get("target_block"))
        if not case["simblocks"] or not case["leveldb_stats"] or not case["read_stats"]:
            continue
        simblocks_path = resolve_path(case["simblocks"])
        leveldb_path = resolve_path(case["leveldb_stats"])
        read_final_path = resolve_path(case["read_stats"])
        leveldb_data = load_json(leveldb_path)
        end_leveldb = checkpoint(leveldb_data, end_block)
        start_leveldb = (
            checkpoint(leveldb_data, args.start_block) if args.start_block else None
        )
        leveldb_metrics = derive_leveldb_metrics(end_leveldb, start_leveldb)

        end_read_path = read_stats_checkpoint(
            read_final_path, case["experiment_id"], end_block
        )
        start_read_path = (
            read_stats_checkpoint(
                read_final_path, case["experiment_id"], args.start_block
            )
            if args.start_block
            else None
        )
        end_read = load_json(end_read_path)
        start_read = load_json(start_read_path) if start_read_path else None
        read_metrics = derive_read_metrics(subtract_read_stats(end_read, start_read))
        disk_size_bytes = simblock_checkpoint(simblocks_path, end_block).get("DiskSize")
        identity = {
            "case_id": case["case_id"],
            "experiment_id": case["experiment_id"],
            "scheme": case["scheme"],
            "start_block": args.start_block,
            "end_block": end_block,
            "database_bytes": (
                case["database_bytes"]
                if end_block == case["target_block"]
                else None
            ),
            "disk_size_bytes": disk_size_bytes,
        }
        leveldb_rows.append(identity | leveldb_metrics)
        read_rows.append(identity | read_metrics)
        provenance_rows.append(
            {
                "leveldb_stats": {
                    "path": portable_path(leveldb_path),
                    "sha256": sha256_file(leveldb_path),
                },
                "simblocks": {
                    "path": portable_path(simblocks_path),
                    "checkpoint": end_block,
                    "field": "DiskSize",
                },
                "end_read_stats": {
                    "path": portable_path(end_read_path),
                    "sha256": sha256_file(end_read_path),
                },
                "start_read_stats": (
                    {
                        "path": portable_path(start_read_path),
                        "sha256": sha256_file(start_read_path),
                    }
                    if start_read_path
                    else None
                ),
            }
        )

    if not leveldb_rows:
        raise SystemExit("the report contains no cases with both LevelDB and read stats")

    read_summary, compaction_summary = write_metric_summaries(
        output_dir, end_block, leveldb_rows, read_rows
    )
    payload = {
        "source_report": portable_path(report_path),
        "source_report_sha256": sha256_file(report_path),
        "start_block": args.start_block,
        "end_block": end_block,
        "formula_reference": "docs/STORAGE_METRICS.md",
        "read_path_summary": read_summary,
        "compaction_storage_summary": compaction_summary,
        "cases": [
            {
                "case_id": leveldb["case_id"],
                "experiment_id": leveldb["experiment_id"],
                "scheme": leveldb["scheme"],
                "inputs": provenance,
                "leveldb": {
                    key: value for key, value in leveldb.items()
                    if key not in {
                        "case_id", "experiment_id", "scheme", "start_block",
                        "end_block", "database_bytes", "disk_size_bytes",
                    }
                },
                "read": {
                    key: value for key, value in read.items()
                    if key not in {
                        "case_id", "experiment_id", "scheme", "start_block",
                        "end_block", "database_bytes", "disk_size_bytes",
                    }
                },
            }
            for leveldb, read, provenance in zip(
                leveldb_rows, read_rows, provenance_rows
            )
        ],
    }
    (output_dir / "storage_metrics.json").write_text(
        json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8"
    )
    write_csv(output_dir / "leveldb_metrics.csv", leveldb_rows)
    write_csv(output_dir / "read_metrics.csv", read_rows)
    write_markdown(
        output_dir / "storage_metrics.md",
        args.start_block,
        end_block,
        leveldb_rows,
        read_rows,
    )
    print(f"Extracted {len(leveldb_rows)} cases for blocks {args.start_block}–{end_block}")
    print(f"Output: {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
