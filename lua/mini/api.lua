local utils = require("lua.mini.utils")
local fs = require("lua.mini.fs")
local xp = require("lua.mini.explorer")
local win = require("lua.mini.window")
local view = require("lua.mini.view")

local M = {}

---@param path string|nil A valid file system path used as anchor.
---   If it is a path to directory, used directly.
---   If it is a path to file, its parent directory is used as anchor while
---   explorer will focus on the supplied file.
---   Default: path of |current-directory|.
---@param use_latest boolean|nil Whether to load explorer state from history
---   (based on the supplied anchor path). Default: `true`.
---@param opts table|nil Table of options overriding |M.config| and
---   `vim.b.minifiles_config` for this particular explorer session.
function M.open(path, use_latest, opts)
	-- Validate path: allow only valid file system path
	path = fs.full_path(path or vim.fn.getcwd())

	local fs_type = fs.get_type(path)
	if fs_type == nil then
		utils.error('`path` is not a valid path ("' .. path .. '")')
	end

	-- Validate rest of the arguments
	if use_latest == nil then
		use_latest = true
	end

	-- Properly close possibly opened in the tabpage explorer
	local did_close = M.close()
	if did_close == false then
		return
	end

	-- Get explorer to open
	local explorer
	if use_latest then
		explorer = xp.explorer_path_history[path]
	end
	explorer = explorer or xp.explorer_new(path)

	-- Update explorer data. Don't use current explorer's data to allow more
	-- interactive config change by modifying global/local configs.
	explorer.opts = utils.normalize_opts(nil, opts)
	explorer.target_window = vim.api.nvim_get_current_win()

	-- Adjust the initial view based on whether it's a file or directory
	if fs_type == "file" then
		local parent = fs.get_parent(path)
		explorer.branch = { fs.get_parent(parent) or "", parent, path }
	else
		explorer.branch = { fs.get_parent(path) or "", path, "" }
	end
	explorer.depth_focus = 2 -- Always focus on the middle column

	-- Refresh and register as opened
	xp.explorer_refresh(explorer)

	-- Register latest used path
	fs.latest_paths[vim.api.nvim_get_current_tabpage()] = path

	-- Track lost focus
	xp.explorer_track_lost_focus()
	xp.update_preview(explorer)

	-- Trigger appropriate event
	utils.trigger_event("MiniFilesExplorerOpen")
end

--- Close explorer
---
---@return boolean|nil Whether closing was done or `nil` if there was nothing to close.
function M.close()
	local explorer = xp.explorer_get()
	if explorer == nil then
		return nil
	end

	-- Stop tracking lost focus
	pcall(vim.loop.timer_stop, utils.timers.focus)

	-- Confirm close if there is modified buffer
	if not xp.explorer_confirm_modified(explorer, "close") then
		return false
	end

	-- Trigger appropriate event
	utils.trigger_event("MiniFilesExplorerClose")

	-- Focus on target window
	explorer = xp.explorer_ensure_target_window(explorer)
	-- - Use `pcall()` because window might still be invalid
	pcall(vim.api.nvim_set_current_win, explorer.target_window)

	-- Update currently shown cursors
	explorer = xp.explorer_update_cursors(explorer)

	-- Close shown explorer windows
	for i, win_id in pairs(explorer.windows) do
		win.window_close(win_id)
		explorer.windows[i] = nil
	end

	-- Close possibly visible help window
	for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf_id = vim.api.nvim_win_get_buf(win_id)
		if vim.bo[buf_id].filetype == "minifiles-help" then
			vim.api.nvim_win_close(win_id, true)
		end
	end

	-- Invalidate views
	for path, v in pairs(explorer.views) do
		explorer.views[path] = view.view_invalidate_buffer(view.view_encode_cursor(v))
	end

	-- Update histories and unmark as opened
	local tabpage_id, anchor = vim.api.nvim_get_current_tabpage(), explorer.anchor
	xp.explorer_path_history[anchor] = explorer
	xp.opened_explorers[tabpage_id] = nil

	-- Return `true` indicating success in closing
	return true
end

return M
