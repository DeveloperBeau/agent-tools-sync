# Proxy incident capture and recovery

Codex image generation uses bare `/images/generations` and `/images/edits` paths.
The pinned Headroom fork registers these alongside `/v1/images/...`, preserving
subscription authentication and forwarding to the Codex image backend. Without
these aliases, the generic fallback sends requests to the wrong ChatGPT path and
can return a redirect that subsequently fails at Caveman with `cave_route_not_found`.

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
Cooldown delays another restart, not failure detection. A qualifying failure
during cooldown captures an incident and sends a notification once per affected
route per cooldown window. This also applies after three failed health probes.
Persistent `cooldown_alerts` state prevents repeated ten-second notifications,
including after the watchdog itself restarts. State and `event=recovery_suppressed`
logs identify the failure reason and remaining cooldown; the restart timer stays
unchanged. Continued failures can trigger recovery when cooldown expires.
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
uv tool install --force --python 3.13 'headroom-ai[all] @ git+https://github.com/DeveloperBeau/headroom.git@313236de0c0c4f7ea93207d88a34bc761d2519d6'
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
Connection records also retain inbound/outbound HTTP/2 frame counts, the last
32 frame headers and numeric control fields, pending frame payload lengths,
local/remote SETTINGS, DATA payload byte counts, and WINDOW_UPDATE increments.
RST_STREAM and GOAWAY emit immediate `kind=h2_control` events. GOAWAY debug data
is represented only by its length; request/response bodies and headers are skipped.
WINDOW_UPDATE increments are activity counters, not exact flow-control windows.

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

Socket instrumentation measures decrypted transport read/write progress and
bounded frame metadata, without packet captures or content payloads. It cannot
establish a remote peer's internal reason for stopping or resetting a stream.
No transport settings, retry policy, or restart criteria change
with these diagnostics. Preserve reports before making further changes. A
completed request on one route does not establish health of the other route.

## Automatic Caveman size bypass

On the configured `/compat/headroom/` route, Caveman streams requests above
32 MiB unchanged, without inspecting or transforming the body. This includes
media bytes and native session markers. A declared oversized body streams
immediately; an unknown-length upload retains at most the transform budget plus
one byte, then forwards that prefix and the remaining upload together. Caveman
adds `x-headroom-bypass: true` after header sanitation so Headroom also skips body
processing. The next smaller request uses compression normally. No command or
provider switch is needed.

`CAVE_MAX_TRANSFORM_BYTES` controls the processing budget (default 32 MiB).
The Headroom route has no default 100 MiB upload rejection. An explicit positive
`CAVE_MAX_REQUEST_BYTES` still sets a hard limit: known oversized uploads receive
413 before forwarding; unknown-length uploads stop when their reader reaches
the limit. Streamed requests are never replayed, including after upload failure
or an upstream rejection. Authentication, configured routing, header mapping,
SSRF checks, cancellation, and upload deadlines remain enforced. Other Caveman
provider routes retain their existing buffered behavior and default 100 MiB cap.

Headroom independently streams supported Responses and Messages requests above
its 100 MiB processing budget unchanged, including requests that arrive without
Caveman. Requests that need body-dependent policy enforcement retain their
policy limits; raw forwarding does not bypass those checks. The processing
budgets bound retained input, not process RSS: copies, concurrent requests, and
other proxy work can use additional memory.

Responses disclose size bypass with `x-cave-bypass: request_size`. Private
`~/.caveman/proxy.log` records `event=request_bypass`, request ID, declared size,
and limits without payloads or credentials. Streamed requests also record
`event=request_bypass_complete` with bytes consumed by the upstream transport
and whether the complete-body hash is known. Partial uploads never claim a
complete hash or invented model/token savings. Hard rejections record
`event=request_rejected` and bytes seen, which may be less than the full upload.

ATS builds the pinned upstream revision plus `patches/caveman-request-size.patch`
using `lib/install_caveman_proxy.py`. Its private wrapper and executable live in
`~/.caveman/ats-proxy/`; the wrapper exports `CAVEMAN_PROXY_BIN` so native hooks
and their child CLI processes use the same build. Vendor-managed binaries remain
separate. ATS persists the override for shell launches and migrates vendor-owned
native hook commands. Go is required to build or update the patch; a failed build
keeps the previously installed executable. `build.json` records the source,
patch, and binary hashes. To update the pin, rebase the tracked patch and rerun
its gateway and installer checks before replacing the running proxy.

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
