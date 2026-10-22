-- Terminal session persistence across a reboot: periodic checkpoints plus
-- restore-on-cold-start, built on the plain capture/save/restore library at
-- https://github.com/TheCookieLab/resurrect.wezterm (not the convenience
-- `setup()` wrappers some forks ship -- those pull in undisclosed extra
-- dependencies and probe hooks we don't want). Call this from your own
-- wezterm.lua:
--
--   package.path = package.path .. ";" .. wezterm.config_dir .. "/?.lua"
--   require("conf.resurrect")(config)
--
-- before `return config`.

local wezterm = require("wezterm")
local resurrect = wezterm.plugin.require("https://github.com/TheCookieLab/resurrect.wezterm")

local state_dir = wezterm.home_dir .. "/.local/state/wezterm-resurrect"
local history_sweep_script = wezterm.home_dir .. "/.local/bin/wezterm-resurrect-history-sweep"
local SAVE_INTERVAL_SECONDS = 120
local CWD_SAVE_USER_VAR = "WEZTERM_RESURRECT_SAVE"
local HISTORY_ID_USER_VAR = "WEZTERM_RESURRECT_HISTORY_ID"
local CWD_USER_VAR = "WEZTERM_RESURRECT_CWD"
local TITLE_USER_VAR = "WEZTERM_RESURRECT_TITLE"

local function is_local_dir(path)
	local f = path and io.open(path .. "/.", "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- Carries each pane's isolated-history id (stamped by
-- conf.d/wezterm-resurrect-history.fish as a wezterm user var) through the
-- capture/restore round trip, so a restored pane's shell inherits the same
-- id and reconnects to the same history file instead of starting a new one.
-- The same round trip carries the shell-reported cwd and the pane title:
-- the library's own cwd comes back empty for alt-screen foreground apps,
-- and an app-set title (OSC 0/2) is only visible through pane:get_title().
local function on_pane_capture(pane, leaf)
	local user_vars = pane:get_user_vars()
	if user_vars and user_vars[HISTORY_ID_USER_VAR] then
		leaf.history_id = user_vars[HISTORY_ID_USER_VAR]
	end
	if user_vars and user_vars[CWD_USER_VAR] and user_vars[CWD_USER_VAR] ~= "" then
		leaf.saved_cwd = user_vars[CWD_USER_VAR]
	end
	local title = user_vars and user_vars[TITLE_USER_VAR]
	if not title or title == "" then
		title = pane:get_title()
	end
	if title and title ~= "" then
		leaf.saved_title = title
	end
end

local function spawn_pane(leaf, opts)
	local cmd, notice = resurrect.pane_tree.default_spawn_pane(leaf, opts)
	if leaf.history_id then
		cmd.set_environment_variables = cmd.set_environment_variables or {}
		cmd.set_environment_variables[HISTORY_ID_USER_VAR] = leaf.history_id
	end
	if leaf.saved_title then
		cmd.set_environment_variables = cmd.set_environment_variables or {}
		cmd.set_environment_variables[TITLE_USER_VAR] = leaf.saved_title
	end
	if leaf.saved_cwd and is_local_dir(leaf.saved_cwd) then
		cmd.cwd = leaf.saved_cwd
	end
	return cmd, notice
end

return function(config)
	local manager = resurrect.state_manager

	os.execute('mkdir -p -m 700 "' .. state_dir .. '"')
	local ok, change_dir_err = manager.change_state_save_dir(state_dir)
	if not ok then
		wezterm.log_error("resurrect: could not set state dir: " .. tostring(change_dir_err))
	end
	manager.set_max_nlines(3500)

	local function sweep_history()
		wezterm.background_child_process({ history_sweep_script })
	end

	local function checkpoint()
		local snapshot, capture_err = resurrect.session_state.capture({ on_pane_capture = on_pane_capture })
		if not snapshot then
			wezterm.log_error("resurrect: capture failed: " .. tostring(capture_err))
			return
		end
		local path, warn_or_err = manager.save_session(snapshot)
		if not path then
			wezterm.log_error("resurrect: save failed: " .. tostring(warn_or_err))
		elseif warn_or_err then
			wezterm.log_warn("resurrect: save warning: " .. tostring(warn_or_err))
		end
	end

	-- conf.d/wezterm-resurrect.fish emits this user var on every `cd`, for
	-- finer-grained saves than the periodic timer alone. Harmless if that
	-- hook isn't installed, or you're not on fish -- this just never fires.
	wezterm.on("user-var-changed", function(_window, _pane, name, _value)
		if name == CWD_SAVE_USER_VAR then
			checkpoint()
		end
	end)

	wezterm.on("gui-startup", function(_cmd)
		local state, warn_or_err = manager.load_session()
		if state then
			local _, restore_err = resurrect.session_state.restore(state, { spawn_pane = spawn_pane })
			if restore_err then
				wezterm.log_warn("resurrect: restore warning: " .. tostring(restore_err))
			end
		elseif warn_or_err then
			wezterm.log_warn("resurrect: load warning: " .. tostring(warn_or_err))
		end

		-- Every per-pane history lock from before this boot is necessarily
		-- orphaned (its pid can't still be running) -- sweep once up front
		-- rather than waiting for the first periodic tick.
		sweep_history()

		-- The library has no shutdown/SIGTERM hook, so a hard reboot never
		-- catches a clean final save -- this bounds how stale the restored
		-- layout can be afterward. Started once here, not at top level,
		-- because gui-startup only fires on a true cold start, never on a
		-- config reload (which would otherwise stack duplicate timers).
		local function tick()
			checkpoint()
			sweep_history()
			wezterm.time.call_after(SAVE_INTERVAL_SECONDS, tick)
		end
		wezterm.time.call_after(SAVE_INTERVAL_SECONDS, tick)
	end)

	config.keys = config.keys or {}
	table.insert(config.keys, {
		key = "S",
		mods = "ALT|SHIFT",
		action = wezterm.action_callback(function(window, _pane)
			checkpoint()
			window:toast_notification("wezterm-resurrect", "session saved", nil, 1500)
		end),
	})

	return resurrect
end
