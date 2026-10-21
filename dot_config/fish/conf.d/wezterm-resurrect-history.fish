# Isolated per-pane fish history, merged back into the main history when the
# pane closes (and swept up periodically/after a reboot by
# wezterm-resurrect-history-sweep for panes that didn't exit cleanly).
# Zellij-aware by default: a pane running inside zellij keys off zellij's
# own per-pane identity ($ZELLIJ_PANE_ID / $ZELLIJ_SESSION_NAME) instead of
# the wezterm pane, so zellij's internal panes don't all collide onto one
# history file. Set `set -g wezterm_resurrect_zellij_aware 0` in your own
# config (before conf.d runs -- e.g. in config.fish) to key on the wezterm
# pane even inside zellij.
#
# Complete no-op outside an interactive wezterm pane or zellij pane: safe to
# source in any fish config, on any terminal.
if status is-interactive
    if not set -q wezterm_resurrect_zellij_aware
        set -g wezterm_resurrect_zellij_aware 1
    end

    set -l history_key ""

    # fish_history's value must be a valid fish variable name -- no hyphens.
    # (Confirmed: fish silently falls back to the default "fish" history
    # session on an invalid name rather than erroring, so this is a strict
    # requirement, not a style preference.)
    if test "$wezterm_resurrect_zellij_aware" = 1; and set -q ZELLIJ_PANE_ID
        set -l session_part (string replace -ra '[^A-Za-z0-9_]' '_' "$ZELLIJ_SESSION_NAME")
        set -l pane_part (string replace -ra '[^A-Za-z0-9_]' '_' "$ZELLIJ_PANE_ID")
        set history_key "zellij_$session_part"_"$pane_part"
    else if set -q WEZTERM_PANE
        if not set -q WEZTERM_RESURRECT_HISTORY_ID
            set -l raw_id (cat /proc/sys/kernel/random/uuid 2>/dev/null; or string join '' (random) (random) (random))
            set -gx WEZTERM_RESURRECT_HISTORY_ID (string replace -ra '[^A-Za-z0-9_]' '' "$raw_id")
        end
        set history_key "wezterm_$WEZTERM_RESURRECT_HISTORY_ID"
        # Re-stamp the live pane on every shell start (idempotent) so the
        # *next* resurrect capture can read this id back off the pane via
        # on_pane_capture/get_user_vars, even if this shell was itself
        # spawned fresh rather than restored.
        printf '\033]1337;SetUserVar=%s=%s\007' WEZTERM_RESURRECT_HISTORY_ID (printf '%s' "$WEZTERM_RESURRECT_HISTORY_ID" | base64)
    end

    if test -n "$history_key"
        set -g fish_history $history_key

        set -g __wezterm_resurrect_lock_dir "$HOME/.local/state/wezterm-resurrect/history-locks"
        set -g __wezterm_resurrect_lock_file "$__wezterm_resurrect_lock_dir/$history_key.pid"
        mkdir -p "$__wezterm_resurrect_lock_dir"
        echo $fish_pid > "$__wezterm_resurrect_lock_file"

        function __wezterm_resurrect_history_merge_on_exit --on-event fish_exit --description 'Merge this pane''s isolated history into the main history on close'
            set -l main_history "$HOME/.local/share/fish/fish_history"
            set -l my_history "$HOME/.local/share/fish/$fish_history"_history
            if test -f "$my_history"
                cat "$my_history" >> "$main_history"
                rm -f "$my_history"
            end
            rm -f "$__wezterm_resurrect_lock_file"
            # A pane that's deliberately closing has no restore coming for
            # it specifically, so its saved custom env vars (see
            # conf.d/wezterm-resurrect.fish) are equally stale -- clean up
            # alongside history rather than leaking indefinitely. Only
            # applies to the wezterm branch; zellij panes never get an
            # env file in the first place.
            if set -q WEZTERM_RESURRECT_HISTORY_ID
                rm -f "$HOME/.local/state/wezterm-resurrect/env/$WEZTERM_RESURRECT_HISTORY_ID.env"
            end
        end
    end
end
