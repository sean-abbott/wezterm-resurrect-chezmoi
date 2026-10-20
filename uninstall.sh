#!/bin/sh
# Removes everything this repo installs. Run directly from wherever you
# cloned this repo (it doesn't need to be applied via chezmoi first).
set -eu

systemctl --user disable --now wezterm-resurrect-final-save.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/wezterm-resurrect-final-save.service"
rm -f "$HOME/.local/bin/wezterm-resurrect-final-save"
rm -f "$HOME/.local/bin/wezterm-resurrect-history-sweep"
rm -f "$HOME/.config/wezterm/conf/resurrect.lua"
rm -f "$HOME/.config/fish/conf.d/wezterm-resurrect.fish"
rm -f "$HOME/.config/fish/conf.d/wezterm-resurrect-history.fish"
rm -rf "$HOME/.local/state/wezterm-resurrect"
systemctl --user daemon-reload 2>/dev/null || true

echo "Removed. Two things left for you:"
echo "  - remove the two added lines from your wezterm.lua"
echo "  - leftover per-pane history files, if any:"
echo "      ~/.local/share/fish/wezterm_*_history"
echo "      ~/.local/share/fish/zellij_*_history"
echo "    safe to 'cat' into ~/.local/share/fish/fish_history, or just delete"
echo "This script and the chezmoi source directory it came from are left in"
echo "place -- remove the clone yourself if you're done with it entirely."
