# wezterm-resurrect-chezmoi

Get your WezTerm windows, tabs, and pane layout (working directories
included) back after a reboot. Built on the plain capture/save/restore
library at [TheCookieLab/resurrect.wezterm](https://github.com/TheCookieLab/resurrect.wezterm)
— deliberately not a fork's `setup()` convenience wrapper. One such fork
(Wezurrect) turned out to pull in an undisclosed second plugin dependency
and wire internal behavior to an OSC-escape-sequence-triggered probe, which
is more surface area than a terminal-persistence tool should have. This
repo's glue code is short enough to read in one sitting — see
`dot_config/wezterm/conf/resurrect.lua`.

## How it works

- **`dot_config/wezterm/conf/resurrect.lua`** is the entire implementation:
  a periodic checkpoint every 2 minutes, a restore attempt on cold start
  (`gui-startup`, which the library guarantees never fires on a config
  reload — only on a genuine new process), and an `Alt+Shift+S` manual
  save. State lives in `~/.local/state/wezterm-resurrect` (created 0700;
  the library does not secure permissions itself).
- **`dot_config/fish/conf.d/wezterm-resurrect.fish`** triggers an extra
  checkpoint on every `cd`, for saves fresher than the periodic timer alone.
  It's guarded on `status is-interactive` and `set -q WEZTERM_PANE`, so it's
  a complete no-op in any shell that isn't an interactive WezTerm pane —
  safe to drop into any fish config via `conf.d`, which fish auto-sources
  without you editing `config.fish` or any existing function.

## Isolated per-pane fish history

`dot_config/fish/conf.d/wezterm-resurrect-history.fish` gives each pane (or,
inside zellij, each zellij pane) its own fish history file instead of the
one shared `fish_history` — so up-arrow recall in one tab isn't polluted by
what you typed in another. It's folded back into the main history (and
cleaned up) in two ways:

- **On normal tab/pane close**: a `fish_exit` handler merges that pane's
  history into the main file and deletes the per-pane file. No wezterm
  involvement needed for this path — it's just fish's own exit hook.
- **Periodically, and once right after a reboot**: `conf/resurrect.lua`'s
  existing 120-second tick (and its `gui-startup` handler) fire
  `dot_local/bin/executable_wezterm-resurrect-history-sweep`, which checks
  each per-pane history's recorded pid with `kill -0` and merges+deletes any
  whose owning shell is no longer running. This is what catches panes that
  died without a clean exit (a crash, a hard reboot) — right after boot,
  every recorded pid is necessarily from before this boot, so the same
  liveness check correctly treats all of them as orphaned.

**Automatically reconnecting a restored pane to its own history** (not just
isolating it) uses the library's capture/restore extension points directly:
`on_pane_capture` reads a per-pane id off the pane's wezterm user vars
(stamped there by the fish hook) and attaches it to the saved state;
`spawn_pane` wraps the library's own `default_spawn_pane` and injects that
same id as an environment variable into the freshly spawned shell, which the
fish hook then recognizes and reuses instead of generating a new id. This
round trip was exercised against a stub harness (fake `wezterm`/pane
objects — see the repo's build notes) confirming the id survives
capture → JSON-shaped state → restore intact, including the case where a
pane has no id at all.

**Zellij-aware by default**: a pane running inside zellij keys off zellij's
own `$ZELLIJ_PANE_ID`/`$ZELLIJ_SESSION_NAME` instead of the wezterm pane, so
zellij's internal panes (invisible to wezterm's own capture, which only
ever sees "one pane running zellij") don't all collide onto one history
file. Set `set -g wezterm_resurrect_zellij_aware 0` in your own fish config
*before* `conf.d` runs to disable this and key purely on the wezterm pane
even inside zellij. Note this only gives zellij panes correct *isolation*
and periodic/exit-triggered merging — the "automatically reconnects to the
same history after a restore" guarantee above is wezterm-specific (via
`on_pane_capture`/`spawn_pane`), since wezterm's capture never sees inside
zellij at all. Whether a zellij pane reconnects to its exact prior history
after a zellij-level session restore depends on zellij's own session
resurrection re-assigning pane ids the same way — outside this repo's
control, and not something we had a way to verify here.

A fish variable name can't contain hyphens (confirmed empirically — fish
silently falls back to the default history session on an invalid name
rather than erroring), so every generated id and sanitized zellij session
name has hyphens stripped/replaced before being used as the `fish_history`
value.

## Best-effort save on shutdown/reboot

`dot_config/systemd/user/wezterm-resurrect-final-save.service` is an
extra, best-effort layer on top of the periodic timer: a `--user` oneshot
unit whose `ExecStop` runs during shutdown (the standard
`RemainAfterExit=yes` + `Before=shutdown.target` pattern), poking any live
WezTerm pane's `WEZTERM_RESURRECT_SAVE` user var via `wezterm cli
set-user-var` — which `conf/resurrect.lua`'s `user-var-changed` handler
turns into a real save, the same path the fish cwd hook uses.

This is **not guaranteed to fire before WezTerm itself is gone**: on reboot,
your desktop session's teardown and systemd's unit-stopping sequence aren't
strictly ordered against each other in a way a user-level unit can control
cleanly. Treat it as a bonus chance at a slightly fresher save, not a
replacement for the periodic timer.

Enable it like the rest:

```
systemctl --user daemon-reload
systemctl --user enable --now wezterm-resurrect-final-save.service
```

## Limitations

- WezTerm has no Lua shutdown/SIGTERM hook. A `reboot` never gets a final
  clean save — recovery quality depends on how recent the last periodic
  checkpoint was (worst case: up to 2 minutes of layout changes lost, less
  if you're on fish and the cwd-triggered hook caught a more recent `cd`).
- Restore spawns fresh shells at the saved working directories. It does not
  replay scrollback, resume running programs, or reconnect remote domains —
  this is the library's default, and deliberately the simpler, more robust
  half of what it's capable of.
- The per-pane history mechanism (and the isolation itself) is local-only.
  SSH doesn't forward `$WEZTERM_PANE` to a remote shell by default (only
  variables the remote `sshd`'s `AcceptEnv` explicitly allows, which this
  isn't on a typical host), so a remote fish session over SSH won't pick up
  isolated history at all — it just behaves like it always did, same as the
  cwd-save hook already does outside wezterm. Consistent with the library
  not meaningfully restoring SSH panes anyway (they come back as
  disconnected local shells, not live reconnections).
- This was built and checked as far as a GUI-less environment allows: Lua
  syntax via `luac`, actual Lua *execution* of `conf/resurrect.lua` against
  a stub `wezterm`/pane harness confirming the capture → restore round trip
  really does carry a history id through `set_environment_variables`
  (including the no-id case), the fish hooks via `fish -n` plus real
  interactive runs (zellij-keyed, wezterm-keyed, the opt-out toggle, and the
  fully-inert case all independently verified), the history-sweep script
  against simulated live/dead pid scenarios, and the systemd unit via
  `systemd-analyze verify`. None of that is a substitute for real WezTerm
  runtime behavior (`gui-startup` actually firing on a cold start, the real
  capture/restore implementation, real pane user-var propagation) — there's
  no GUI in the environment this was built in. Install it and watch the
  first restore before trusting it.

## Requirements

- WezTerm `20240203-110809-5046fc22` or newer.
- `chezmoi` on `PATH`.
- fish, if you want the cwd-triggered saves (optional — the periodic timer
  and manual `Alt+Shift+S` work regardless of shell).

## Install

Needs `chezmoi` itself on `PATH` first — see Requirements above.

Clone as its own chezmoi source directory, independent of any other
chezmoi setup you might have:

```
git clone <this-repo-url> ~/.local/share/chezmoi-wezterm
chezmoi init --source ~/.local/share/chezmoi-wezterm
chezmoi diff --source ~/.local/share/chezmoi-wezterm --persistent-state ~/.local/state/chezmoi-profiles/wezterm.boltdb
chezmoi apply --source ~/.local/share/chezmoi-wezterm --persistent-state ~/.local/state/chezmoi-profiles/wezterm.boltdb
```

**Always pass `--persistent-state`.** chezmoi supports running several
independent `--source` profiles on one machine, but they share one global
state database by default regardless — and since this repo, `fish-chezmoi`,
and `zen-updater-chezmoi` all separately manage `~/.local/bin`, without
this flag whichever profile applies second sees that shared directory as
"changed since chezmoi last wrote it" and refuses to touch it. Confirmed
by hitting this for real and fixing it. If you're running more than one
chezmoi profile this way, a small wrapper (shell function, alias, whatever
you use) that calls `chezmoi apply --source <dir> --persistent-state <its
own state file>` for each in turn is the standard way to apply them all.

This is the one piece chezmoi can't safely automate: `wezterm.lua` is a
single file you've almost certainly already customized, so this repo
doesn't template over it — add these two lines yourself, after
`wezterm.config_builder()` and before `return config`:

```lua
package.path = package.path .. ";" .. wezterm.config_dir .. "/?.lua"
require("conf.resurrect")(config)
```

That's it — never needs to change again. All future updates to the
persistence logic itself land via `chezmoi apply` re-rendering
`conf/resurrect.lua`, not by touching `wezterm.lua` again.

## Manual save / restore

- `Alt+Shift+S` — save right now.
- Restore happens automatically on WezTerm startup (cold start only, never
  on a config reload).

## Uninstall

```
./uninstall.sh
```

run from wherever you cloned this repo. It stops and removes the systemd
units, deletes everything it installed under `~/.config` and
`~/.local/bin`, and tells you what's left to do by hand (removing the two
lines from `wezterm.lua`, and dealing with any leftover per-pane history
files). It doesn't delete the chezmoi source directory itself or the clone
— `rm -rf` those yourself if you're done with this entirely.
