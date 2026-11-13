# Proxy chain

```text
Claude Code / Codex → Caveman 127.0.0.1:8787 → provider
```

ATS points Claude's `env.ANTHROPIC_BASE_URL` at `http://127.0.0.1:8787/w/claude`.
It points Codex's `model_providers.caveman.base_url` at
`http://127.0.0.1:8787/chatgpt`. These are Caveman's native routes.
Caveman runs in its default compress mode. No `caveman.yaml` is needed.
Claude Remote Control works only in the `--no-wrap` mode, which removes the Claude route.

## Start the proxy without a sync

```sh
bash proxy-chain.sh
# Optional: export routing for agents/SDKs launched from this shell.
eval "$(bash proxy-chain.sh env)"
```

Startup starts Caveman only if port 8787 is unused, and waits for readiness.
A healthy process is preserved. An unhealthy occupied port is reported, not
killed. No tool updates, memory-worker actions, or provider calls occur.
Environment exports take effect only in the calling shell. They do not change
running agents. In `direct` mode, nothing starts.

## Provider authentication

Keep credentials in the agents' own login or key storage. The proxy forwards
provider authentication. No keys are copied into ATS. The listener must stay
loopback-only. Do not print authorization headers or enable shell tracing
around authenticated requests.

## Verify compression

These commands make no paid inference requests and do not reset counters:

```sh
caveman status
caveman stats --json
caveman doctor
```

A `measured` request with `after_tokens < before_tokens` shows input reduction.
Zero or unavailable measurements do not show compression. Compare `saved_tokens`
with `expanded_requests`: a negative total means the proxy made requests larger.
Do not add savings percentages from different layers.
