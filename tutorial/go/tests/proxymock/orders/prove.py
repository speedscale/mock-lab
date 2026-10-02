#!/usr/bin/env python3
"""Qualify candidate suites through the native CLI without accepting expectations."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "tests/proxymock/orders"
WORK = ROOT / "proxymock/suite-proof" / str(uuid.uuid4())
BIN = shutil.which(os.environ.get("PROXYMOCK_BIN", "proxymock"))
if not BIN:
    raise SystemExit("Set PROXYMOCK_BIN to a build with suite-v1 support.")
WORK.mkdir(parents=True, mode=0o700)
ENV = dict(os.environ, TUTORIAL_AUTH_TOKEN="fixture-" + uuid.uuid4().hex)
BASE = (FIXTURE / "suite.yaml").read_text()
RECORDS = []
OWNED = []


def replace(text, old, new):
    if old not in text:
        raise AssertionError("Fixture layout changed; update qualification inputs.")
    return text.replace(old, new)


def candidate(name, scenario, edits=()):
    text = BASE
    for old, new in edits:
        text = replace(text, old, new)
    text = replace(text, "scenarios: [regression, contract, load, chaos]",
                   "scenarios: [" + scenario + "]")
    path = WORK / (name + ".yaml")
    path.write_text(text)
    return path


def launch(path):
    process = subprocess.Popen(
        [BIN, "suite", "explore", str(path), "--profile", "ci"],
        cwd=ROOT, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    OWNED.append(process)
    return process


def collect(process, name, expected):
    stdout, stderr = process.communicate(timeout=90)
    if process.returncode != 2:
        raise AssertionError(name + ": candidate must exit 2, got " + str(process.returncode))
    paths = [line.removeprefix("Results: ") for line in stdout.splitlines()
             if line.startswith("Results: ")]
    if len(paths) != 1:
        raise AssertionError(name + ": native evidence missing")
    result_path = Path(paths[0])
    result = json.loads(result_path.read_text())
    observed = {case["id"]: case["status"] for case in result["cases"]}
    if observed != expected:
        raise AssertionError(name + ": unexpected verdict " + json.dumps(
            [{k: c.get(k) for k in ("id", "status", "reason")}
             for c in result["cases"]]))
    if list(result_path.parent.glob(".runtime-*")):
        raise AssertionError(name + ": private runtime was not removed")
    coverage = json.loads((result_path.parent / "coverage.json").read_text())
    RECORDS.append({"name": name, "exitCode": process.returncode,
                    "expectationRevision": result["expectationRevision"],
                    "programSha256": result.get("programSha256"),
                    "cases": result["cases"], "coverage": coverage})
    print(name + ": " + ", ".join(k + "=" + v for k, v in observed.items()), flush=True)
    return result, coverage


def check(name, path, scenario, status):
    return collect(launch(path), name, {scenario: status})


try:
    subprocess.run(["go", "build", "-o", ".suite-bin/orders", "."], cwd=ROOT, check=True)
    healthy = FIXTURE / "suite.yaml"
    subprocess.run([BIN, "suite", "validate", str(healthy)], cwd=ROOT, env=ENV, check=True)
    one, two = launch(healthy), launch(healthy)
    statuses = {key: "passed" for key in ("regression", "contract", "load", "chaos")}
    _, coverage = collect(one, "parallel-a", statuses)
    result, _ = collect(two, "parallel-b", statuses)
    load = next(c for c in result["cases"] if c["id"] == "load")
    if load["measurements"]["peakConcurrentRequests"] != 8 or load["mockMisses"]:
        raise AssertionError("Eight actors must preserve distinct row/body assertions with no misses")
    operations = lambda units: {(u["method"], u["path"]) for u in units if not u.get("status")}
    if (len(operations(coverage["denominator"])),
        len(operations(coverage["original"])),
        len(operations(coverage["passed"]))) != (6, 2, 5):
        raise AssertionError("Expected pinned coverage improvement from 2/6 to 5/6")

    wrong_source = WORK / "wrong-price"
    wrong_source.mkdir()
    for path in ROOT.iterdir():
        if path.name in ("go.mod", "go.sum") or (
                path.suffix == ".go" and not path.name.endswith("_test.go")):
            shutil.copy2(path, wrong_source / path.name)
    source = wrong_source / "upstream.go"
    source.write_text(replace(source.read_text(), "return 1200", "return 1"))
    subprocess.run(["go", "build", "-o", "orders", "."], cwd=wrong_source, check=True)
    wrong_exe = "./" + str((wrong_source / "orders").relative_to(ROOT))
    check("wrong-business-value", candidate("wrong-price", "regression", [
        ("start: [./.suite-bin/orders]", "start: [" + wrong_exe + "]")]),
        "regression", "failed")
    check("wrong-json-type", candidate("wrong-type", "contract", [
        ("APP_VERSION: v1", "APP_VERSION: v2")]), "contract", "failed")

    latency = WORK / "latency.json"
    latency.write_text(json.dumps([
        '(location REGEX "^/v1/projects"): status=503,latency=300ms,percent=100,duration=4s,name=slow-catalog']))
    config = json.loads((FIXTURE / "checks.json").read_text())
    config["id"] = "budgets"
    config["rules"].append({"metricName": "p95Latency", "value": 250, "action": "ALERT"})
    budget = WORK / "latency-budget.json"
    budget.write_text(json.dumps(config))
    edits = [("path: tests/proxymock/orders/faults.json", "path: " + str(latency.relative_to(ROOT))),
             ("path: tests/proxymock/orders/budgets.json", "path: " + str(budget.relative_to(ROOT))),
             ("recording: failure, testConfig: checks", "recording: failure, testConfig: budgets")]
    result, _ = check("latency-budget", candidate("latency", "chaos", edits), "chaos", "failed")
    if result["cases"][0]["verifiedFaultCalls"] < 1 or result["cases"][0]["goalsFailed"] < 1:
        raise AssertionError("Latency failure requires applied effect and failed native budget")

    result, _ = check("failed-recovery", candidate("recovery-defect", "chaos", [
        ('APP_SLOW: "0"', 'APP_SLOW: "0"\n    TUTORIAL_RECOVERY_DEFECT: "1"')]),
        "chaos", "failed")
    if result["cases"][0]["verifiedFaultCalls"] < 1 or result["cases"][0]["recoveryVerified"]:
        raise AssertionError("Recovery defect requires verified fault followed by unhealthy recovery")

    missing = WORK / "missing-mock"
    shutil.copytree(FIXTURE / "recording", missing)
    for path in missing.glob("*.json"):
        rr = json.loads(path.read_text())
        if rr.get("direction") == "OUT" and rr.get("l7protocol") == "http":
            path.unlink()
    check("missing-mock", candidate("missing-mock", "regression", [
        ("path: tests/proxymock/orders/recording", "path: " + str(missing.relative_to(ROOT)))]),
        "regression", "incomplete")
    inactive = WORK / "inactive.json"
    inactive.write_text(json.dumps([
        '(location REGEX "^/never-called"): status=503,percent=100,duration=4s,name=inactive']))
    check("inactive-fault", candidate("inactive", "chaos", [
        ("path: tests/proxymock/orders/faults.json", "path: " + str(inactive.relative_to(ROOT)))]),
        "chaos", "incomplete")

    interrupted = launch(candidate("interrupt", "load", [("duration: 2s", "duration: 15s")]))
    survivor = launch(healthy)
    time.sleep(2)
    interrupted.send_signal(signal.SIGINT)
    collect(interrupted, "interrupted-run", {"load": "incomplete"})
    collect(survivor, "interrupt-survivor", statuses)

    proof = ROOT / "proxymock/suite-proof" / "qualification.json"
    proof.write_text(json.dumps({"formatVersion": 1, "runtimeSha256": hashlib.sha256(
        Path(BIN).read_bytes()).hexdigest(), "explorationOnly": True, "runs": RECORDS}, indent=2) + "\n")
    print("Metadata-only qualification: " + str(proof), flush=True)
finally:
    for process in OWNED:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
    shutil.rmtree(WORK)
