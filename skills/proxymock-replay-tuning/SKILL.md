---
name: proxymock-replay-tuning
description: Run and tune a local HTTP/HTTPS proxymock replay by routing replay RRPair requests through proxymock mock, measuring HIT/MISS/PASSTHROUGH outcomes, and identifying mock signatures or transforms to adjust. Use when users ask to tune a replay locally, compare proxymock recordings, improve mock match rate, or diagnose replay misses with proxymock files.
argument-hint: --mock-in <dir> --replay-in <dir>
---

# proxymock Traffic Replay Tuning

Tune local HTTP/HTTPS mocks by replaying RRPair traffic through `proxymock mock` and counting match outcomes.
Use this as a replay story: recorded traffic becomes the source of truth, stale mocks create misses,
and tuning turns the same replay back into hits.

This workflow uses local files and the `proxymock` CLI. It does not require Speedscale Cloud access.

## Inputs

- `--mock-in`: candidate mock/recording directory to tune.
- `--replay-in`: HTTP/HTTPS replay request directory to run against the mock.
- Optional `--work-dir`: where logs, observed RRPairs, and `summary.json` should be written.

Use the bundled script first:

```bash
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh \
  --mock-in <candidate-mock-dir> \
  --replay-in <replay-dir>
```

If this skill has been copied outside `mock-lab`, replace `./skills/proxymock-replay-tuning` with the copied skill directory.

For custom ports or protocol maps:

```bash
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh \
  --mock-in <candidate-mock-dir> \
  --replay-in <replay-dir> \
  --proxy-port 4140 \
  --mock-arg '--map=15432=postgres://localhost:5432'
```

## Traffic Replay Story

1. Start with real recorded traffic. `--replay-in` is the request set that represents what the app already saw.
2. Run that traffic against the candidate mock set. The script starts `proxymock mock` in fail-closed mode, sends replay HTTP RRPair requests through that proxy, stops the mock, then writes:
   - `summary.json`
   - `mock.log`
   - `replay.log`
   - `mock-output/`
3. Read `summary.json` first. Treat `HIT` as traffic covered by the mock set. Treat `MISS` and `PASSTHROUGH` as the parts of the replay story the mock set cannot yet explain.
4. Inspect miss files in `mock-output/` and compare their request signatures with the closest matching files in `--mock-in`.
5. **Ask proxymock what to change** (see below) — turn the observed traffic into a prioritized recommendation instead of eyeballing every miss.
6. Tune by adding missing recordings, editing mock RRPair signatures, adjusting request filters, or updating `.metadata/snapshot.json` transforms, then rerun the same replay.

## Use proxymock's recommendations

After a tuning run, let proxymock analyze the observed traffic and tell you what
to fix next, rather than reading every miss by hand:

```bash
# Findings + fix guidance over the traffic proxymock mock just observed:
proxymock report --in <work-dir>/mock-output --format prompt --out <work-dir>/recommend.md

# The precise lever for misses caused by volatile fields (tokens, IDs, dates):
# drift emits a prefilled TransformChain per field that varies between the
# mock set and the observed replay — drop it into the responder signature
# (to wildcard-ignore) or a generator transform (to stabilize the mock).
proxymock drift --source <mock-in> --source <work-dir>/mock-output \
  --sensitivity normal --out <work-dir>/drift.json
```

Read `recommend.md` first, then apply drift recommendations for fields that
*should* match but don't. A field that legitimately varies every call (a fresh
access token) is a wildcard-ignore candidate; a field that drifted because the
mock returned the wrong body is a real miss to fix by correcting the recording.
The **proxymock-compare-results** skill wraps this report/drift step if you want
a one-command before/after view across tuning iterations.

## Interpretation

- High `MISS`: signatures are too strict or the replay requests differ from the mock input.
- Any `PASSTHROUGH` during fail-closed tuning: verify whether extra mock args disabled fail-closed behavior or whether the traffic is outside proxymock's mocked protocols.
- Replay `failed` can be nonzero when fail-closed misses return errors. Use match rate from `summary.json` as the primary tuning metric.
- The script sends recorded HTTP/HTTPS requests through the local proxy so recorded hosts stay intact.
- For non-HTTP protocols, start from the same `proxymock mock` output artifacts and match-count summary pattern, but drive traffic with the real protocol client.

## Output Contract

The script exits nonzero when:

- inputs are invalid,
- `proxymock mock` does not become ready,
- replay request sending fails,
- `--fail-under <percent>` is set and the hit rate is lower than that threshold.

When reporting results, include the hit rate and the absolute path to `summary.json`.

## Proof

To verify the bundled workflow end to end, run:

```bash
./skills/proxymock-replay-tuning/scripts/prove-proxymock-replay-tuning.sh
```

The proof script records the `mock-lab` Go app against the local CNCF API, drives both the basic and auth/order flows, verifies inbound route coverage, creates a stale mock set missing several dependency recordings, then replays the same traffic against the stale and tuned mock sets. It fails unless the tuned set improves the hit rate on real outbound requests.
