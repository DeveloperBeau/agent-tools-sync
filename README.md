# agent-tools-sync

Idempotent installer/updater for a local agent-efficiency toolkit — [headroom](https://github.com/headroom-ai/headroom), [rtk](https://github.com/rtk-ai/rtk), [caveman](https://caveman.ai), and [ponytail](https://github.com/DietrichGebert/ponytail) — wired into both [Claude Code](https://claude.com/claude-code) and [Codex CLI](https://github.com/openai/codex).

Safe to re-run any time: every step checks current state first and only acts when something is actually missing or out of date.

## What it sets up

- **caveman** — owns Claude Code's compression proxy on `:8787` (`ANTHROPIC_BASE_URL`), plus native Codex integration. Self-starts on the next `claude`/`codex` session.
- **headroom** — Codex routing (`OPENAI_BASE_URL`) via a persistent proxy on `:8788`, plus an on-demand MCP server in Claude Code.
- **rtk** — shell-output compression hook in both Claude Code and Codex.
- **ponytail** — lazy-coding plugin in both Claude Code and Codex.

Two separate proxies run side by side deliberately — one per agent's Anthropic/OpenAI-shaped traffic — so they never fight over the same port or env var.

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

`ats kill` is a hard stop — nothing auto-restarts headroom's proxy afterward (unlike caveman, which self-starts on the next agent session), so anything routed through `OPENAI_BASE_URL` will get connection-refused until you run `ats start` or `ats`.

## Testing

```sh
bash test/run_tests.sh   # unit tests for every pure decision function
bash test/mutate.sh      # mutation testing against the test suite
```

Pure decision functions (parsing `caveman status`, `headroom install status`, config files, etc.) are isolated from their side-effecting orchestration functions specifically so they can be unit-tested without a live install. See `test/harness.sh` for the (dependency-free, no bats/shunit2) assertion helpers.

## License

MIT — see [LICENSE](LICENSE).
