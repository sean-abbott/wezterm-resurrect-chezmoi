# Triggers a wezterm-resurrect checkpoint on every `cd`, for finer-grained
# saves than its periodic timer alone. Also continuously stamps the pane's
# real cwd as a user var -- WezTerm's own process-based cwd detection
# (what the library's capture normally relies on) comes back empty for
# panes running an alt-screen foreground app (e.g. Claude Code's TUI), so
# a pane that's just running `claude` would otherwise restore to a default
# directory instead of wherever it was actually started. Fish always
# knows its own $PWD regardless of what's running in the foreground, so
# conf/resurrect.lua's on_pane_capture/spawn_pane prefer this over the
# library's own (possibly empty) captured cwd.
#
# Guarded so it's a complete no-op outside an interactive wezterm pane --
# safe to source in any fish config, on any terminal, with or without the
# wezterm-side plugin installed.
if status is-interactive; and set -q WEZTERM_PANE
    function __wezterm_resurrect_notify_cwd --on-variable PWD --description 'Trigger a wezterm-resurrect checkpoint and cwd stamp on cd'
        printf '\033]1337;SetUserVar=%s=%s\007' WEZTERM_RESURRECT_SAVE (printf '1' | base64)
        printf '\033]1337;SetUserVar=%s=%s\007' WEZTERM_RESURRECT_CWD (printf '%s' "$PWD" | base64 -w0)
    end
    # --on-variable only fires on future changes, not the initial value --
    # a pane that never cd's again (e.g. launches straight into claude)
    # still needs its starting cwd stamped once up front.
    printf '\033]1337;SetUserVar=%s=%s\007' WEZTERM_RESURRECT_CWD (printf '%s' "$PWD" | base64 -w0)
end

# Persists this pane's own custom-exported env vars to a per-pane file
# (exportenv-compatible: config.fish in fish-chezmoi reloads it before a
# restored pane takes its own baseline), so manually `set -x`'d vars
# survive a restore the same way history/cwd/title do. Only vars that
# differ from this session's own startup baseline count -- see
# config.fish for where that baseline gets captured, right after ssh-agent
# and everything else conf.d sets up, so none of that counts as "custom".
# A short excludelist on top catches vars that naturally change during
# normal use regardless of baseline (cwd navigation, prompt bookkeeping).
if status is-interactive; and set -q WEZTERM_PANE
    function __wezterm_resurrect_save_env --on-event fish_prompt --description 'Persist this pane''s custom-exported env vars for wezterm-resurrect'
        set -q WEZTERM_RESURRECT_HISTORY_ID; or return
        set -q __wezterm_resurrect_env_baseline; or return

        set -l current (env | sort)
        set -l custom
        for line in $current
            contains -- "$line" $__wezterm_resurrect_env_baseline; and continue
            set -l key (string split -m1 '=' -- "$line")[1]
            switch $key
                case PWD OLDPWD SHLVL _ COLUMNS LINES \
                     WEZTERM_RESURRECT_SAVE WEZTERM_RESURRECT_CWD \
                     WEZTERM_RESURRECT_TITLE WEZTERM_RESURRECT_HISTORY_ID
                    continue
            end
            set -a custom "$line"
        end

        set -l env_dir "$HOME/.local/state/wezterm-resurrect/env"
        set -l env_file "$env_dir/$WEZTERM_RESURRECT_HISTORY_ID.env"
        if test (count $custom) -eq 0
            rm -f "$env_file"
        else
            mkdir -p "$env_dir"
            printf '%s\n' $custom > "$env_file"
        end
    end
end
