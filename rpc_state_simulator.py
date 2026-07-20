#!/usr/bin/env python3
"""Replay locally synced Ethereum blocks through the state simulator.

This quick-reproduction client intentionally uses only the Python standard
library. It mirrors the simulator socket messages used by the original
MariaDB-backed client, but reads canonical blocks from a local geth JSON-RPC
endpoint.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--simulator-host", default="127.0.0.1")
    parser.add_argument("--simulator-port", type=int, required=True)
    parser.add_argument("--start-block", type=int, default=0)
    parser.add_argument("--end-block", type=int, required=True)
    parser.add_argument("--target-hash", required=True)
    parser.add_argument("--db-path", type=Path, required=True)
    parser.add_argument("--delete-db", action="store_true")
    parser.add_argument("--progress-interval", type=int, default=1000)
    parser.add_argument("--rpc-retries", type=int, default=5)
    parser.add_argument("--summary-output", type=Path)
    return parser.parse_args()


def quantity(value: str | None) -> int:
    if value is None:
        return 0
    return int(value, 16)


def hex_data(value: str | None) -> str:
    if not value:
        return ""
    return value[2:] if value.startswith("0x") else value


def nullable_quantity(value: str | None) -> str:
    return "None" if value is None else str(quantity(value))


def nullable_address(value: str | None) -> str:
    return "None" if value is None else hex_data(value)


class JsonRpc:
    def __init__(self, url: str, retries: int) -> None:
        self.url = url
        self.retries = retries
        self.request_id = 0

    def call(self, method: str, params: list[Any]) -> Any:
        self.request_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
                "id": self.request_id,
            }
        ).encode()
        request = urllib.request.Request(
            self.url, payload, {"Content-Type": "application/json"}
        )
        last_error: Exception | None = None
        for attempt in range(1, self.retries + 1):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    result = json.load(response)
                if "error" in result:
                    raise RuntimeError(f"JSON-RPC {method} failed: {result['error']}")
                return result.get("result")
            except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
                last_error = error
                if attempt < self.retries:
                    time.sleep(attempt)
        raise RuntimeError(f"JSON-RPC {method} failed after retries: {last_error}")


@dataclass
class SimulatorClient:
    host: str
    port: int

    def __post_init__(self) -> None:
        self.socket = socket.create_connection((self.host, self.port), timeout=30)
        self.socket.settimeout(120)

    def close(self) -> None:
        self.socket.close()

    def command(self, *parts: object, terminator: bool = False) -> str:
        message = ",".join(str(part) for part in parts)
        if terminator:
            message += ",@"
        self.socket.sendall(message.encode())
        response = self.socket.recv(4096)
        if not response:
            raise RuntimeError(
                "simulator closed the connection; inspect logs/simulator.console.log"
            )
        decoded = response.decode()
        if decoded != "success":
            raise RuntimeError(f"simulator command {parts[0]} failed: {decoded}")
        return decoded

    def query(self, name: str) -> str:
        self.socket.sendall(name.encode())
        response = self.socket.recv(4096)
        if not response:
            raise RuntimeError(
                "simulator closed the connection; inspect logs/simulator.console.log"
            )
        return response.decode()


def insert_header(simulator: SimulatorClient, block: dict[str, Any]) -> None:
    simulator.command(
        "insertHeader",
        quantity(block["number"]),
        quantity(block["timestamp"]),
        hex_data(block["miner"]),
        quantity(block["difficulty"]),
        quantity(block["gasUsed"]),
        quantity(block["gasLimit"]),
        hex_data(block["extraData"]),
        hex_data(block["parentHash"]),
        hex_data(block["sha3Uncles"]),
        hex_data(block["stateRoot"]),
        hex_data(block["nonce"]),
        hex_data(block["receiptsRoot"]),
        hex_data(block["transactionsRoot"]),
        hex_data(block["mixHash"]),
        hex_data(block["logsBloom"]),
        quantity(block.get("baseFeePerGas")),
    )


def insert_uncles(
    simulator: SimulatorClient,
    rpc: JsonRpc,
    block_number: int,
    uncle_hashes: list[str],
) -> None:
    parts: list[object] = ["insertUncles", block_number]
    for index in range(len(uncle_hashes)):
        uncle = rpc.call(
            "eth_getUncleByBlockNumberAndIndex",
            [hex(block_number), hex(index)],
        )
        if uncle is None:
            raise RuntimeError(f"missing uncle {index} in block {block_number}")
        parts.extend([hex_data(uncle["miner"]), quantity(uncle["number"])])
    simulator.command(*parts)


def insert_transaction(
    simulator: SimulatorClient, transaction: dict[str, Any]
) -> None:
    simulator.command(
        "insertTransactionArgs",
        hex_data(transaction["from"]),
        nullable_address(transaction.get("to")),
        quantity(transaction["gas"]),
        nullable_quantity(transaction.get("gasPrice")),
        quantity(transaction["value"]),
        quantity(transaction["nonce"]),
        hex_data(transaction["input"]),
        nullable_quantity(transaction.get("maxFeePerGas")),
        nullable_quantity(transaction.get("maxPriorityFeePerGas")),
        terminator=True,
    )


def insert_access_lists(
    simulator: SimulatorClient, transactions: list[dict[str, Any]]
) -> None:
    for transaction_index, transaction in enumerate(transactions):
        for entry in transaction.get("accessList") or []:
            simulator.command(
                "insertTransactionAccessListV2",
                transaction_index,
                hex_data(entry["address"]),
                *(hex_data(key) for key in entry.get("storageKeys", [])),
                terminator=True,
            )


def main() -> int:
    args = parse_args()
    if args.start_block != 0:
        raise SystemExit("quick reproduction must replay from genesis (--start-block 0)")
    if args.end_block < args.start_block:
        raise SystemExit("--end-block must not be smaller than --start-block")

    rpc = JsonRpc(args.rpc_url, args.rpc_retries)
    target = rpc.call("eth_getBlockByNumber", [hex(args.end_block), False])
    if target is None:
        raise SystemExit(f"local geth does not contain target block {args.end_block}")
    if target["hash"].lower() != args.target_hash.lower():
        raise SystemExit(
            f"target hash mismatch: expected {args.target_hash}, got {target['hash']}"
        )

    args.db_path.mkdir(parents=True, exist_ok=True)
    simulator = SimulatorClient(args.simulator_host, args.simulator_port)
    started = time.monotonic()
    total_transactions = 0
    total_uncles = 0
    try:
        experiment_id = simulator.query("getExperimentID")
        if not experiment_id:
            raise RuntimeError("simulator returned an empty experiment ID")
        simulator.command("setDbPath", str(args.db_path.resolve()))
        simulator.command("setDatabase", 1 if args.delete_db else 0)
        setup_completed = time.monotonic()
        replay_started = setup_completed

        for block_number in range(args.start_block, args.end_block + 1):
            block = rpc.call("eth_getBlockByNumber", [hex(block_number), True])
            if block is None:
                raise RuntimeError(f"missing canonical block {block_number}")
            if quantity(block["number"]) != block_number:
                raise RuntimeError(f"RPC returned the wrong block for {block_number}")

            transactions = block["transactions"]
            uncles = block["uncles"]
            insert_header(simulator, block)
            insert_uncles(simulator, rpc, block_number, uncles)
            for transaction in transactions:
                insert_transaction(simulator, transaction)
            insert_access_lists(simulator, transactions)
            simulator.command("executeTransactionArgsList")

            total_transactions += len(transactions)
            total_uncles += len(uncles)
            if (
                block_number == args.start_block
                or block_number == args.end_block
                or block_number % args.progress_interval == 0
            ):
                elapsed = time.monotonic() - started
                completed = block_number - args.start_block + 1
                print(
                    f"replayed block {block_number}/{args.end_block} "
                    f"({completed / elapsed:.1f} blocks/s, "
                    f"{total_transactions} txs, {total_uncles} uncles)",
                    flush=True,
                )

        replay_completed = time.monotonic()
        simulator.command("commitDirtyStates")
        simulator.command("saveLevelDBStats")
        simulator.command("saveSimBlocks", "quick", args.end_block + 1)
        finalize_completed = time.monotonic()
    finally:
        simulator.close()

    elapsed = time.monotonic() - started
    print()
    print("QUICK REPLAY: PASS")
    print(f"blocks:       {args.start_block}..{args.end_block}")
    print(f"transactions: {total_transactions}")
    print(f"uncles:       {total_uncles}")
    print(f"target hash:  {target['hash']}")
    print(f"experiment:   {experiment_id}")
    print(f"setup:        {setup_completed - started:.1f} seconds")
    print(f"block replay: {replay_completed - replay_started:.1f} seconds")
    print(f"finalize:     {finalize_completed - replay_completed:.1f} seconds")
    print(f"elapsed:      {elapsed:.1f} seconds")
    if args.summary_output:
        args.summary_output.parent.mkdir(parents=True, exist_ok=True)
        summary = {
            "status": "PASS",
            "start_block": args.start_block,
            "end_block": args.end_block,
            "target_hash": target["hash"],
            "experiment_id": experiment_id,
            "transactions": total_transactions,
            "uncles": total_uncles,
            "setup_seconds": round(setup_completed - started, 3),
            "block_replay_seconds": round(replay_completed - replay_started, 3),
            "finalize_seconds": round(finalize_completed - replay_completed, 3),
            "elapsed_seconds": round(elapsed, 3),
        }
        with args.summary_output.open("w", encoding="utf-8") as output:
            json.dump(summary, output, indent=2)
            output.write("\n")
        print(f"summary:      {args.summary_output}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        sys.exit(130)
