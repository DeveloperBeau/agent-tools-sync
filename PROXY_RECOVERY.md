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

Before restart, it saves route outcomes, process memory and uptime, six hours of
minute memory samples, Headroom runtime health and task state, payload-free stream
timings, and selected Caveman transport errors. Reports live in
`~/.headroom/incidents/`. Watchdog state lives in `~/.headroom/watchdog-state.json`.
Files are private to the user. Prompts, responses, and authentication headers are
not captured by this instrumentation.

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
`feature/route-health-stream-recovery`, resolve conflicts while preserving route
health and upstream timing instrumentation, run focused tests, and push the fork.
Update `HEADROOM_FORK_SOURCE` to the resulting full commit before deployment.
Do not use `headroom update -y` or upgrade directly from PyPI while using the fork.

## Standalone installation

Install the Headroom revision pinned by `HEADROOM_FORK_SOURCE` in `lib/headroom.sh`,
then restart Headroom directly:

```sh
uv tool install --force --python 3.13 'headroom-ai[all] @ git+https://github.com/DeveloperBeau/headroom.git@9b38d5ec8ea8426cb0ae4e12196b036887af50ef'
headroom install restart --profile default
python3 /absolute/path/to/agent-tools-sync/lib/proxy_watchdog.py install
```

The watchdog installs a user LaunchAgent named
`com.agent-tools-sync.proxy-watchdog`. Installation and operation do not invoke
ATS. Keep the source checkout at its installed path. Restart can interrupt active
requests. Existing deployment configuration and agent routing stay in place.

## Inspect the next failure

```sh
curl -sS http://127.0.0.1:8788/health/routes
cat ~/.headroom/watchdog-state.json
ls -lt ~/.headroom/incidents/
tail -n 20 ~/.headroom/watchdog.stdout.log ~/.headroom/watchdog.stderr.log
launchctl print gui/$(id -u)/com.agent-tools-sync.proxy-watchdog
```

Compare upstream chunk timing with downstream outcomes and Caveman errors.
Growing RSS across samples suggests memory growth; silent streams with a live
event loop suggest transport or upstream trouble. Preserve reports before making
further changes. A completed request on one route does not establish health of
the other route.

## Rollback

Disable the watchdog before replacing the fork:

```sh
launchctl bootout gui/$(id -u)/com.agent-tools-sync.proxy-watchdog
rm ~/Library/LaunchAgents/com.agent-tools-sync.proxy-watchdog.plist
uv tool install --force --python 3.13 'headroom-ai[all]==0.39.1'
headroom install restart --profile default
```

This restores the previously installed Headroom release. Keep incident reports.
The ATS feature branch pins the fork, so a future ATS invocation on that branch
will install the diagnostic build again.
