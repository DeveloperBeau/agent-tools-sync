# agent-tools-sync

ATS installs and updates [headroom](https://github.com/headroomlabs-ai/headroom), [rtk](https://github.com/rtk-ai/rtk), [caveman](https://github.com/JuliusBrussee/caveman), and [ponytail](https://github.com/DietrichGebert/ponytail) for [Claude Code](https://claude.com/claude-code) and [Codex CLI](https://github.com/openai/codex).

Rerun ATS to check installed tools, apply updates, and refresh agent integrations.

## What it sets up

- **caveman:** proxy on `:8787`, plus agent hooks, skills, and MCP recovery. It forwards requests through headroom.
- **headroom:** downstream compression proxy on `:8788`, plus an on-demand MCP server in Claude Code.
- **rtk:** shell-output compression hook in both agents.
- **ponytail:** lazy-coding plugin in both agents.
- **Ship:** optional private plugin in both agents. ATS runs `ship-update` when installed or attempts installation through authenticated GitHub CLI. If access is unavailable, sync continues with the other tools.
- **SkillOpt:** [Microsoft's skill optimizer](https://github.com/microsoft/SkillOpt), with the SkillOpt-Sleep plugin for Claude Code and skill for Codex CLI/Desktop. It runs on demand and stages learned changes for review.
- **Obsidian plans:** optional shared Markdown vault with plan capture and project indexes. Setup is off by default; enable it with `ATS_OBSIDIAN_PLANS=1`.

Requests follow `agent → caveman (:8787) → headroom (:8788) → provider`. ATS configures a `compat.headroom` mount in `~/.caveman/caveman.yaml` and permits the loopback hop through `CAVE_SSRF_ALLOWLIST`.

ATS points Claude's `ANTHROPIC_BASE_URL` and Codex's `model_providers.caveman.base_url` at that mount. Caveman may then report its native integrations as "degraded" because ATS changed the files it fingerprints. ATS recognizes this routing configuration and leaves it in place.

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

You can copy the directory to another machine and symlink the entry point. The script resolves `lib/*.sh` from its own location.

## Usage

```sh
ats            # install/update tools and enabled integrations
ats kill       # stop both background proxies (caveman :8787, headroom :8788)
ats start      # bring both proxies back up, without the full sync
```

`ats` checks the Git checkout's upstream first. A clean checkout fast-forwards and restarts the updated script before integrations start. Offline, dirty, or diverged checkouts continue with their local version. `ats start` skips updates and waits for Headroom readiness before starting Caveman.

For proxy-only startup that leaves the memory worker and the installed Headroom fork alone, use `bash proxy-chain.sh`. It preserves healthy processes and starts the existing Headroom deployment only if its port is not listening. See [chain verification](PROXY_CHAIN.md) for agent environment exports and separate compression measurements.

During full sync, ATS checks tool updates before setup. Headroom stays pinned to the diagnostic fork; upstream release checks report updates without replacing it. Installing a new pinned Headroom revision or updating Caveman restarts its running proxy. CLI hooks use updated executables on their next invocation. Existing agent sessions and the claude-mem worker keep running.

The ATS-managed Caveman hook bridge removes unsupported context output from Codex `PostCompact` callbacks while preserving lifecycle recording, warnings, and stop controls. Codex restores Caveman context through its supported `SessionStart` callback with `source: compact`. This correction survives vendor CLI updates.

Optional standalone watchdog records separate Claude and ChatGPT Codex route health, captures incident evidence, and performs bounded Headroom recovery. It respects deliberate proxy stops and can capture reports manually. See [proxy recovery instructions](PROXY_RECOVERY.md) for installation, upstream fork maintenance, and rollback. ATS does not install or activate the watchdog automatically.

`ats kill` stops Headroom until you run `ats start` or `ats`. Caveman can self-start on the next agent session, but requests through the chain fail while Headroom is stopped.

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

Setup is opt-in. To enable it for one sync:

```sh
ATS_OBSIDIAN_PLANS=1 ats
```

For future syncs, add `export ATS_OBSIDIAN_PLANS=1` to your shell startup file.
Without this setting, ATS skips plans setup before checking dependencies or
changing files. Setting it to `0` also skips setup. This setting does not
uninstall an existing integration or change where its hooks save plans.

When enabled, plans live only in `~/Developer/Personal/plans`, under one folder
per project. Set `ATS_PLANS_VAULT` to choose another shared directory. ATS
preserves existing notes and Obsidian settings. The integration needs Python
3.11 or newer and uses no Obsidian community plugin.

ATS installs managed instruction blocks and lifecycle hooks for installed agents.
Session hooks resolve the repository, including linked worktrees, and supply
its canonical plan directory. Claude gets file access through
`permissions.additionalDirectories`; Codex gets the vault in its workspace
sandbox's `writable_roots`. Other permissions and hooks are preserved.

Claude's default `~/.claude/plans` is linked to `Inbox/Claude` inside the vault.
An existing native plans directory is moved intact when that Inbox is unused;
ATS preserves and reports conflicting directories or links. It removes the user-level
`plansDirectory` override because Claude rejects custom directories
outside the project root. Project-level overrides still take precedence; remove
those if native drafts continue landing in a code repository.

Hooks save approved Claude `ExitPlanMode` output and Codex `<proposed_plan>`
responses in the resolved project folder, with project, agent,
session, creation time, type, and status properties. Native Claude drafts stay
in the Inbox; approved snapshots are separate knowledge notes. Hooks ignore
other answers. Designs, specs, decisions, and reviews written through
normal file tools follow the same canonical directory from the instructions.

Open **Plans Home.md** in Obsidian for linked project indexes, or **Plans.base**
for a table of note properties. ATS indexes existing dated notes without
rewriting them. Indexes refresh at session start and after plan/turn completion;
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

Tests exercise parsing and setup decisions without a live tool installation. The shell assertion helpers are in `test/harness.sh` and need no test framework.

## License

MIT. See [LICENSE](LICENSE).
