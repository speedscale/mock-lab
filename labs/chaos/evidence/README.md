# Evidence

`broken-storefront.jsonl` is what the checked-in storefront answers for all
six SKUs while `make mock-chaos` has inventory failing **every** call.

Every line claims `degraded:false` and `source:"inventory"`. Inventory
returned `503` for every one of them, carrying
`x-speedscale-chaos: effect=status code;status=503;rule=chaos-1`.

The numbers in the bodies are real — an injected status change does not erase
the recorded body — which is exactly why this is hard to catch by inspection.
The defect is the metadata, not the data.
