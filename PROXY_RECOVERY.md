# Proxy troubleshooting

## Codex hook descriptor exhaustion

`Too many open files (os error 24)` can occur before a hook process starts. Check
the Codex shared daemon's open descriptors and the launchd default limit:

```sh
pid=$(python3 -c 'import json,pathlib; print(json.loads((pathlib.Path.home()/".codex/app-server-daemon/app-server.pid").read_text())["pid"])')
lsof -nP -p "$pid" | awk 'NR>1 {types[$5]++; if ($4 ~ /^[0-9]/) total++} END {print "numeric descriptors:", total; for (t in types) print t, types[t]}'
launchctl limit maxfiles
```

Skill scan errors and command spawn errors in
`~/.codex/app-server-daemon/app-server.stderr.log` help distinguish host resource
exhaustion from an individual hook failure. The limit from `launchctl` is an
inherited default, not a direct measurement of the running daemon's limit.
The type totals above include mapped files; numeric descriptors are the relevant
open-descriptor count.

After saving active work, restart Codex's shared daemon from a shell with a
higher soft limit:

```sh
zsh -c 'ulimit -n 4096 && exec codex app-server daemon restart'
```

This interrupts active Codex sessions. It does not restart ATS proxies or the
memory worker. Increasing the limit and resetting descriptors is a mitigation;
continued descriptor growth needs host investigation. Shell limits apply to
new children, not an already-running daemon, and this command does not change
the machine's default for future unrelated launches.
