# Existing proxy chain

```text
Claude Code / Codex → Caveman 127.0.0.1:8787 → Headroom 127.0.0.1:8788 → provider
```

The existing Caveman configuration already contains:

```yaml
mode: compress
compat:
  headroom:
    base_url: http://127.0.0.1:8788
    wire_dialect: anthropic
```

Claude's `env.ANTHROPIC_BASE_URL` and Codex's selected
`model_providers.caveman.base_url` already point at
`http://127.0.0.1:8787/compat/headroom`. Codex uses the Responses endpoint.
Do not switch back to Caveman's native `/w/claude` or `/chatgpt` routes;
those bypass this mount. Ports are arbitrary, but must remain consistent.

## Start without replacing the leak-debugging fork

From this checkout:

```sh
bash proxy-chain.sh
# Optional: export routing for agents/SDKs launched from this shell.
eval "$(bash proxy-chain.sh env)"
```

Startup validates the existing mount, checks Headroom readiness, starts the
existing `default` profile only if port 8788 is unused, and waits for readiness
before starting Caveman. Failures stop startup. Healthy processes are preserved;
an unhealthy occupied port is left alone and reported, not killed or replaced.
No tool updates, deployment reapplication, fork changes, memory-worker actions,
or provider calls occur. Environment exports take effect in the calling shell
only when evaluated; they do not change already-running agents.

`ats start` uses the same proxy launcher, then starts the memory worker as before.
Use the standalone command while investigating the Headroom leak. Full `ats`
still performs its normal installation/update workflow.

## Provider authentication

Keep credentials in the agents' existing login/key storage. The local proxies
forward provider authentication; no keys are copied into this script or YAML.
Headroom routes Anthropic Messages to Anthropic, OpenAI API-key Responses to
OpenAI, and ChatGPT-authenticated Codex Responses to ChatGPT's backend. Its
`backend=anthropic` setting does not force Responses traffic to Anthropic.
Both listeners should remain loopback-only. Do not print authorization headers
or enable shell tracing around authenticated requests.

## Verify routing and compression separately

Readiness is not proof of compression. These commands do not make paid inference
requests or reset counters:

```sh
curl --noproxy '*' -fsS http://127.0.0.1:8788/health |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print({k:d[k] for k in ("service","ready","routes")})'
caveman stats --json
```

For per-request Caveman evidence, query metadata only (no prompts or keys):

```sh
python3 - <<'PY'
import pathlib, sqlite3
db = pathlib.Path.home() / '.caveman/caveman.db'
with sqlite3.connect(f'file:{db}?mode=ro', uri=True) as c:
    for row in c.execute('''
        SELECT ts, endpoint, status_code, request_measurement_status,
               request_tokens_before, request_tokens_after
        FROM requests WHERE endpoint LIKE '/compat/headroom/%'
        ORDER BY id DESC LIMIT 20
    '''):
        print(row)
PY
```

A successful chained request has HTTP 200 on `/compat/headroom/...` plus a
completed corresponding Headroom route. A `measured` Caveman row with
`request_tokens_after < request_tokens_before` demonstrates input reduction.
Zero or unavailable measurements do not demonstrate compression.

Take Headroom snapshots before and after a normal agent turn containing a large,
repetitive tool result:

```sh
curl --noproxy '*' -fsS http://127.0.0.1:8788/stats |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print("requests",d["requests"]["total"],"input tokens saved",d["tokens"]["proxy_compression_saved"])'
```

An increase in Headroom's saved counter proves compression during that interval.
Other active agent sessions contribute to shared counters; use a quiet interval
for attribution. Preserve leak-debugging state: do not reset statistics or
restart Headroom to create a clean baseline.

Caveman's compression can skip turns when recovery support is absent or the
result would not be smaller. Its status warning is not proof that every request
bypasses compression: inspect actual measured rows. Neither routing order nor
input counters prove provider-response trimming. Caveman's concise-output
instructions and command-output shrinking are separate from proxy input
compression; this change does not truncate model responses. Do not add both
layers' savings percentages or infer billing savings from these estimates.
