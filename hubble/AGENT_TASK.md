# Hubble + proxymock investigation task

Work in the `hubble` directory of your `mock-lab` clone. Do not edit the
application. The application image is identical in the healthy and failing
states, so any conclusion that blames application code is wrong by
construction — your job is to prove that from evidence, not to assume it.

1. Read `proxymock/failure/window.json`. Report `capture_start` and
   `capture_end` as the exact failure boundaries. Use `query_start` and
   `query_end` unchanged wherever an interval is required. Do not edit, round,
   widen, or ask the user to confirm a timestamp.
2. Report the application-side evidence first, from
   `proxymock/failure/observations.txt` and `proxymock/failure/catalog-api.log`:
   HTTP status, wall-clock duration, error text, and how many log lines explain
   the cause. State explicitly what this evidence can and cannot distinguish.
3. Call proxymock MCP `search_local_traffic` with
   `{"in-directory":["proxymock/recording"],"direction":"in","method":"GET","query":"/api/stats","limit":20,"offset":0}`
   and again with `direction":"out"` and `"query":"/v1/projects"`. Report the
   recorded stable response. This is the contract any fix must preserve.
4. Read `proxymock/failure/flows.json` (newline-delimited `jsonpb` from
   `make flows`). Group `.flow` records by `verdict`. For every `DROPPED` flow
   report source workload, destination workload, destination port, and
   `drop_reason_desc`.
5. Separately, report the L7 DNS flows for the same interval: the queried name
   and its verdict. Use this to state whether name resolution succeeded.
6. Now state three separate conclusions, each with the evidence that supports
   it: an application conclusion, a dependency conclusion, and a network
   conclusion. Say which single conclusion the drop reason supports and which
   ones it eliminates.
7. Propose the smallest change that removes the failure without touching
   application behavior. Apply it with `make fix`.
8. Run `make functional-replay`, then `make load-replay`, then `make verify`.
   Report `requests.failed` and `requests.result-match-pct`. The fix is only
   accepted when the failed count is zero and the stable-response match is 100
   percent.
9. Re-export flows over the replay window and confirm the dropped count is zero.

Beware of one counting trap: a single blocked TCP connection produces many
dropped flow records because the kernel retransmits the SYN. Report the number
of affected requests and the number of dropped packets as different numbers.
