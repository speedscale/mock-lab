import json
import sys
from pathlib import Path

results = Path(sys.argv[1])
summary = {}
for variant in ("original", "broken", "fixed"):
    run = results / variant
    verdict = json.loads((run / "replayed/replay-verdict.json").read_text())
    stats = json.loads((run / "stats.json").read_text())
    code = int((run / "exit-code.txt").read_text())
    assert verdict["summary"]["pairs"] == 8, variant
    assert (run / "stats.headers").read_text().startswith("HTTP/1.1 200"), variant
    assert stats["total"] == 24, variant
    if variant == "broken":
        assert code == 3 and verdict["verdict"] == "new-mismatch", verdict
        assert verdict["summary"]["newMismatches"] == 1, verdict
        failed = [p for p in verdict["pairs"] if p.get("newMismatch")]
        assert len(failed) == 1 and failed[0]["endpoint"] == "/api/stats", failed
        assert failed[0]["observedStatus"] == 200 and failed[0]["bodyMatch"] == "fail", failed
        assert failed[0]["bodyChanges"], failed
        assert all("by_maturity" in c["location"] for c in failed[0]["bodyChanges"]), failed
        assert stats["by_maturity"] == {}, stats
    else:
        assert code == 0 and verdict["verdict"] == "pass", verdict
        assert verdict["summary"]["mismatches"] == 0, verdict
        assert all(p["match"] == "pass" and p["bodyMatch"] == "pass" for p in verdict["pairs"]), verdict
        assert stats["by_maturity"] == {"Graduated": 16, "Incubating": 5, "Sandbox": 3}, stats
    summary[variant] = {"exitCode": code, "verdict": verdict["verdict"], **verdict["summary"], "stats": stats}
(results / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
