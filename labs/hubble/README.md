# Hubble network-path lab

A disposable Cilium + Hubble Kubernetes lab where a request **times out for a
reason the application cannot see**. The application code, image, and
configuration never change. Only a `CiliumNetworkPolicy` does.

The point of the lab is the separation of conclusions:

| Question | Answered by |
| --- | --- |
| What did the caller receive, and is it stable? | proxymock RRPairs and replay |
| Did the dependency reply at all? | Hubble flows |
| Was the packet dropped, and by what? | Hubble verdict and drop reason |
| Was it DNS? | Hubble L7 DNS flows |

## Topology

`GET /api/stats` on `catalog-api` makes one in-cluster call to
`http://catalog-fixture.netpath-demo.svc.cluster.local:8090/v1/projects` and
aggregates the result. The call is resolved by cluster DNS and dialed
pod-to-pod, so Cilium and Hubble observe the real data path — this lab
deliberately does **not** route the dependency through a host proxy.

`DOWNSTREAM_TIMEOUT=5s` bounds the wait so a blackholed packet becomes a fast,
deterministic 502 instead of a multi-minute TCP retry.

## Prerequisites

Docker, minikube, kubectl, helm, jq, Go, curl, and proxymock. The `hubble` CLI
is installed into this lab's `bin/` by `make hubble-cli`; nothing is written
outside this directory.

## Run

```shell
make up                 # minikube profile hubble-lab + pinned Cilium 1.19.6
make forward            # second terminal: hubble relay :4245, Hubble UI :12000
make capture            # record the healthy boundary (2 RRPairs + window.json)
make flows WINDOW=proxymock/recording/window.json

make break              # apply the incomplete egress policy
make probe              # drive /api/stats and save the failure interval
make flows WINDOW=proxymock/failure/window.json

make fix                # add the one missing egress rule
make functional-replay  # correctness gate: 0 failed, 100% stable-response match
make load-replay
make verify
make down
```

## Reference run

`evidence/reference.json` holds the measured numbers. Summary:

- **Healthy:** 65 flows, 0 dropped, `catalog-api → catalog-fixture:8090`
  FORWARDED.
- **Broken:** three 502s at ~5.01 s with `context deadline exceeded`, and zero
  application log lines explaining it. Hubble shows 48 DROPPED flows,
  `POLICY_DENIED`, `catalog-api → catalog-fixture:8090` — while DNS for
  `catalog-fixture.netpath-demo.svc.cluster.local` is FORWARDED and successful.
  The 48 drops are SYN retransmissions for 3 requests, not 48 requests.
- **Fixed:** functional replay 3/3 with 100% stable-response match, load replay
  50/50 with 0 failed, and 0 dropped flows.

## Why there is no MCP server here

The sibling labs query Grafana through its MCP server. Hubble has no MCP server,
so `make flows` writes `flows.json` (newline-delimited `jsonpb`) next to the
saved `window.json`. The agent reads a file instead of calling a tool; the
evidence discipline is the same.
