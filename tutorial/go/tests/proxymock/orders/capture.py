#!/usr/bin/env python3
"""Capture owned local dependencies and export a sanitized candidate recording."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--improve", action="store_true", help="Add documented operation/error cases")
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
binary = shutil.which(os.environ.get("PROXYMOCK_BIN", "proxymock"))
if not binary:
    raise SystemExit("Set PROXYMOCK_BIN or install proxymock.")
work = root / "proxymock/captures" / str(uuid.uuid4())
work.mkdir(parents=True, mode=0o700)


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_ready(url):
    for _ in range(100):
        try:
            with urllib.request.urlopen(url, timeout=.2) as response:
                if response.status == 200:
                    return
        except Exception:
            time.sleep(.1)
    raise RuntimeError("Owned fixture did not become ready")


def check_canary(value, canary):
    if isinstance(value, dict):
        for key, item in value.items():
            if canary in key:
                raise RuntimeError("Redaction verification failed")
            if key.endswith("Base64") and isinstance(item, str):
                if canary.encode() in base64.b64decode(item):
                    raise RuntimeError("Decoded redaction verification failed")
            check_canary(item, canary)
    elif isinstance(value, list):
        for item in value:
            check_canary(item, canary)
    elif isinstance(value, str) and canary in value:
        raise RuntimeError("Redaction verification failed")


app, inbound, outbound, postgres, dbmap, catalog, catmap = [port() for _ in range(7)]
name = "orders-capture-" + uuid.uuid4().hex[:12]
canary = "RAW_CANARY_AUTH_" + uuid.uuid4().hex
environment = dict(os.environ, PORT=str(app), TUTORIAL_AUTH_TOKEN=canary,
                   TUTORIAL_ID_SEED="orders-suite-v1", TUTORIAL_CLOCK="2026-10-01T12:00:00Z",
                   DATABASE_URL=f"postgres://tutorial@127.0.0.1:{dbmap}/tutorial?sslmode=disable",
                   DEMO_API_URL=f"http://127.0.0.1:{catmap}", APP_VERSION="v1", APP_SLOW="0")
environment.pop("TUTORIAL_RECOVERY_DEFECT", None)
processes = []
try:
    for command, target in ((".", "orders"), ("./cmd/catalog", "catalog"),
                            ("./cmd/small-traffic", "small-traffic")):
        subprocess.run(["go", "build", "-o", ".suite-bin/" + target, command], cwd=root, check=True)
    subprocess.run(["docker", "run", "--detach", "--name", name, "--cpus", "2",
                    "--memory", "512m", "-p", f"127.0.0.1:{postgres}:5432",
                    "-e", "POSTGRES_USER=tutorial", "-e", "POSTGRES_DB=tutorial",
                    "-e", "POSTGRES_HOST_AUTH_METHOD=trust",
                    "-v", str(root.parent / "contract/schema.sql") +
                    ":/docker-entrypoint-initdb.d/schema.sql:ro", "postgres:16"],
                   check=True, stdout=subprocess.DEVNULL)
    for attempt in range(100):
        ready = subprocess.run(["docker", "exec", name, "pg_isready", "-U", "tutorial"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if ready.returncode == 0:
            break
        time.sleep(.2)
    else:
        raise RuntimeError("Owned Postgres did not become ready")
    with (work / "private.log").open("wb") as log:
        processes.append(subprocess.Popen([str(root / ".suite-bin/catalog")],
                                          env=dict(environment, PORT=str(catalog)), stdout=log, stderr=log))
        wait_ready(f"http://127.0.0.1:{catalog}/healthz")
        dlp = work / "dlp.json"
        dlp.write_text(json.dumps({"id": "orders-local", "redactlist": {"entries": {
            "all": ["authorization", "cookie", "password"]}}, "discoverPatterns": True}))
        raw = work / "raw"
        processes.append(subprocess.Popen(
            [binary, "record", "--out", str(raw), "--out-format", "json", "--app-port", str(app),
             "--proxy-in-port", str(inbound), "--proxy-out-port", str(outbound),
             "--map", f"{dbmap}=postgres://127.0.0.1:{postgres}",
             "--map", f"{catmap}=http://127.0.0.1:{catalog}", "--dlp-config", str(dlp),
             "--", str(root / ".suite-bin/orders")], cwd=root, env=environment, stdout=log, stderr=log))
        wait_ready(f"http://127.0.0.1:{app}/healthz")
        command = [str(root / ".suite-bin/small-traffic"), "-target", f"http://127.0.0.1:{inbound}"]
        if args.improve:
            command.append("-improve")
        subprocess.run(command, env=environment, check=True)
        time.sleep(.5)
        processes[-1].send_signal(signal.SIGINT)
        processes[-1].wait(timeout=20)
    recording = work / "sanitized"
    recording.mkdir(mode=0o700)
    counts = {"IN": 0, "OUT": 0}
    for path in raw.rglob("*.json"):
        rr = json.loads(path.read_text())
        if rr.get("msgType") != "rrpair":
            continue
        headers = rr.get("http", {}).get("req", {}).get("headers", {})
        for key in list(headers):
            if key.lower() == "authorization":
                headers[key] = ["Bearer ${{secret:runtime/TUTORIAL_AUTH_TOKEN}}"]
        rr.pop("tokenList", None)
        rr.pop("signature", None)
        for key in ("hostname", "cluster", "pod", "file"):
            rr.pop(key, None)
        tags = rr.get("tags", {})
        for key in list(tags):
            if key.lower() in ("hostname", "local_hostname", "cmdline", "cwd", "file", "cluster", "pod"):
                tags.pop(key)
        check_canary(rr, canary)
        identity = uuid.UUID(bytes=base64.b64decode(rr["uuid"]))
        target = recording / (rr["direction"] + "-" + str(identity) + "Z.json")
        target.write_text(json.dumps(rr, indent=2) + "\n")
        target.chmod(0o600)
        counts[rr["direction"]] += 1
    expected = 10 if args.improve else 4
    if counts["IN"] != expected or counts["OUT"] == 0:
        raise RuntimeError("Capture shape incomplete")
    inventory = {"inbound": counts["IN"], "outbound": counts["OUT"],
                 "routes": {"db": f"127.0.0.1:{postgres}", "catalog": f"127.0.0.1:{catalog}"},
                 "redaction": {"revision": "orders-local-v1", "verified": True,
                               "canaries": [{"sha256": hashlib.sha256(canary.encode()).hexdigest(),
                                            "length": len(canary)}]}}
    (work / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    shutil.rmtree(raw)
    (work / "private.log").unlink()
    print("Sanitized candidate: " + str(recording))
    print("Capture inventory: " + str(work / "inventory.json"))
finally:
    for process in processes:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
