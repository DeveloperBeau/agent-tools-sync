# agent-tools-sync

Idempotent installer/updater for a local agent-efficiency toolkit — [headroom](https://github.com/headroomlabs-ai/headroom), [rtk](https://github.com/rtk-ai/rtk), [caveman](https://github.com/JuliusBrussee/caveman), and [ponytail](https://github.com/DietrichGebert/ponytail) — wired into both [Claude Code](https://claude.com/claude-code) and [Codex CLI](https://github.com/openai/codex).

Safe to re-run any time: every step checks current state first and only acts when something is actually missing or out of date.

## What it sets up

- **caveman** — the only proxy either agent's base URL points at, on `:8787`. Owns both Claude Code's and Codex's native integration (hooks, skills, MCP recovery) and chains its own compression into headroom as the next hop.
- **headroom** — a downstream compression hop behind caveman on `:8788` (not agent-facing), plus an on-demand MCP server in Claude Code.
- **rtk** — shell-output compression hook in both Claude Code and Codex.
- **ponytail** — lazy-coding plugin in both Claude Code and Codex.
- **Ship** — optional private plugin in both agents. ATS runs `ship-update` when installed, or attempts installation through authenticated GitHub CLI. Missing access leaves rest of sync working.
- **SkillOpt** — [Microsoft's skill optimizer](https://github.com/microsoft/SkillOpt), with the SkillOpt-Sleep plugin for Claude Code and skill for Codex CLI/Desktop. Runs on demand and stages learned changes for review.
- **Obsidian plans** — one shared Markdown vault for both agents, with automatic plan capture, project indexes, backlinks, and a properties table.

Both tools are universal (each can wrap Claude Code, Codex, and a dozen other agents on its own) and are designed to stack rather than split one-per-agent — caveman's own README benchmarks headroom head-to-head as a direct alternative, and headroom's README documents running "Caveman, or any other MCP server" upstream of it. So the request path is `agent → caveman (:8787) → headroom (:8788) → real provider`, via a `compat` mount in `~/.caveman/caveman.yaml` (caveman has no override for its native wrap routes' upstream, only for named `compat` mounts) with `CAVE_SSRF_ALLOWLIST` opened for the loopback hop. `ats` patches `ANTHROPIC_BASE_URL` in `~/.claude/settings.json` and `model_providers.caveman.base_url` in `~/.codex/config.toml` to point at that mount instead of caveman's native `/w/claude` / `/chatgpt` routes. One side effect: `caveman status` reports both integrations as "degraded" afterward (it fingerprints the files it writes, and the patch changes them) — `ats` recognizes that as expected and won't retry or warn about it.

## Install

On macOS, download and run the bootstrap script in a terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/DeveloperBeau/agent-tools-sync/main/install.sh -o /tmp/agent-tools-sync-install.sh
bash /tmp/agent-tools-sync-install.sh
```

The wizard installs Homebrew, Git, Node.js, Python, uv, and Bun when missing. It asks separately whether to install Claude Code and Codex; both default to no. It then clones ATS into `~/.local/share/agent-tools-sync`, adds `agent-tools-sync` to `~/.local/bin`, and runs the sync. Open a new terminal before using the command. Agent sign-in happens in each agent's own CLI.

For a manual checkout instead:

```sh
git clone https://github.com/DeveloperBeau/agent-tools-sync.git
mkdir -p ~/.local/bin
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

`ats` checks the Git checkout's upstream first. A clean checkout fast-forwards and restarts the updated script before integrations start. Offline, dirty, or diverged checkouts continue with their local version. `ats start` skips updates and waits for Headroom readiness before starting Caveman.

For proxy-only startup that leaves the memory worker and the installed Headroom fork alone, use `bash proxy-chain.sh`. It preserves healthy processes and starts the existing Headroom deployment only if its port is not listening. See [chain verification](PROXY_CHAIN.md) for agent environment exports and separate compression measurements.

During full sync, ATS checks tool updates before setup. Headroom stays pinned to the diagnostic fork; upstream release checks report updates without replacing it. Installing a new pinned Headroom revision or updating Caveman restarts its running proxy. CLI hooks use updated executables on their next invocation. Existing agent sessions and the claude-mem worker keep running.

Optional standalone watchdog records separate Claude and ChatGPT Codex route health, captures incident evidence, and performs bounded Headroom recovery. It respects deliberate proxy stops and can capture reports manually. See [proxy recovery instructions](PROXY_RECOVERY.md) for installation, upstream fork maintenance, and rollback. ATS does not install or activate the watchdog automatically.

`ats kill` is a hard stop — nothing auto-restarts headroom's proxy afterward (unlike caveman, which self-starts on the next agent session). Since caveman chains every request through headroom, both agents get connection-refused on the last hop until you run `ats start` or `ats`.

## SkillOpt

ATS installs the [DeveloperBeau fork of SkillOpt](https://github.com/DeveloperBeau/SkillOpt),
which discovers agent guidance and prompts as optimization targets. It keeps a source
checkout at `~/.local/share/skillopt` and installs its CLI with `uv tool`.
Future syncs fast-forward the checkout and refresh the agent integrations.
Clean Microsoft `main` checkouts migrate to the fork while retaining Microsoft as
`upstream`; dirty, diverged, unrelated checkouts and conflicting remotes are preserved.
Set `SKILLOPT_SLEEP_REPO` to use another checkout location. Local checkout changes
are preserved. The Codex skill includes the checkout path so desktop sessions can
find it without inheriting terminal environment variables.

In Claude Code, use `/skillopt-sleep status`. In Codex, ask: “Use the skillopt-sleep
skill to run status for this project.” Start a new session after installation to
load the new integration. The CLI also works directly:

```sh
skillopt-sleep status --project "$PWD"
```

Optimization is opt-in. The default `mock` backend makes no model calls; real
`claude` and `codex` backends use the corresponding agent account and send
transcript-derived content to its provider. Review proposals before adoption.
Scheduling and automatic adoption remain explicit choices in SkillOpt.

For Codex learning runs, select `--source codex` and a Codex-visible
`--target-skill-path .agents/skills/<name>/SKILL.md`. The fork also supports
`--target-document-path` for discovered guidance or stage prompts, and
`--memory-path` for secondary guidance such as `CLAUDE.local.md` or `AGENTS.md`.

## Shared plans and Obsidian

Plans live only in `~/Developer/Personal/plans`, under one folder per project.
Set `ATS_PLANS_VAULT` before sync to choose another shared directory. Existing
notes and Obsidian settings are preserved; no community plugin is installed.
Python 3.11 or newer is required for this integration.

ATS installs managed instruction blocks and lifecycle hooks for both agents.
Session hooks resolve the repository, including linked worktrees, and supply
its canonical plan directory. Claude gets file access through
`permissions.additionalDirectories`; Codex gets the vault in its workspace
sandbox's `writable_roots`. Other permissions and hooks are preserved.

Claude's default `~/.claude/plans` is linked to `Inbox/Claude` inside the vault.
An existing native plans directory is moved intact when that Inbox is unused;
conflicting directories or links are preserved and reported. The user-level
`plansDirectory` override is removed because Claude rejects custom directories
outside the project root. Project-level overrides still take precedence; remove
those if native drafts continue landing in a code repository.

Approved Claude `ExitPlanMode` output and Codex `<proposed_plan>` responses are
saved automatically in the resolved project folder, with project, agent,
session, creation time, type, and status properties. Native Claude drafts stay
in the Inbox; approved snapshots are separate knowledge notes. Other answers
are not saved as plans. Designs, specs, decisions, and reviews written through
normal file tools follow the same canonical directory from the instructions.

Open **Plans Home.md** in Obsidian for linked project indexes, or **Plans.base**
for a table of note properties. Existing dated notes are indexed without being
rewritten. Indexes refresh at session start and after plan/turn completion;
ordinary code repositories receive no generated planning files. Handwritten
indexes are preserved and use a separate generated index when names conflict.

Start new Claude and Codex sessions to load the configuration. Codex may request
its normal hook trust review. Hook failures surface a warning without blocking
the conversation. Recovery copies of changed configuration files carry the
`.ats-plans-backup` suffix.

## Testing

```sh
bash test/run_tests.sh   # unit tests for every pure decision function
python3 -m unittest discover -s test -p 'test_*.py' -q
bash test/mutate.sh      # mutation testing against the test suite
```

Pure decision functions (parsing `caveman status`, `headroom install status`, config files, etc.) are isolated from their side-effecting orchestration functions specifically so they can be unit-tested without a live install. See `test/harness.sh` for the (dependency-free, no bats/shunit2) assertion helpers.

## License

MIT — see [LICENSE](LICENSE).
