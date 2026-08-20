# Chaos + proxymock fallback task

Work in the `chaos` directory of your `mock-lab` clone. Do not edit the
application until step 5.

1. Run `make capture`. Confirm the recording holds 6 inbound stock lookups and
   6 outbound inventory calls, and that **every** recorded inventory response
   is a `200`. Report anything in the recording that looks like a failure.

2. Start `make mock-chaos` in one terminal and run `make baseline` in another.
   Record the storefront's answer for all six SKUs verbatim.

3. Run `make chaos-evidence`. Report the status code inventory actually
   returned and the value of the `x-speedscale-chaos` response header. That
   header names the effect and the rule that produced it; its absence is how
   an untouched response is identified.

4. Reconcile steps 2 and 3. State, in one sentence, what the storefront told
   its callers and what was actually true. Identify the exact line in
   `cmd/app/main.go` responsible, and say why no status-code assertion or
   response diff would have caught it.

5. Make the smallest fix that lets the storefront tell the truth. Do not
   change the response schema, the fallback cache, or the recording.

6. Prove it. Start `make mock-flaky` and run `make baseline` several times.
   The fix is correct when all three of these appear and none contradict the
   dependency's real behavior:
   - a healthy answer with `degraded:false` and `source:"inventory"`
   - a degraded answer with `degraded:true` and `source:"cache"`
   - an honest error when inventory fails before anything is cached

   A response claiming `degraded:false` on a call that inventory failed is a
   failing result, whatever the numbers say.

7. Re-run `make mock` with no chaos and confirm the six baseline answers are
   byte-identical to step 2 of the README. A fix that changes the healthy path
   is out of scope.

## Constraints

- `percent=50,seed=lab` is deterministic per signature and occurrence: the Nth
  lookup of a SKU gets the same verdict every run. Do not treat a differing
  count of requests between runs as nondeterminism in the rule.
- The recorded body survives an injected status change. Correct-looking data
  in the body is not evidence that the call succeeded.
