#!/usr/bin/env python3
import argparse
import json
import socket


def request(sock, message):
    sock.sendall(message.encode())
    response = sock.recv(4097).decode()
    if response.startswith("error:"):
        raise RuntimeError(response)
    return response


parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--db-path", required=True)
parser.add_argument("--seed", type=int, default=1)
parser.add_argument("--output", required=True)
args = parser.parse_args()

rows = []
with socket.create_connection((args.host, args.port), timeout=120) as sock:
    request(sock, f"setDbPath,{args.db_path}")
    request(sock, "setDatabase,0")
    for suffix, random_keys, random_values in (
        ("random_keys", True, False),
        ("random_values", False, True),
        ("random_keys_values", True, True),
    ):
        raw = request(
            sock,
            f"convertKeyValues,{str(random_keys).lower()},{str(random_values).lower()},"
            f"{suffix},{args.seed}",
        )
        rows.append(json.loads(raw))

with open(args.output, "w", encoding="utf-8") as f:
    json.dump({"status": "PASS", "rewrites": rows}, f, indent=2)
    f.write("\n")
