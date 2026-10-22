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
  checkpoint on every `cd`, for saves fresher than the periodic timer
  alone; also stamps the pane's real cwd, reloads custom env vars and the
  last title on startup, and persists custom env vars going forward (see
  below for all three). Guarded on `status is-interactive` and `set -q
  WEZTERM_PANE`, so it's a complete no-op in any shell that isn't an
  interactive WezTerm pane — safe to drop into any fish config via
  `conf.d`, which fish auto-sources without you editing `config.fish` or
  any existing function. This repo never touches `config.fish` itself —
  see "cwd restore for alt-screen apps, and tab titles" below for the one
  thing (titles) that needs a one-line opt-in from you instead.
- **`dot_config/fish/functions/wezterm_resurrect_notify_title.fish`** and
  **`dot_config/fish/functions/__wezterm_resurrect_load_env.fish`** —
  supporting pieces for the above, plain callable functions rather than
  anything that redefines `fish_title` or collides with a generic
  dotenv-loader a separate fish config might ship under a name like
  `exportenv`.

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

## cwd restore for alt-screen apps, and tab titles

Two related gaps, both from the same root cause: WezTerm's own capture
relies on process introspection to get a pane's cwd, and its own
`tab:get_title()` only reflects a title explicitly set through its Lua
API — neither sees anything the shell itself displays via OSC sequences.
In practice this meant panes running an alt-screen foreground app (a TUI)
restored to a default directory
instead of wherever they actually started, and tab titles came back
blank regardless of what was shown before.

Fish always knows its own `$PWD` regardless of what's running in the
foreground, so cwd is tracked the same way as the history id: stamped
continuously as a wezterm user var (on every `cd`, plus once at shell
start), read back by `on_pane_capture`, and injected into the respawned
shell's environment by `spawn_pane`.

Titles work the same way, but deliberately **don't** redefine
`fish_title` for you — function definitions in fish don't coexist the way
hooks do, so a repo that silently overrides `fish_title` would clobber
whatever you've already customized it to do (this one originally lived in
`fish-chezmoi`'s `config.fish` for exactly that reason, until making this
repo public made the dependency the wrong way around). Instead,
`functions/wezterm_resurrect_notify_title.fish` is a plain function you
opt into calling from your own `fish_title`, however it's defined:

```fish
function fish_title
    set -l title ...  # however you already compute it
    type -q wezterm_resurrect_notify_title; and wezterm_resurrect_notify_title $title
    echo $title
end
```

Complete no-op if you never call it (no title tracking, same as before
this feature existed) and a complete no-op outside a wezterm pane even if
you do. `conf.d/wezterm-resurrect.fish` picks the stamped value back up
on restore and adopts it into `$__TERMTITLE` before the first prompt
renders, so whatever your own `fish_title` checks for a custom title
(the convention above assumes a `$__TERMTITLE`-style variable, same as
`fish-chezmoi`'s) sees it immediately rather than one render late.

## Titles set by other programs

At capture, a pane's title is its `WEZTERM_RESURRECT_TITLE` user var if
set, otherwise `pane:get_title()`. Anything that can emit
`OSC 1337 ; SetUserVar=WEZTERM_RESURRECT_TITLE=<base64 title>` to the
pane (the fish function above does) controls what a restored pane
comes back with.

## Custom env vars

A pane's own `set -x`'d env vars (not the whole environment — see below
for what's excluded and why) survive a restore the same way history/cwd/
title do, with no fish_title-style integration needed — this one's purely
hooks, so it works automatically the moment this repo is installed.
`conf.d/wezterm-resurrect.fish` diffs the current environment against a
baseline captured once at this session's own startup (right after
ssh-agent and everything else conf.d sets up, so none of that counts as
"custom"), on every prompt, and writes whatever's left over to a per-pane
file (`~/.local/state/wezterm-resurrect/env/<history_id>.env`) keyed by
the same history id used for per-pane history. A short excludelist
(`PWD`, `OLDPWD`, `SHLVL`, etc.) catches vars that naturally change during
normal use regardless of baseline.

This file lives independently of the JSON session snapshot — a restored
pane reloads it (via the internal `__wezterm_resurrect_load_env` helper,
deliberately not named or shaped like a generic dotenv-loader a separate
fish config might also ship, to avoid two different tools claiming the
same target path) directly from disk before taking its own baseline, so
only genuinely new exports made after that count toward the next save.
Cleaned up the same way as history: on normal pane close (`fish_exit`),
and by the periodic/post-reboot sweep for panes that didn't exit cleanly.

Verified end to end: captured a custom export in one simulated pane,
confirmed the written file contained only that var (not `PWD`,
`SSH_AUTH_SOCK`, or any of our own `WEZTERM_RESURRECT_*` vars), confirmed
a second simulated pane inheriting the same history id via env correctly
reloaded it, and confirmed a pane with nothing custom set writes no file
at all.

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
