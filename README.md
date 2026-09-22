# agent-tools-sync

Idempotent installer/updater for a local agent-efficiency toolkit — [headroom](https://github.com/headroomlabs-ai/headroom), [rtk](https://github.com/rtk-ai/rtk), [caveman](https://github.com/JuliusBrussee/caveman), and [ponytail](https://github.com/DietrichGebert/ponytail) — wired into both [Claude Code](https://claude.com/claude-code) and [Codex CLI](https://github.com/openai/codex).

Safe to re-run any time: every step checks current state first and only acts when something is actually missing or out of date.

## What it sets up

- **caveman** — the only proxy either agent's base URL points at, on `:8787`. Owns both Claude Code's and Codex's native integration (hooks, skills, MCP recovery) and chains its own compression into headroom as the next hop.
- **headroom** — a downstream compression hop behind caveman on `:8788` (not agent-facing), plus an on-demand MCP server in Claude Code.
- **rtk** — shell-output compression hook in both Claude Code and Codex.
- **ponytail** — lazy-coding plugin in both Claude Code and Codex.

Both tools are universal (each can wrap Claude Code, Codex, and a dozen other agents on its own) and are designed to stack rather than split one-per-agent — caveman's own README benchmarks headroom head-to-head as a direct alternative, and headroom's README documents running "Caveman, or any other MCP server" upstream of it. So the request path is `agent → caveman (:8787) → headroom (:8788) → real provider`, via a `compat` mount in `~/.caveman/caveman.yaml` (caveman has no override for its native wrap routes' upstream, only for named `compat` mounts) with `CAVE_SSRF_ALLOWLIST` opened for the loopback hop. `ats` patches `ANTHROPIC_BASE_URL` in `~/.claude/settings.json` and `model_providers.caveman.base_url` in `~/.codex/config.toml` to point at that mount instead of caveman's native `/w/claude` / `/chatgpt` routes. One side effect: `caveman status` reports both integrations as "degraded" afterward (it fingerprints the files it writes, and the patch changes them) — `ats` recognizes that as expected and won't retry or warn about it.

## Install

```sh
git clone https://github.com/DeveloperBeau/agent-tools-sync.git
ln -s "$(pwd)/agent-tools-sync/agent-tools-sync.sh" ~/.local/bin/agent-tools-sync
```

Add an alias if you want the short form:

```sh
echo 'alias ats="agent-tools-sync"' >> ~/.zshrc
```

The whole directory is portable — copy it to another machine and symlink the entry point; `lib/*.sh` is resolved relative to the script's real location, not `$PWD`.

## Usage

```sh
ats            # install/update everything and wire up integrations
ats kill       # stop both background proxies (caveman :8787, headroom :8788)
ats start      # bring both proxies back up, without the full sync
```

`ats kill` is a hard stop — nothing auto-restarts headroom's proxy afterward (unlike caveman, which self-starts on the next agent session). Since caveman chains every request through headroom, both agents get connection-refused on the last hop until you run `ats start` or `ats`.

## Testing

```sh
bash test/run_tests.sh   # unit tests for every pure decision function
bash test/mutate.sh      # mutation testing against the test suite
```

Pure decision functions (parsing `caveman status`, `headroom install status`, config files, etc.) are isolated from their side-effecting orchestration functions specifically so they can be unit-tested without a live install. See `test/harness.sh` for the (dependency-free, no bats/shunit2) assertion helpers.

## License

MIT — see [LICENSE](LICENSE).
