# Chaos + proxymock fallback task

Work in the `chaos` directory of your `mock-lab` clone. Do not edit the
application until step 6.

1. Run `make coverage`. Report the package statement coverage and `fetchStock`
   function coverage. Read the tests, list each dependency outcome they assert,
   and say which realistic dependency failures they leave unchecked.

2. Run `make capture`. Confirm the recording holds 6 inbound stock lookups and
   6 outbound inventory calls, and that **every** recorded inventory response
   is a `200`. Report anything in the recording that looks like a failure.

3. Start `make mock-chaos` in one terminal and run `make baseline` in another.
   Record the storefront's answer for all six SKUs verbatim.

4. Run `make chaos-evidence`. Report the status code inventory actually
   returned and the value of the `x-speedscale-chaos` response header. That
   header names the effect and the rule that produced it; its absence is how
   an untouched response is identified.

5. Reconcile steps 3 and 4. State, in one sentence, what the storefront told
   its callers and what was actually true. Identify the exact line in
   `cmd/app/main.go` responsible, and say why no status-code assertion or
   response diff would have caught it.

6. Make the smallest fix that lets the storefront tell the truth. Check the
   dependency status before accepting its body. Add a regression test for a
   503 with a valid recorded body. Do not change the response schema, fallback
   cache, or recording.

7. Start `make mock-slow` and run `make slow-evidence`. The service requirement
   is a response within 750 ms when inventory takes 2 seconds. Set a bounded
   client timeout and add a test for the slow dependency path.

8. Prove the fallback behavior. Start `make mock-flaky` and run `make baseline` several times.
   The fix is correct when all three of these appear and none contradict the
   dependency's real behavior:
   - a healthy answer with `degraded:false` and `source:"inventory"`
   - a degraded answer with `degraded:true` and `source:"cache"`
   - an honest error when inventory fails before anything is cached

   A response claiming `degraded:false` on a call that inventory failed is a
   failing result, whatever the numbers say.

9. Start a healthy `make mock` and run the p95 gate from the README against the
   recorded inbound traffic. Report p95 and failed requests. Treat local RPS as
   a harness-bound result, not the app's capacity.

10. Re-run `make mock` with no chaos and confirm the six baseline answers are
   byte-identical to the answers you recorded in step 3. A fix that changes the healthy path
   is out of scope.

## Constraints

- `percent=50,seed=lab` is deterministic per signature and occurrence: the Nth
  lookup of a SKU gets the same verdict every run. Do not treat a differing
  count of requests between runs as nondeterminism in the rule.
- The recorded body survives an injected status change. Correct-looking data
  in the body is not evidence that the call succeeded.
