# Proxy incident capture and recovery

The diagnostic Headroom fork observes real Claude `/v1/messages` traffic and
ChatGPT Codex Responses traffic separately. No inference probes are sent.
Successful HTTP connection alone is insufficient: SSE must reach its terminal
event. A route becomes unhealthy after three consecutive failures within five
minutes. Idle routes become `unknown`, with their last observation retained.
Active request count, age, and silence duration remain visible while streams run.

The standalone watchdog checks every ten seconds. Three route failures involving
broken streams or HTTP 5xx responses trigger one Headroom restart. Three failed
health endpoint probes also trigger recovery. Restarts have a persistent thirty
minute cooldown; authentication errors and rate limits do not trigger restarts.
Slow active requests alone do not trigger restarts.
Recovery requires the managed Headroom LaunchAgent to remain loaded. A deliberate
Headroom stop or `ats kill` stays stopped; the watchdog does not start it again.

Before restart, it captures live stream diagnostics first, followed by route
outcomes, process CPU/state/memory/uptime, six hours of minute memory samples,
Headroom runtime health and task state, payload-free stream timings, selected
Caveman transport errors, TCP socket endpoints/states, host TCP counters, and the
default network route. Reports live in
`~/.headroom/incidents/`. Watchdog state lives in `~/.headroom/watchdog-state.json`.
Files are private to the user. Prompts, responses, and authentication headers are
not captured by this instrumentation.

The watchdog polls `/debug/streams` every ten seconds. It retains the last
successful full snapshot and two minutes of bounded active-stream/connection
samples. If the proxy stops responding, those earlier snapshots survive in the
incident. Snapshot errors do not change the restart policy. OS probes have
three-second deadlines and bounded output; unavailable probes are reported as
errors rather than preventing recovery. TCP counters are host-wide and may
include unrelated traffic.

Restart success means Headroom restarted and answered its readiness endpoint.
Provider recovery remains unverified until the next real request completes.
This is incident capture and bounded recovery, not a proven root-cause fix.
Caveman or provider failures may persist after restarting Headroom.

## Keep upstream updates

ATS setup retains a bounded `headroom update --check` call. It reports upstream
PyPI releases but never upgrades over the pinned fork. The same check can run
directly without invoking ATS:

```sh
headroom update --check
```

When a release is available, merge its upstream tag into
`feature/stream-diagnostics`, resolve conflicts while preserving route
health and upstream timing instrumentation, run focused tests, and push the fork.
Update `HEADROOM_FORK_SOURCE` to the resulting full commit before deployment.
Do not use `headroom update -y` or upgrade directly from PyPI while using the fork.

## Standalone installation

Install the Headroom revision pinned by `HEADROOM_FORK_SOURCE` in `lib/headroom.sh`,
then restart Headroom directly:

```sh
uv tool install --force --python 3.13 'headroom-ai[all] @ git+https://github.com/DeveloperBeau/headroom.git@0e44f64344c40ef5c22c342312a7d31d2daa7233'
headroom install restart --profile default
python3 /absolute/path/to/agent-tools-sync/lib/proxy_watchdog.py install
```

The watchdog installs a user LaunchAgent named
`au.com.beauayres.agent-tools-sync.proxy-watchdog`. Installation and operation do not invoke
ATS. Keep the source checkout at its installed path. Restart can interrupt active
requests. Existing deployment configuration and agent routing stay in place.

## Inspect the next failure

If the client fails while observed Headroom routes look healthy, capture a report
manually. This also captures failures earlier in the chain without restarting:

```sh
python3 /absolute/path/to/agent-tools-sync/lib/proxy_watchdog.py capture
```

```sh
curl -sS http://127.0.0.1:8788/health/routes
curl -sS http://127.0.0.1:8788/debug/streams
cat ~/.headroom/watchdog-state.json
ls -lt ~/.headroom/incidents/
tail -n 20 ~/.headroom/watchdog.stdout.log ~/.headroom/watchdog.stderr.log
launchctl print gui/$(id -u)/au.com.beauayres.agent-tools-sync.proxy-watchdog
```

`/debug/streams` is loopback-only and contains bounded active/recent request and
connection records, event-loop lag, effective HTTP timeouts, and transport library
versions. Correlate Headroom request IDs, connection IDs, HTTP/2 stream IDs, and
allowlisted upstream request IDs. IDs are scoped to a process; compare the PID
before joining records across a restart. Diagnostic logs use
`event=stream_diagnostic` and `event=proxy_loop_lag`.

| Evidence | What it helps distinguish |
| --- | --- |
| Long upstream iterator wait, socket read also waiting, responsive loop | No bytes reaching the socket; remote/network trouble remains possible. |
| Long iterator wait while the shared socket receives bytes | HTTP/2 stream scheduling, flow control, or per-stream upstream delay; other streams may be progressing. |
| Long downstream send or suspended generator yield | Client/proxy backpressure, rather than assuming upstream silence. |
| TCP/TLS/header phase delay | Connection establishment, handshake, pool/stream admission, or upstream response-header delay. |
| Same connection ID on multiple resets | Correlated failure of streams sharing a connection. |
| HTTP/2 reset/GOAWAY fields and exception chain | Protocol failure type without logging exception text or payloads. |
| Event-loop lag across the same interval | Local scheduling/blocking work that delays multiple requests. |
| Growing RSS, high CPU, compression queues | Local resource pressure; correlate with timings before assigning cause. |
| TCP retransmit/reset counters and socket states | Supporting network evidence; host-wide counters cannot identify one request. |

Socket instrumentation measures decrypted transport read/write progress, not
packet captures or HTTP/2 frame contents. It cannot establish why a remote peer
stopped sending. No transport settings, retry policy, or restart criteria change
with these diagnostics. Preserve reports before making further changes. A
completed request on one route does not establish health of the other route.

## Caveman rejects an oversized request

`Request body exceeds the proxy limit.` from `:8787` is Caveman's inbound
32 MiB limit. It runs before compression, pass-through mode, and request logging;
there is no automatic bypass for this rejection. To run Codex directly through
the Headroom diagnostic fork for one session:

```sh
codex -c 'model_provider="headroom"' \
  -c 'model_providers.headroom.base_url="http://127.0.0.1:8788/v1"'
```

This uses the compatibility provider registered by ATS and leaves global routing
unchanged. Headroom has its own 100 MiB wire/decompressed-body ceiling. Caveman's
ceiling can instead be raised with `CAVE_MAX_REQUEST_BYTES` in its launcher
environment, but changing a shell variable cannot alter an already-running proxy.

## Rollback

Disable the watchdog before replacing the fork:

```sh
launchctl bootout gui/$(id -u)/au.com.beauayres.agent-tools-sync.proxy-watchdog
rm ~/Library/LaunchAgents/au.com.beauayres.agent-tools-sync.proxy-watchdog.plist
uv tool install --force --python 3.13 'headroom-ai[all]==0.39.1'
headroom install restart --profile default
```

This restores the previously installed Headroom release. Keep incident reports.
The ATS feature branch pins the fork, so a future ATS invocation on that branch
will install the diagnostic build again.
