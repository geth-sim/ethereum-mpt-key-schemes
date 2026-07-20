#!/usr/bin/env python3
"""Materialize the simulator's replay input from a local geth RPC in MariaDB."""

from __future__ import annotations

import argparse
import json
import time
import urllib.request
from typing import Any

import pymysql


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", default="")
    parser.add_argument("--database", required=True)
    parser.add_argument("--start-block", type=int, default=0)
    parser.add_argument("--end-block", type=int, required=True)
    parser.add_argument("--target-hash", required=True)
    parser.add_argument("--commit-interval", type=int, default=1000)
    parser.add_argument("--progress-interval", type=int, default=1000)
    return parser.parse_args()


class Rpc:
    def __init__(self, url: str) -> None:
        self.url = url
        self.request_id = 0

    def call(self, method: str, params: list[Any]) -> Any:
        self.request_id += 1
        body = json.dumps(
            {"jsonrpc": "2.0", "method": method, "params": params, "id": self.request_id}
        ).encode()
        request = urllib.request.Request(
            self.url, body, {"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]


def integer(value: str | None) -> int | None:
    return None if value is None else int(value, 16)


def binary(value: str | None, width: int | None = None) -> bytes | None:
    if value is None:
        return None
    raw = bytes.fromhex(value.removeprefix("0x"))
    return raw.rjust(width, b"\0") if width is not None else raw


def main() -> int:
    args = arguments()
    if args.start_block != 0:
        raise SystemExit("the artifact workload must be materialized from genesis")
    rpc = Rpc(args.rpc_url)
    target = rpc.call("eth_getBlockByNumber", [hex(args.end_block), False])
    if target is None or target["hash"].lower() != args.target_hash.lower():
        actual = None if target is None else target["hash"]
        raise SystemExit(f"target hash mismatch: expected {args.target_hash}, got {actual}")

    connection = pymysql.connect(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        database=args.database,
        autocommit=False,
    )
    started = time.monotonic()
    with connection, connection.cursor() as cursor:
        cursor.execute("SELECT COUNT(*), MIN(number), MAX(number) FROM blocks")
        block_count, minimum_block, maximum_block = cursor.fetchone()
        if block_count:
            if minimum_block != args.start_block or block_count != maximum_block + 1:
                raise RuntimeError(
                    "blocks table is not a contiguous genesis prefix: "
                    f"count={block_count}, min={minimum_block}, max={maximum_block}"
                )
            resume_block = maximum_block + 1
        else:
            resume_block = args.start_block

        cursor.execute("SELECT COUNT(*) FROM transactions")
        transaction_count = cursor.fetchone()[0]
        cursor.execute("SELECT COUNT(*) FROM uncles")
        uncle_count = cursor.fetchone()[0]

        if resume_block > args.end_block:
            print(
                f"MariaDB already contains blocks 0..{maximum_block}; "
                f"configured target {args.end_block} needs no import",
                flush=True,
            )
        elif resume_block > args.start_block:
            print(
                f"resuming after committed block {resume_block - 1} "
                f"({transaction_count} txs, {uncle_count} uncles)",
                flush=True,
            )

        for number in range(resume_block, args.end_block + 1):
            block = rpc.call("eth_getBlockByNumber", [hex(number), True])
            if block is None or integer(block["number"]) != number:
                raise RuntimeError(f"missing or incorrect block {number}")

            cursor.execute(
                """INSERT INTO blocks
                   (number,timestamp,miner,difficulty,gasused,gaslimit,extradata,
                    parenthash,sha3uncles,stateroot,nonce,receiptsroot,
                    transactionsroot,mixhash,logsbloom,basefee)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                   ON DUPLICATE KEY UPDATE stateroot=VALUES(stateroot)""",
                (
                    number,
                    integer(block["timestamp"]),
                    binary(block["miner"], 20),
                    integer(block["difficulty"]),
                    integer(block["gasUsed"]),
                    integer(block["gasLimit"]),
                    binary(block["extraData"]),
                    binary(block["parentHash"], 32),
                    binary(block["sha3Uncles"], 32),
                    binary(block["stateRoot"], 32),
                    binary(block["nonce"], 8),
                    binary(block["receiptsRoot"], 32),
                    binary(block["transactionsRoot"], 32),
                    binary(block["mixHash"], 32),
                    binary(block.get("logsBloom")),
                    integer(block.get("baseFeePerGas")),
                ),
            )

            for index, tx in enumerate(block["transactions"]):
                tx_index = integer(tx.get("transactionIndex"))
                if tx_index is None:
                    tx_index = index
                cursor.execute(
                    """INSERT IGNORE INTO transactions
                       (blocknumber,transactionindex,`from`,`to`,gas,gasprice,
                        value,nonce,input,maxfeepergas,maxpriorityfeepergas)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                    (
                        number,
                        tx_index,
                        binary(tx["from"], 20),
                        binary(tx.get("to"), 20),
                        integer(tx["gas"]),
                        integer(tx.get("gasPrice")),
                        integer(tx["value"]),
                        integer(tx["nonce"]),
                        binary(tx["input"]),
                        integer(tx.get("maxFeePerGas")),
                        integer(tx.get("maxPriorityFeePerGas")),
                    ),
                )
                cursor.execute(
                    "DELETE FROM transactions_accesslist "
                    "WHERE blocknumber=%s AND transactionindex=%s",
                    (number, tx_index),
                )
                for access_index, entry in enumerate(tx.get("accessList") or []):
                    keys = entry.get("storageKeys") or [None]
                    for key in keys:
                        cursor.execute(
                            """INSERT INTO transactions_accesslist
                               (blocknumber,transactionindex,accesslistindex,
                                address,storagekeys)
                               VALUES (%s,%s,%s,%s,%s)""",
                            (
                                number,
                                tx_index,
                                access_index,
                                binary(entry["address"], 20),
                                binary(key, 32),
                            ),
                        )
                transaction_count += 1

            cursor.execute("DELETE FROM uncles WHERE blocknumber=%s", (number,))
            for position in range(len(block["uncles"])):
                uncle = rpc.call(
                    "eth_getUncleByBlockNumberAndIndex", [hex(number), hex(position)]
                )
                if uncle is None:
                    raise RuntimeError(f"missing uncle {position} in block {number}")
                cursor.execute(
                    """INSERT INTO uncles
                       (blocknumber,uncleheight,uncleposition,miner)
                       VALUES (%s,%s,%s,%s)""",
                    (
                        number,
                        integer(uncle["number"]),
                        position,
                        binary(uncle["miner"], 20),
                    ),
                )
                uncle_count += 1

            if number % args.commit_interval == 0 or number == args.end_block:
                connection.commit()
            if (
                number == args.start_block
                or number == args.end_block
                or number % args.progress_interval == 0
            ):
                elapsed = time.monotonic() - started
                print(
                    f"materialized block {number}/{args.end_block} "
                    f"({number + 1:.0f} blocks, {transaction_count} txs, "
                    f"{uncle_count} uncles, {(number + 1) / elapsed:.1f} blocks/s)",
                    flush=True,
                )

        for table, expected in (("transactions", transaction_count), ("uncles", uncle_count)):
            cursor.execute(f"SELECT COUNT(*) FROM `{table}`")
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise RuntimeError(f"{table} count mismatch: {actual} != {expected}")
        cursor.execute(
            "SELECT COUNT(*) FROM blocks WHERE number BETWEEN %s AND %s",
            (args.start_block, args.end_block),
        )
        actual_blocks = cursor.fetchone()[0]
        expected_blocks = args.end_block - args.start_block + 1
        if actual_blocks != expected_blocks:
            raise RuntimeError(
                f"blocks count mismatch: {actual_blocks} != {expected_blocks}"
            )

    print(
        f"MARIADB IMPORT: PASS ({args.end_block + 1} canonical-prefix blocks, "
        f"{transaction_count} transactions, {uncle_count} uncles)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
