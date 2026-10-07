# agent-tools-sync

ATS installs and updates for the tools I use alongside [Claude Code](https://claude.com/claude-code) and [Codex CLI](https://github.com/openai/codex).

Rerun ATS to check installed tools, apply updates, and refresh agent integrations.

## What it sets up

- **caveman:** proxy on `:8787`, plus agent hooks, skills, and MCP recovery. It forwards requests through headroom.
- **headroom:** downstream compression proxy on `:8788`, plus an on-demand MCP server in Claude Code.
- **rtk:** shell-output compression hook in both agents.
- **xcsift:** when Xcode is installed, a Claude Code hook pipes `xcodebuild` and `swift build`/`swift test` through [xcsift](https://github.com/ldomaradzki/xcsift), after [Daniel Saidi's setup](https://danielsaidi.com/blog/2026/09/30/optimizing-claude-code-s-xcode-build-token-usage). ATS adds those commands to rtk's `exclude_commands` so the two hooks don't race to rewrite them.
- **Search tools:** Homebrew `ripgrep`, `fd`, `sd` and `ast-grep`, installed or upgraded on each sync.
- **grepai:** [semantic code search](https://github.com/yoanbernabeu/grepai) with local Ollama embeddings, registered as a user-scope MCP server in Claude Code. See [grepai](#grepai).
- **ponytail:** lazy-coding plugin in both agents.
- **Ship:** optional private plugin in both agents. ATS runs `ship-update` when installed or attempts installation through authenticated GitHub CLI. If access is unavailable, sync continues with the other tools.
- **SkillOpt:** [Microsoft's skill optimizer](https://github.com/microsoft/SkillOpt), with the SkillOpt-Sleep plugin for Claude Code and skill for Codex CLI/Desktop. It runs on demand and stages learned changes for review.
- **Context7:** [current library documentation](https://github.com/upstash/context7), registered as a remote HTTP MCP server for installed agents.
- **Serena:** [semantic code navigation and editing](https://github.com/oraios/serena), installed through uv and registered as a local stdio MCP server for installed agents.
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
ats            # install/update tools and enabled integrations, full proxy chain
ats --no-headroom               # same sync, agents → Caveman → provider
ats --no-caveman                # same sync, agents → Headroom → provider
ats --no-headroom --no-caveman  # same sync, agents → provider (direct)
ats kill       # stop both proxies and the memory worker
ats start      # start both proxies and the memory worker, without full sync
ats watchdog capture  # save incident evidence without restarting
ats watchdog fire     # force Headroom recovery, ignoring detection/cooldown
```

`ats` checks the Git checkout's upstream first. A clean checkout fast-forwards and restarts the updated script before integrations start. Offline, dirty, or diverged checkouts continue with their local version. Full sync starts the proxy chain after setup. `ats start` skips updates and waits for Headroom readiness before starting Caveman, then starts the installed memory-worker runtime. An existing memory worker stays running, preserving its provider backoff.

For proxy-only startup that leaves the memory worker and the installed Headroom fork alone, use `bash proxy-chain.sh`. It preserves healthy processes and starts the existing Headroom deployment only if its port is not listening. See [chain verification](PROXY_CHAIN.md) for agent environment exports and separate compression measurements.

During full sync, ATS checks tool updates before setup. Headroom stays pinned to the diagnostic fork; upstream release checks report updates without replacing it. Installing a new pinned Headroom revision or updating Caveman restarts its running proxy. CLI hooks use updated executables on their next invocation. Existing agent sessions and the claude-mem worker keep running.

The ATS-managed Caveman hook bridge removes unsupported context output from Codex `PostCompact` callbacks while preserving lifecycle recording, warnings, and stop controls. Codex restores Caveman context through its supported `SessionStart` callback with `source: compact`. This correction survives vendor CLI updates.

Optional standalone watchdog records separate Claude and ChatGPT Codex route health, captures incident evidence, and performs bounded Headroom recovery. It respects deliberate proxy stops and can capture reports manually. See [proxy recovery instructions](PROXY_RECOVERY.md) for installation, upstream fork maintenance, and rollback. ATS does not install or activate the watchdog automatically.

The proxy flags select a mode, and ATS keeps the mode in `~/.caveman/ats-mode` (or `$CAVEMAN_HOME`). A plain `ats` run removes the file and restores the full chain. The sync does not install or update a skipped proxy. It stops the skipped proxy and points Claude Code and Codex at the first hop that remains. ATS changes only base URLs that it manages, and keeps a custom URL. `ats start` and `proxy-chain.sh start` start only the proxies that the mode uses. The watchdog does not restart Headroom in the `no-headroom` or `direct` mode. The Caveman wrapper skips native hooks in the `no-caveman` or `direct` mode. Restart open agent sessions after a mode change, because a session keeps the route that it started with.

| Mode | Claude Code base URL | Codex base URL |
|---|---|---|
| full | `http://127.0.0.1:8787/compat/headroom` | `http://127.0.0.1:8787/compat/headroom` |
| no-headroom | `http://127.0.0.1:8787/w/claude` | `http://127.0.0.1:8787/chatgpt` |
| no-caveman | `http://127.0.0.1:8788` | `http://127.0.0.1:8788` |
| direct | none (Anthropic) | `https://chatgpt.com/backend-api/codex` |

`ats kill` records stop intent in `~/.caveman/ats-stopped` before stopping services. The ATS-managed Caveman wrapper silently skips native hooks while stopped, and the watchdog honors the marker even before Headroom is unloaded. `ats start`, full `ats` sync, and `proxy-chain.sh start` clear the marker. Shutdown waits for in-progress watchdog work under the same control lock, then waits for identified Caveman listeners, escalates only those PIDs when needed, and preserves unknown processes. Lock acquisition waits up to three minutes. Failed shutdown or unavailable process inspection returns a failing command status.

If `headroom install restart` fails, the watchdog loads the Headroom LaunchAgent again. A failed restart can leave the job unloaded, and launchd then does not restart it. The incident report keeps the last line of the restart error and the result of the reload.

`ats watchdog fire` captures evidence before restarting Headroom, bypasses the automatic detection threshold and restart cooldown, and fails if restart or readiness fails. It preserves deliberate stop intent; run `ats start` first when stopped. Restart interrupts active proxy requests. Manual recovery shares a state lock with daemon polling and shutdown. If busy, it reports the wait and allows up to three minutes for the current operation to finish, then reads fresh state and checks stop intent before recovery. A lock timeout fails without a restart. If an older watchdog is still running, reload its LaunchAgent using the installation command in [proxy recovery instructions](PROXY_RECOVERY.md) before using `fire`.

If hooks report `Too many open files (os error 24)`, inspect the agent process rather than restarting proxies. Codex's shared daemon can exhaust its inherited descriptor limit, affecting skill scans and command spawning as well as hooks. See [descriptor troubleshooting](PROXY_RECOVERY.md#codex-hook-descriptor-exhaustion).

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

## grepai

ATS installs `grepai` (from `yoanbernabeu/tap`) and `ollama` with Homebrew, runs Ollama from its own LaunchAgent (`au.com.beauayres.agent-tools-sync.ollama`, stopping the `brew services` one if registered) with `OLLAMA_KEEP_ALIVE=-1`, adds `.grepai/` to your global git excludes, and, when Claude Code is installed, runs `claude mcp add --scope user grepai -- grepai mcp-serve` unless `grepai` is already registered. The excludes file is whatever `core.excludesFile` points at; if none is set, ATS creates `~/.config/git/ignore` and sets the config. A repository's own `.gitignore` is never touched. ATS does not run `grepai init` or index any repository.

The first sync that sets up grepai asks which embedding model to download:

- `qwen3-embedding:8b` (recommended): best search quality, fast once loaded; about a 4.7 GB download, keeps about 9 GB of memory held while Ollama runs, best on Apple silicon with 16 GB or more.
- `nomic-embed-text`: about a 274 MB download, runs on any Mac, lower search quality.

The LaunchAgent exists because Ollama otherwise unloads the model after every request, and grepai sends no keep-alive: qwen3 took about 9 s per chunk that way, against 0.04 to 0.1 s with the model kept loaded. Homebrew regenerates its own service file on every start, so the environment can't be set there. After pulling, ATS sends one embed request to warm the model. Logs go to `~/Library/Logs/ollama.log`.

The question uses the terminal (the bootstrap's open terminal, else `/dev/tty`). With no terminal, ATS pulls `nomic-embed-text` and says so; the next run in a terminal still asks. If the `qwen3-embedding:8b` pull fails, ATS warns, pulls `nomic-embed-text` and records it as active. Later syncs pull only the recorded model, and a failed update of a model you already have keeps it.

The choice lives in `~/.caveman/ats-grepai.env` (or `$CAVEMAN_HOME`), beside ATS's stop marker. Delete the file to be asked again. It holds `GREPAI_MODEL`, `GREPAI_DIMENSIONS` (4096 for qwen3, 768 for nomic) and `GREPAI_ASKED`.

To use grepai in a repository, run `grepai init --provider ollama --backend gob --yes`, then set the model in `.grepai/config.yaml` to match the file above. `grepai init` has no model flag for Ollama (it always writes `nomic-embed-text`, 768):

```yaml
embedder:
    provider: ollama
    model: qwen3-embedding:8b
    dimensions: 4096
```

Run `grepai watch` to index. Watching a repo indexes every git worktree of it, each roughly as costly as the main checkout, so prune merged worktrees first. grepai also appends `.grepai/` to each checkout's tracked `.gitignore` when it first sets it up, and `grepai init` does the same in the main checkout. The global excludes already cover this, so the line is redundant and leaves a modified tracked file that is easy to commit by accident. After the first index, run `git checkout -- .gitignore` in each checkout whose only change to that file is that line. Change the model or dimensions only before indexing, or delete `.grepai/` and reindex; embeddings from different models are not comparable. ATS adds no agent instructions for these tools.

## Context7 and Serena

Full `ats` sync registers both MCP servers at user scope for whichever agents
are installed. Existing entries named `context7` or `serena` are preserved,
including custom endpoints, commands, API keys, and environment settings.
ATS reads the user registries directly; it does not health-check or launch
MCP servers while checking these registrations. Invalid or unreadable registries
are preserved and reported. Registry inspection needs Python 3; Codex TOML
inspection needs Python 3.11 or newer.

Context7 uses `https://mcp.context7.com/mcp` without a local Node process.
Anonymous access works without a key; configure authentication in your agent
for higher limits if needed.

ATS installs `serena-agent` with `uv tool install --python 3.13` and upgrades
uv-managed installations on later syncs. Existing Serena executables outside
that uv tool are preserved and used without replacement. Serena's configuration
is initialized only when `serena_config.yml` is absent from `SERENA_HOME`
(default `~/.serena`), preserving existing backend settings. ATS registers an
absolute executable path, with `claude-code` or `codex` context and
`--project-from-cwd`. Automatic browser opening is disabled.

Start a new agent session after registration. Serena finds the nearest ancestor
with `.serena/project.yml` or `.git` from the agent's working directory. If
Codex Desktop starts elsewhere, ask: “Activate the current dir as project using
serena.” Project configuration and language-server availability remain managed
by Serena. These MCP sessions belong to the agents; `ats start`, `ats kill`,
and the proxy watchdog do not manage them.

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
