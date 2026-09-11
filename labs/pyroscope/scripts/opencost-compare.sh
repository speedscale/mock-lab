#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
results_root=${RESULTS_DIR:-$root_dir/proxymock/results/opencost}
stable_differences=${STABLE_RESPONSE_DIFFERENCES:-}

if [[ ! "$stable_differences" =~ ^[0-9]+$ ]]; then
  echo "set STABLE_RESPONSE_DIFFERENCES to the count reported by proxymock MCP response_diff" >&2
  exit 2
fi

for variant in baseline candidate; do
  for evidence_file in \
    "$results_root/$variant/functional/summary.json" \
    "$results_root/$variant/load/summary.json" \
    "$results_root/$variant/load/window.json" \
    "$results_root/$variant/load/allocation.json"; do
    [[ -s "$evidence_file" ]] || {
      echo "missing evidence: $evidence_file" >&2
      exit 1
    }
  done
done

metric() {
  local variant=$1
  local mode=$2
  local name=$3
  jq -er --arg name "$name" '.endpoints[] | select(.url=="-ALL-") | .metrics[$name]' \
    "$results_root/$variant/$mode/summary.json"
}

allocation_cost() {
  jq -er '.data[0]["catalog-api"].totalCost' "$results_root/$1/load/allocation.json"
}

window() {
  jq -er '.start + " – " + .end' "$results_root/$1/load/window.json"
}

baseline_functional_failed=$(metric baseline functional requests.failed)
candidate_functional_failed=$(metric candidate functional requests.failed)
baseline_load_failed=$(metric baseline load requests.failed)
candidate_load_failed=$(metric candidate load requests.failed)
baseline_succeeded=$(metric baseline load requests.succeeded)
candidate_succeeded=$(metric candidate load requests.succeeded)
baseline_p95=$(metric baseline load latency.p95)
candidate_p95=$(metric candidate load latency.p95)
baseline_throughput=$(metric baseline load requests.per-second)
candidate_throughput=$(metric candidate load requests.per-second)
baseline_cost=$(allocation_cost baseline)
candidate_cost=$(allocation_cost candidate)
baseline_window=$(window baseline)
candidate_window=$(window candidate)
slo=$(jq -er '.latency_p95_slo_ms' "$results_root/candidate/load/window.json")

comparison_file="$results_root/comparison.json"
comparison_markdown="$results_root/comparison.md"

jq -n \
  --arg baseline_window "$baseline_window" \
  --arg candidate_window "$candidate_window" \
  --argjson baseline_functional_failed "$baseline_functional_failed" \
  --argjson candidate_functional_failed "$candidate_functional_failed" \
  --argjson stable_differences "$stable_differences" \
  --argjson baseline_load_failed "$baseline_load_failed" \
  --argjson candidate_load_failed "$candidate_load_failed" \
  --argjson baseline_succeeded "$baseline_succeeded" \
  --argjson candidate_succeeded "$candidate_succeeded" \
  --argjson baseline_p95 "$baseline_p95" \
  --argjson candidate_p95 "$candidate_p95" \
  --argjson baseline_throughput "$baseline_throughput" \
  --argjson candidate_throughput "$candidate_throughput" \
  --argjson baseline_cost "$baseline_cost" \
  --argjson candidate_cost "$candidate_cost" \
  --argjson slo "$slo" \
  '{
    baseline: {
      window: $baseline_window,
      functional_failed: $baseline_functional_failed,
      load_failed: $baseline_load_failed,
      latency_p95_ms: $baseline_p95,
      throughput_rps: $baseline_throughput,
      successful_requests: $baseline_succeeded,
      allocation_cost: $baseline_cost,
      cost_per_successful_request: ($baseline_cost / $baseline_succeeded)
    },
    candidate: {
      window: $candidate_window,
      functional_failed: $candidate_functional_failed,
      load_failed: $candidate_load_failed,
      latency_p95_ms: $candidate_p95,
      throughput_rps: $candidate_throughput,
      successful_requests: $candidate_succeeded,
      allocation_cost: $candidate_cost,
      cost_per_successful_request: ($candidate_cost / $candidate_succeeded)
    },
    stable_response_differences: $stable_differences,
    latency_p95_slo_ms: $slo
  }
  | .cost_per_successful_request_change_pct = (((.candidate.cost_per_successful_request / .baseline.cost_per_successful_request) - 1) * 100)
  | .candidate_valid = (
      .baseline.functional_failed == 0 and
      .candidate.functional_failed == 0 and
      .stable_response_differences == 0 and
      .baseline.load_failed == 0 and
      .candidate.load_failed == 0 and
      .baseline.latency_p95_ms <= .latency_p95_slo_ms and
      .candidate.latency_p95_ms <= .latency_p95_slo_ms and
      .candidate.cost_per_successful_request < .baseline.cost_per_successful_request
    )' >"$comparison_file"

jq -r '
  "| Evidence | Baseline | Candidate |\n" +
  "| --- | ---: | ---: |\n" +
  "| Failed functional requests | \(.baseline.functional_failed) | \(.candidate.functional_failed) |\n" +
  "| Stable response differences | baseline | \(.stable_response_differences) |\n" +
  "| Load p95 latency | \(.baseline.latency_p95_ms) ms | \(.candidate.latency_p95_ms) ms |\n" +
  "| Load throughput | \(.baseline.throughput_rps) req/s | \(.candidate.throughput_rps) req/s |\n" +
  "| Failed load requests | \(.baseline.load_failed) | \(.candidate.load_failed) |\n" +
  "| Exact UTC window | \(.baseline.window) | \(.candidate.window) |\n" +
  "| Allocation cost | \(.baseline.allocation_cost) | \(.candidate.allocation_cost) |\n" +
  "| Successful requests | \(.baseline.successful_requests) | \(.candidate.successful_requests) |\n" +
  "| Cost / successful request | \(.baseline.cost_per_successful_request) | \(.candidate.cost_per_successful_request) |\n\n" +
  "Candidate valid: **\(.candidate_valid)**\n\n" +
  "Cost per successful request change: \(.cost_per_successful_request_change_pct)%"
' "$comparison_file" >"$comparison_markdown"

cat "$comparison_markdown"
