# Triggers a wezterm-resurrect checkpoint on every `cd`, for finer-grained
# saves than its periodic timer alone. Guarded so it's a complete no-op
# outside an interactive wezterm pane -- safe to source in any fish config,
# on any terminal, with or without the wezterm-side plugin installed.
if status is-interactive; and set -q WEZTERM_PANE
    function __wezterm_resurrect_notify_cwd --on-variable PWD --description 'Trigger a wezterm-resurrect checkpoint on cd'
        printf '\033]1337;SetUserVar=%s=%s\007' WEZTERM_RESURRECT_SAVE (printf '1' | base64)
    end
end
