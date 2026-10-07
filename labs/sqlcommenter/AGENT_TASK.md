# sqlcommenter + proxymock: attribute every query

Work in the `sqlcommenter` directory of your `mock-lab` clone, with the proxymock MCP server from [mcp.example.json](mcp.example.json) (set `--work-dir` to this directory). Do not edit any file. The answers all come from the committed recording in `proxymock/recording`.

1. Call proxymock MCP `sql_report` on `proxymock/recording`. Report the number of inbound requests, statements attributed to a request, statements linked by the trace id in their SQL comment, ambiguous statements, and statements outside any request.
2. Call `search_local_traffic` on `proxymock/recording` for the inbound `GET /reports/sales` requests. Report each one's trace id (from its `traceparent` header) and whether their time windows overlap.
3. Pick one report's trace id. Call `search_local_traffic` for the Postgres traffic and find the statements whose SQL comment carries that trace id. Report how many there are and what they run.
4. Explain why the overlapping reports produce no ambiguous statements.
5. Account for every statement that is not linked by trace id. For each, name the request it belongs to by timing and the reason it carries no usable trace id. Three reasons cover all of them; name each one.
6. Compare your counts with [evidence/reference.json](evidence/reference.json) and report any difference.

Stop after step 6. Do not record new traffic or start the app.
