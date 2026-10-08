# Quack reload launchd agent

`com.inframe.quack-reload.plist` is the tracked template for the per-user
launchd agent that watches `/Users/aloksubbarao/duckdb-skills/server`.

The agent snapshots every regular file below `server/` so that a WatchPaths
notification can be classified. Only changed paths ending in `.sql` or `.tera`
are treated as files dev loads and cause a `launchctl kickstart -k`. Every other
changed path is written to `~/.duck/logs/reload-events.log` as
`event=skipped reason=not-loaded`. The snapshot is stored at
`~/.duck/local/reload-source.snapshot`.

## Install

From the checkout containing this template:

```bash
cp server/launchd/com.inframe.quack-reload.plist "$HOME/Library/LaunchAgents/com.inframe.quack-reload.plist"
launchctl bootout "gui/$(id -u)/com.inframe.quack-reload"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.inframe.quack-reload.plist"
launchctl print "gui/$(id -u)/com.inframe.quack-reload"
```

The `bootout` command is only needed when replacing an already-loaded copy; if
the label is not loaded, continue with `bootstrap`. The template intentionally
does not install or reload itself. It is written for this machine's
`/Users/aloksubbarao/duckdb-skills/server` path; change both `WatchPaths` and
the default paths in the inline script before installing on another machine.

## Dry run

The inline script supports `RELOAD_DRY_RUN=1` and path overrides so the exact
template can be exercised without touching the live snapshot, log, or quack:

```bash
reload_script="$(plutil -extract ProgramArguments.2 raw -o - server/launchd/com.inframe.quack-reload.plist)"
RELOAD_DRY_RUN=1 \
RELOAD_SERVER_DIR="$tmp/server" \
RELOAD_STATE_DIR="$tmp/state" \
RELOAD_LOG="$tmp/reload-events.log" \
RELOAD_TARGET="gui/$(id -u)/com.inframe.quack" \
/bin/bash -c "$reload_script"
```

Touching `.DS_Store` or `.md` produces `event=skipped` and does not call
`launchctl`; touching `.sql` or `.tera` produces `event=triggered action=dry-run`.
