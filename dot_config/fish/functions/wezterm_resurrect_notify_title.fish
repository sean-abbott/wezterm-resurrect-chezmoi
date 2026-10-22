function wezterm_resurrect_notify_title --argument-names title --description 'Stamp the current window title so wezterm-resurrect can capture and restore it'
    set -q WEZTERM_PANE; or return
    # stderr, not stdout: this is called from fish_title, whose stdout fish
    # captures and uses as the title text itself.
    printf '\033]1337;SetUserVar=%s=%s\007' WEZTERM_RESURRECT_TITLE (printf '%s' "$title" | base64 -w0) >&2
end
