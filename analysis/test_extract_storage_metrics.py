#!/usr/bin/env python3

import json
import tempfile
import unittest
from pathlib import Path

from extract_storage_metrics import (
    derive_leveldb_metrics,
    derive_read_metrics,
    simblock_checkpoint,
    subtract_read_stats,
    write_metric_summaries,
)


class MetricFormulaTests(unittest.TestCase):
    def test_reads_one_simblock_checkpoint(self):
        payload = {
            "00000000": {"Number": 0, "DiskSize": 0},
            "00050000": {"Number": 50000, "DiskSize": 123456},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simblocks.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            self.assertEqual(simblock_checkpoint(path, 50000)["DiskSize"], 123456)

    def test_read_formulas_match_documented_definitions(self):
        raw = {
            "ReadRequestCount": 10,
            "FakeMems": {"imm": 1, "mem": 2},
            "FakeLevels": {"0": 3, "1": 4, "2": 5},
            "RealMems": {"imm": 1, "mem": 1},
            "RealLevels": {"0": 7, "1": 2, "2": 3},
            "FakeLevel0Attempts": 8,
            "RealLevel0Attempts": 5,
            "NotFoundCount": 1,
            "CacheHitCounts": {
                "data-block": 3, "filter-block": 4, "index-block": 5
            },
            "CacheMissCounts": {
                "data-block": 1, "filter-block": 4, "index-block": 5
            },
            "BloomHitCount": 20,
            "BloomMissCount": 30,
            "BloomFalsePositiveCount": 2,
        }
        result = derive_read_metrics(raw)
        self.assertEqual(result["fake_non_l0_lookups"], 9)
        self.assertEqual(result["fake_disk_lookups"], 12)
        self.assertEqual(result["fake_total_lookups"], 15)
        self.assertEqual(result["negative_sstable_lookups_per_read"], 1.2)
        self.assertEqual(result["fake_disk_lookups_per_read"], 1.2)
        self.assertEqual(result["fake_total_lookups_per_read"], 1.5)
        self.assertEqual(result["data_cache_hit_rate_percent"], 75)
        self.assertEqual(result["bloom_false_positive_rate"], 2 / 32)
        self.assertEqual(result["bloom_positive_predictive_value"], 0.9)
        self.assertEqual(result["bloom_skip_rate"], 0.6)

    def test_checkpoint_subtraction_precedes_derived_ratios(self):
        start = {
            "ReadRequestCount": 10,
            "FakeLevels": {"0": 4, "1": 3},
            "CacheHitCounts": {"data-block": 2},
        }
        end = {
            "ReadRequestCount": 25,
            "FakeLevels": {"0": 10, "1": 9},
            "CacheHitCounts": {"data-block": 8},
        }
        delta = subtract_read_stats(end, start)
        self.assertEqual(delta["ReadRequestCount"], 15)
        self.assertEqual(delta["FakeLevels"], {"0": 6, "1": 6})
        self.assertEqual(delta["CacheHitCounts"], {"data-block": 6})

    def test_leveldb_interval_and_non_compaction_io(self):
        start = {
            "compaction": {"total": {
                "tables": 2, "size_mb": 3, "time_sec": 4,
                "read_mb": 5, "write_mb": 6,
            }},
            "io": {"read_mb": 20, "write_mb": 30},
            "write_delay": {"delay_n": 1, "delay_sec": 2},
            "compaction_count": {
                "mem_comp": 1, "level0_comp": 2,
                "non_level0_comp": 3, "seek_comp": 4,
            },
            "opened_tables": 7,
        }
        end = {
            "compaction": {"total": {
                "tables": 12, "size_mb": 13, "time_sec": 14,
                "read_mb": 15, "write_mb": 16,
            }},
            "io": {"read_mb": 50, "write_mb": 70},
            "write_delay": {"delay_n": 3, "delay_sec": 5},
            "compaction_count": {
                "mem_comp": 2, "level0_comp": 4,
                "non_level0_comp": 6, "seek_comp": 8,
            },
            "opened_tables": 9,
        }
        result = derive_leveldb_metrics(end, start)
        self.assertEqual(result["compaction_read_mb"], 10)
        self.assertEqual(result["io_read_mb"], 30)
        self.assertEqual(result["non_compaction_read_mb"], 20)
        self.assertEqual(result["non_compaction_write_mb"], 30)
        self.assertEqual(result["total_compactions"], 10)
        self.assertEqual(result["opened_tables"], 9)

    def test_metric_summary_outputs_use_semantic_names(self):
        leveldb_rows = [{
            "scheme": "PVstar",
            "compaction_time_seconds": 1,
            "compaction_read_mb": 2,
            "compaction_write_mb": 3,
            "mem_compactions": 4,
            "level0_compactions": 5,
            "non_level0_compactions": 6,
            "opened_tables": 7,
            "disk_size_bytes": 8_000_000_000,
        }]
        read_rows = [{
            "scheme": "PVstar",
            "negative_sstable_lookups_per_read": 0.25,
            "data_cache_hit_rate_percent": 75,
        }]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            read_summary, compaction_summary = write_metric_summaries(
                output, 500_000, leveldb_rows, read_rows
            )
            self.assertEqual(read_summary["columns"], ["metric", "PV*"])
            self.assertEqual(compaction_summary["rows"][0]["Size (GB)"], 8)
            self.assertTrue((output / "read_path_summary.csv").is_file())
            self.assertTrue(
                (output / "compaction_storage_summary.csv").is_file()
            )
            self.assertTrue(
                (output / "storage_metric_summaries.md").is_file()
            )


if __name__ == "__main__":
    unittest.main()
