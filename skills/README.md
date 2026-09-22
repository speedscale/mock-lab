# The proxymock agent skills moved

The skills that lived here (`quality-loop`, `proxymock-regression-test`,
`proxymock-verify-fix`, `proxymock-contract-test`, `proxymock-chaos-mock`,
`proxymock-load-test`, `proxymock-perf-container`, `proxymock-compare-results`,
`proxymock-summarize-recording`, `proxymock-replay-tuning`) now live with the
rest of Speedscale's agent skills at
**https://github.com/speedscale/skills** (`skills/<name>/`), alongside
`install-speedscale` and `improve-mock-match-rate`.

Get them into your agent:

```shell
# Claude Code
/plugin marketplace add speedscale/skills
/plugin install speedscale@speedscale-skills

# any agent, via the skills CLI
npx skills add speedscale/skills
```

They still run against this repo's committed fixture, `lab/proxymock/recording`.
The proof scripts find it through `MOCK_LAB_DIR`:

```shell
MOCK_LAB_DIR="$PWD" /path/to/skills/skills/quality-loop/scripts/prove-quality-loop.sh
```
