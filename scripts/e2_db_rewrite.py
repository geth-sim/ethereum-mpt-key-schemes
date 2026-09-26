#!/usr/bin/env python3
"""Run selected compression rewrites; server progress is streamed by the runner."""

import argparse
import json
from pathlib import Path
import socket


REWRITE_CASES = {
    "E2_random_keys": ("random_keys", True, False),
    "E2_random_values": ("random_values", False, True),
    "E2_random_keys_values": ("random_keys_values", True, True),
}


def inspect_source_database(db_path, profile, target_block=None):
    """Return the latest completed E1 source record, or None for a missing DB."""
    db_path = Path(db_path)
    if not db_path.exists() or (db_path.is_dir() and not any(db_path.iterdir())):
        return None
    current = db_path / "CURRENT"
    if not current.is_file():
        raise ValueError("the existing E1_PVstar directory has no LevelDB CURRENT file")
    manifest = current.read_text().strip()
    if not manifest.startswith("MANIFEST-") or Path(manifest).name != manifest or not (db_path / manifest).is_file():
        raise ValueError("the existing E1_PVstar database has no valid LevelDB manifest")

    family = db_path.parent.parent
    candidates = []
    for path in (family / "run-report.json", family / "run-report_E1_PVstar.json"):
        if not path.is_file():
            continue
        try:
            report = json.loads(path.read_text())
            case = next((row for row in report["cases"]
                         if row["case_id"] == "E1_PVstar"), None)
            if case is None:
                continue
        except (ValueError, KeyError, TypeError):
            case = None
        candidates.append((path.stat().st_mtime_ns, path, case))
    if not candidates:
        raise ValueError("no E1_PVstar completion report was found for the existing database")
    modified, path, case = max(candidates, key=lambda item: item[0])
    if case is None:
        raise ValueError(f"the latest E1 report is invalid: {path}")
    for name in ("simulator.log", "client.log"):
        log = db_path.parent / name
        if log.exists() and log.stat().st_mtime_ns > modified:
            raise ValueError("a newer E1_PVstar replay has no completion report")
    if case.get("status") != "complete" or case.get("client_exit_status") != 0:
        raise ValueError("the latest E1_PVstar replay did not complete successfully")
    expected = {"profile": profile, "scheme": "PVstar", "variant": "fast",
                "state_mode": "archive", "backend": "leveldb", "compression": "snappy"}
    if any(case.get(key) != value for key, value in expected.items()):
        raise ValueError("the E1_PVstar report does not match the required source configuration")
    resolved = case.get("resolved", {})
    if not isinstance(resolved, dict):
        raise ValueError("the E1_PVstar report has invalid block-range metadata")
    completed = resolved.get("completed_block")
    if type(completed) is not int or completed <= 0 or completed != resolved.get("target_block"):
        raise ValueError("the E1_PVstar report does not confirm its completed block range")
    if target_block is not None and completed != target_block:
        raise ValueError(f"the existing E1_PVstar database ends at block {completed}, "
                         f"but TARGET_BLOCK requests {target_block}")
    return {"report": str(path), "target_block": completed}


def request(sock, message, json_response=False):
    sock.sendall(message.encode())
    response = bytearray()
    while True:
        chunk = sock.recv(4097)
        if not chunk:
            raise ConnectionError(f"simulator closed the connection during {message.split(',')[0]}")
        response.extend(chunk)
        try:
            text = response.decode()
        except UnicodeDecodeError:
            # A UTF-8 path in the final reply can also cross a packet boundary.
            continue
        if text.startswith("error:"):
            raise RuntimeError(text)
        if json_response:
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                # TCP may split a final JSON reply across multiple receives.
                continue
        if text == "success":
            return text
        if not "success".startswith(text):
            raise RuntimeError(f"unexpected simulator response: {text}")


def write_report(path, status, rows, **details):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps({"status": status, "rewrites": rows, **details}, indent=2) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--db-path", required=True)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--output", required=True)
    parser.add_argument("--case", action="append", choices=REWRITE_CASES,
                        help="rewrite case to run; repeat to select multiple cases (default: all)")
    args = parser.parse_args()
    case_ids = args.case or list(REWRITE_CASES)
    case_count = len(case_ids)

    rows = []
    stage = "initializing"
    write_report(args.output, "RUNNING", rows, current_stage=stage)
    try:
        # Rewriting a paper-scale database can take hours. There is no socket
        # deadline: progress comes from the simulator log, and Ctrl-C can stop it.
        with socket.create_connection((args.host, args.port), timeout=None) as sock:
            request(sock, f"setDbPath,{args.db_path}")
            request(sock, "setDatabase,0")
            for index, case_id in enumerate(case_ids, start=1):
                stage, random_keys, random_values = REWRITE_CASES[case_id]
                print(f"\n[E2 {index}/{case_count}] Rewriting {stage}; progress follows in the simulator log.", flush=True)
                write_report(args.output, "RUNNING", rows, current_stage=stage)
                result = request(
                    sock,
                    f"convertKeyValues,{str(random_keys).lower()},{str(random_values).lower()},"
                    f"{stage},{args.seed}",
                    json_response=True,
                )
                if result.get("status") != "success":
                    raise RuntimeError(f"rewrite {stage} did not succeed: {result}")
                rows.append({**result, "case_id": case_id})
                write_report(args.output, "RUNNING", rows, current_stage=stage)
                print(f"[E2 {index}/{case_count}] Completed {stage}: "
                      f"{result['entry_count']:,} entries, {result['database_bytes']:,} bytes, "
                      f"{result['elapsed_seconds']:.1f} seconds.", flush=True)
    except (Exception, KeyboardInterrupt) as error:
        write_report(args.output, "INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAILED",
                     rows, current_stage=stage, error=str(error) or "interrupted by user")
        raise

    write_report(args.output, "PASS", rows)


if __name__ == "__main__":
    main()
