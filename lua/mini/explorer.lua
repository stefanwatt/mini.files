local highlight = require("mini.highlight")
local utils = require("mini.utils")
local view = require("mini.view")
local buffer = require("mini.buffer")
local win = require("mini.window")
local fs = require("mini.fs")
local M = {}

-- History of explorers per root directory
M.explorer_path_history = {}

-- Register of opened explorers per tabpage
M.opened_explorers = {}

-- Explorers ------------------------------------------------------------------
---@class Explorer
---
---@field branch table Array of absolute directory paths from parent to child.
---   Its ids are called depth.
---@field depth_focus number Depth to focus.
---@field views table Views for paths. Each view is a table with:
---   - <buf_id> where to show directory content.
---   - <cursor> to position cursor; can be:
---       - `{ line, col }` table to set cursor when buffer changes window.
---       - `entry_name` string entry name to find inside directory buffer.
---   - <children_path_ids> - array with children path ids present during
---     latest directory update.
---@field windows table Array of currently opened window ids (left to right).
---@field anchor string Anchor directory of the explorer. Used as index in
---   history and for `reset()` operation.
---@field target_window number Id of window in which files will be opened.
---@field opts table Options used for this particular explorer.
---@field is_corrupted boolean Whether this particular explorer can not be
---   normalized and should be closed.
---@private
function M.new(path)
	return {
		branch = { path },
		depth_focus = 1,
		views = {},
		windows = {},
		anchor = path,
		target_window = vim.api.nvim_get_current_win(),
		opts = {},
	}
end

function M.get(tabpage_id)
	tabpage_id = tabpage_id or vim.api.nvim_get_current_tabpage()
	local res = M.opened_explorers[tabpage_id]

	if M.is_visible(res) then
		return res
	end

	M.opened_explorers[tabpage_id] = nil
	return nil
end

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
		explorer = M.explorer_path_history[path]
	end
	explorer = explorer or M.new(path)

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
	M.explorer_refresh(explorer)

	-- Register latest used path
	fs.latest_paths[vim.api.nvim_get_current_tabpage()] = path

	-- Track lost focus
	M.explorer_track_lost_focus()
	M.update_preview(explorer)

	-- Trigger appropriate event
	utils.trigger_event("MiniFilesExplorerOpen")
end

--- Close explorer
---
---@return boolean|nil Whether closing was done or `nil` if there was nothing to close.
function M.close()
	local explorer = M.get()
	if explorer == nil then
		return nil
	end

	-- Stop tracking lost focus
	pcall(vim.loop.timer_stop, utils.timers.focus)

	-- Confirm close if there is modified buffer
	if not M.confirm_modified(explorer, "close") then
		return false
	end

	-- Trigger appropriate event
	utils.trigger_event("MiniFilesExplorerClose")

	-- Focus on target window
	explorer = M.ensure_target_window(explorer)
	-- - Use `pcall()` because window might still be invalid
	pcall(vim.api.nvim_set_current_win, explorer.target_window)

	-- Update currently shown cursors
	explorer = M.update_cursors(explorer)

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
	M.explorer_path_history[anchor] = explorer
	M.opened_explorers[tabpage_id] = nil

	-- Return `true` indicating success in closing
	return true
end

function M.is_visible(explorer)
	if explorer == nil then
		return nil
	end
	for _, win_id in ipairs(explorer.windows) do
		if utils.is_valid_win(win_id) then
			return true
		end
	end
	return false
end

function M.update_preview(explorer)
	if not explorer or #explorer.windows < 3 then
		return
	end

	local middle_win = explorer.windows[2]
	local preview_win = explorer.windows[3]
	if not (utils.is_valid_win(middle_win) and utils.is_valid_win(preview_win)) then
		return
	end

	local middle_buf = vim.api.nvim_win_get_buf(middle_win)
	if not buffer.is_opened_buffer(middle_buf) then
		return
	end

	local middle_path = explorer.branch[2]
	local cursor = vim.api.nvim_win_get_cursor(middle_win)

  local validated_buf_id = buffer.validate_opened_buffer(middle_buf)
  local validated_line = buffer.validate_line(validated_buf_id, cursor[1])
	local fs_entry = fs.get_fs_entry(validated_buf_id, validated_line)

	if fs_entry then
		local preview_path = fs_entry.fs_type == "directory" and fs_entry.path or middle_path
		M.refresh_preview_window(explorer, 3, preview_win, explorer.opts.windows.width_preview, preview_path)
	end
end

function M.explorer_refresh(explorer, opts)
	explorer = M.explorer_normalize(explorer)
	if explorer.is_corrupted then
		explorer.is_corrupted = false
		M.close()
		return
	end
	if #explorer.branch == 0 then
		return
	end
	opts = opts or {}

	if not opts.skip_update_cursor then
		explorer = M.update_cursors(explorer)
	end

	if opts.force_update then
		for path, v in pairs(explorer.views) do
			view = M.view_encode_cursor(v)
			view.children_path_ids = M.buffer_update(v.buf_id, path, explorer.opts)
			explorer.views[path] = v
		end
	end

	for _, win_id in ipairs(explorer.windows) do
		local buf_id = vim.api.nvim_win_get_buf(win_id)
		M.opened_buffers[buf_id].win_id = nil
	end

	-- Always show three columns
	local total_width = vim.o.columns
	local col_width = math.floor(total_width / 3)

	-- Left column (parent or empty)
	local left_path = explorer.branch[1] or ""

	M.refresh_depth_window(explorer, 1, 1, 0, col_width, left_path)

	-- Middle column (current focus)
	local middle_path = explorer.branch[2] or ""

	M.refresh_depth_window(explorer, 2, 2, col_width, col_width, middle_path)

	-- Right column (preview)
	local right_path = explorer.branch[3] or ""

	M.refresh_preview_window(explorer, 3, col_width * 2, col_width, right_path)

	-- Always focus on the middle window
	local win_id_focused = explorer.windows[2]
	win.window_focus(win_id_focused)

	local tabpage_id = vim.api.nvim_win_get_tabpage(win_id_focused)
	M.opened_explorers[tabpage_id] = explorer

	return explorer
end

-- Add a new function to handle the preview window
function M.refresh_preview_window(explorer, win_count, win_col, win_width, preview_path)
	local views, windows, opts = explorer.views, explorer.windows, explorer.opts

	local v = views[preview_path] or {}
	v = view.view_ensure_proper(v, preview_path, opts)
	views[preview_path] = v

	local config = {
		col = win_col,
		height = win.window_get_max_height(),
		width = win_width - 1, -- Subtract 1 to prevent cut-off
		title = "Preview",
	}

	local win_id = windows[win_count]
	if not utils.is_valid_win(win_id) then
		win.window_close(win_id)
		win_id = win.window_open(v.buf_id, config)
		windows[win_count] = win_id
	end

	win.window_update(win_id, config)
	win.window_set_view(win_id, v)

	utils.trigger_event("MiniFilesWindowUpdate", { buf_id = vim.api.nvim_win_get_buf(win_id), win_id = win_id })

	explorer.views = views
	explorer.windows = windows
end

M.timers = {
  focus = vim.loop.new_timer(),
}

function M.explorer_track_lost_focus()
	local track = vim.schedule_wrap(function()
		local explorer = M.get()
		if explorer == nil then
			return
		end

		local current_win = vim.api.nvim_get_current_win()
		if vim.tbl_contains(explorer.windows, current_win) then
			return
		end

		M.close()
	end)
	M.timers.focus:start(1000, 1000, track)
end

function M.explorer_normalize(explorer)
	-- Ensure that all paths from branch are valid present paths
	local norm_branch = {}
	for _, path in ipairs(explorer.branch) do
		if not fs.does_path_exist(path) then
			break
		end
		table.insert(norm_branch, path)
	end

	local cur_max_depth = #norm_branch

	explorer.branch = norm_branch
	explorer.depth_focus = math.min(math.max(explorer.depth_focus, 1), cur_max_depth)

	-- Close all unnecessary windows
	for i = cur_max_depth + 1, #explorer.windows do
		M.window_close(explorer.windows[i])
		explorer.windows[i] = nil
	end

	-- Compute if explorer is corrupted and should not operate further
	for _, win_id in pairs(explorer.windows) do
		if not utils.is_valid_win(win_id) then
			explorer.is_corrupted = true
		end
	end

	return explorer
end

function M.explorer_sync_cursor_and_branch(explorer, depth)
	-- Compute helper data while making early returns
	if #explorer.branch < depth then
		return explorer
	end

	local path, path_to_right = explorer.branch[depth], explorer.branch[depth + 1]
	local v = explorer.views[path]
	if v == nil then
		return explorer
	end

	local buf_id, cursor = v.buf_id, v.cursor
	if cursor == nil then
		return explorer
	end

	-- Compute if path at cursor and path to the right are equal (in sync)
	local cursor_path
	if type(cursor) == "table" and utils.is_valid_buf(buf_id) then
		local l = M.get_bufline(buf_id, cursor[1])
		cursor_path = fs.path_index[utils.match_line_path_id(l)]
	elseif type(cursor) == "string" then
		cursor_path = fs.child_path(path, cursor)
	else
		return explorer
	end

	if cursor_path == path_to_right then
		return explorer
	end

	-- Trim branch if cursor path is not in sync with path to the right
	for i = depth + 1, #explorer.branch do
		explorer.branch[i] = nil
	end
	explorer.depth_focus = math.min(explorer.depth_focus, #explorer.branch)

	-- Show preview to the right of current buffer if needed
	local show_preview = explorer.opts.windows.preview
	local path_is_present = type(cursor_path) == "string" and fs.does_path_exist(cursor_path)
	local is_cur_buf = explorer.depth_focus == depth
	if show_preview and path_is_present and is_cur_buf then
		table.insert(explorer.branch, cursor_path)
	end

	return explorer
end

function M.go_in_range(explorer, buf_id, from_line, to_line)
  local validated_buf_id = buffer.validate_opened_buffer(buf_id)
  local validated_line = buffer.validate_line(validated_buf_id, from_line)
	local fs_entry = fs.get_fs_entry(validated_buf_id, validated_line)
	if fs_entry and fs_entry.fs_type == "directory" then
		explorer = M.open_directory(explorer, fs_entry.path, explorer.depth_focus + 1)
	elseif fs_entry and fs_entry.fs_type == "file" then
		explorer = M.open_file(explorer, fs_entry.path)
	end
	return explorer
end

function M.focus_on_entry(explorer, path, entry_name)
	if entry_name == nil then
		return explorer
	end

	-- Set focus on directory. Reset if it is not in current branch.
	explorer.depth_focus = M.get_path_depth(explorer, path)
	if explorer.depth_focus == nil then
		explorer.branch, explorer.depth_focus = { path }, 1
	end

	-- Set cursor on entry
	local path_view = explorer.views[path] or {}
	path_view.cursor = entry_name
	explorer.views[path] = path_view

	return explorer
end

function M.compute_fs_actions(explorer)
	-- Compute differences
	local fs_diffs = {}
	for _, v in pairs(explorer.views) do
		local dir_fs_diff = M.buffer_compute_fs_diff(v.buf_id, v.children_path_ids)
		if #dir_fs_diff > 0 then
			vim.list_extend(fs_diffs, dir_fs_diff)
		end
	end
	if #fs_diffs == 0 then
		return nil
	end

	-- Convert differences into actions
	local create, delete_map, rename, move, raw_copy = {}, {}, {}, {}, {}

	-- - Differentiate between create, delete, and copy
	for _, diff in ipairs(fs_diffs) do
		if diff.from == nil then
			table.insert(create, diff.to)
		elseif diff.to == nil then
			delete_map[diff.from] = true
		else
			table.insert(raw_copy, diff)
		end
	end

	-- - Possibly narrow down copy action into move or rename:
	--   `delete + copy` is `rename` if in same directory and `move` otherwise
	local copy = {}
	for _, diff in pairs(raw_copy) do
		if delete_map[diff.from] then
			if M.fs_get_parent(diff.from) == M.fs_get_parent(diff.to) then
				table.insert(rename, diff)
			else
				table.insert(move, diff)
			end

			-- NOTE: Can't use `delete` as array here in order for path to be moved
			-- or renamed only single time
			delete_map[diff.from] = nil
		else
			table.insert(copy, diff)
		end
	end

	return { create = create, delete = vim.tbl_keys(delete_map), copy = copy, rename = rename, move = move }
end

function M.update_cursors(explorer)
	for _, win_id in ipairs(explorer.windows) do
		if utils.is_valid_win(win_id) then
			local buf_id = vim.api.nvim_win_get_buf(win_id)
			local path = M.opened_buffers[buf_id].path
			explorer.views[path].cursor = vim.api.nvim_win_get_cursor(win_id)
		end
	end

	return explorer
end

function M.refresh_depth_window(explorer, depth, win_count, win_col, win_width, path)
	local views, windows, opts = explorer.views, explorer.windows, explorer.opts

	local v = views[path] or {}
	if path ~= "" then
		v = view.view_ensure_proper(v, path, opts)
		views[path] = v
	else
		-- Create an empty buffer for empty paths
		local buf_id = vim.api.nvim_create_buf(false, true)
		v.buf_id = buf_id
		M.opened_buffers[buf_id] = { path = "", n_modified = 0 }
	end

	local config = {
		col = win_col,
		height = win.window_get_max_height(),
		width = win_width,
		title = win_count == 1 and fs.shorten_path(fs.full_path(path)) or fs.get_basename(path),
	}

	local win_id = windows[win_count]
	if not utils.is_valid_win(win_id) then
		win.window_close(win_id)
		win_id = win.window_open(v.buf_id, config)
		windows[win_count] = win_id
	end

	win.window_update(win_id, config)
	win.window_set_view(win_id, v)

	utils.trigger_event("MiniFilesWindowUpdate", { buf_id = vim.api.nvim_win_get_buf(win_id), win_id = win_id })

	explorer.views = views
	explorer.windows = windows
end

function M.get_path_depth(explorer, path)
	for depth, depth_path in pairs(explorer.branch) do
		if path == depth_path then
			return depth
		end
	end
end

function M.confirm_modified(explorer, action_name)
	local has_modified = false
	for _, v in pairs(explorer.views) do
		if M.is_modified_buffer(v.buf_id) then
			has_modified = true
		end
	end

	-- Exit if nothing to confirm
	if not has_modified then
		return true
	end

	local msg =
		string.format("There is at least one modified buffer\n\nConfirm %s without synchronization?", action_name)
	local confirm_res = vim.fn.confirm(msg, "&Yes\n&No", 1, "Question")
	return confirm_res == 1
end

function M.open_file(explorer, path)
	explorer = M.ensure_target_window(explorer)

	-- Try to use already created buffer, if present. This avoids not needed
	-- `:edit` call and avoids some problems with auto-root from 'mini.misc'.
	local path_buf_id
	for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
		local is_target = M.is_valid_buf(buf_id)
			and vim.bo[buf_id].buflisted
			and vim.api.nvim_buf_get_name(buf_id) == path
		if is_target then
			path_buf_id = buf_id
		end
	end

	if path_buf_id ~= nil then
		vim.api.nvim_win_set_buf(explorer.target_window, path_buf_id)
	else
		-- Use relative path for a better initial view in `:buffers`
		local path_norm = vim.fn.fnameescape(vim.fn.fnamemodify(path, ":."))
		-- Use `pcall()` to avoid possible `:edit` errors, like present swap file
		pcall(vim.fn.win_execute, explorer.target_window, "edit " .. path_norm)
	end

	return explorer
end

function M.ensure_target_window(explorer)
	if not utils.is_valid_win(explorer.target_window) then
		explorer.target_window = M.get_first_valid_normal_window()
	end
	return explorer
end

function M.open_directory(explorer, path, target_depth)
	explorer.depth_focus = 2 -- Always keep focus on middle column
	explorer.branch = { M.fs_get_parent(path) or "", path, "" }
	return explorer
end

function M.open_root_parent(explorer)
	local root = explorer.branch[1]
	local root_parent = M.fs_get_parent(root)
	if root_parent == nil then
		return explorer
	end

	-- Update branch data
	table.insert(explorer.branch, 1, root_parent)

	-- Focus on previous root entry in its parent
	return M.focus_on_entry(explorer, root_parent, M.fs_get_basename(root))
end

function M.trim_branch_right(explorer)
	for i = explorer.depth_focus + 1, #explorer.branch do
		explorer.branch[i] = nil
	end
	return explorer
end

function M.trim_branch_left(explorer)
	local new_branch = {}
	for i = explorer.depth_focus, #explorer.branch do
		table.insert(new_branch, explorer.branch[i])
	end
	explorer.branch = new_branch
	explorer.depth_focus = 1
	return explorer
end

function M.explorer_show_help(explorer_buf_id, explorer_win_id)
	-- Compute lines
	local buf_mappings = vim.api.nvim_buf_get_keymap(explorer_buf_id, "n")
	local map_data, desc_width = {}, 0
	for _, data in ipairs(buf_mappings) do
		if data.desc ~= nil then
			map_data[data.desc] = data.lhs:lower() == "<lt>" and "<" or data.lhs
			desc_width = math.max(desc_width, data.desc:len())
		end
	end

	local desc_arr = vim.tbl_keys(map_data)
	table.sort(desc_arr)
	local map_format = string.format("%%-%ds │ %%s", desc_width)

	local lines = { "Buffer mappings:", "" }
	for _, desc in ipairs(desc_arr) do
		table.insert(lines, string.format(map_format, desc, map_data[desc]))
	end
	table.insert(lines, "")
	table.insert(lines, "(Press `q` to close)")

	-- Create buffer
	local buf_id = vim.api.nvim_create_buf(false, true)
	M.set_buflines(buf_id, lines)

	vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf_id, desc = "Close this window" })

	vim.b[buf_id].minicursorword_disable = true
	vim.b[buf_id].miniindentscope_disable = true

	vim.bo[buf_id].filetype = "minifiles-help"

	-- Compute window data
	local line_widths = vim.tbl_map(vim.fn.strdisplaywidth, lines)
	local max_line_width = math.max(unpack(line_widths))

	local config = vim.api.nvim_win_get_config(explorer_win_id)
	config.relative = "win"
	config.row = 0
	config.col = 0
	config.width = max_line_width
	config.height = #lines
	-- config.height = H.window_get_max_height()
	config.title = vim.fn.has("nvim-0.9") == 1 and [['mini.files' help]] or nil
	config.zindex = config.zindex + 1
	config.style = "minimal"

	-- Open window
	local win_id = vim.api.nvim_open_win(buf_id, false, config)
	highlight.window_update_highlight(win_id, "NormalFloat", "MiniFilesNormal")
	highlight.window_update_highlight(win_id, "FloatTitle", "MiniFilesTitle")
	highlight.window_update_highlight(win_id, "CursorLine", "MiniFilesCursorLine")
	vim.wo[win_id].cursorline = true

	vim.api.nvim_set_current_win(win_id)
	return win_id
end

function M.compute_visible_depth_range(explorer, opts)
	return { from = 1, to = 2 } -- Always show 2 navigation columns
end

--- Set target window
---
---@param win_id number Window identifier inside which file will be opened.
function M.set_target_window(win_id)
	if not utils.is_valid_win(win_id) then
		utils.error("`win_id` should be valid window identifier.")
	end

	local explorer = M.get()
	if explorer == nil then
		return
	end

	explorer.target_window = win_id
end

--- Refresh explorer
---
--- Notes:
--- - If in `opts` at least one of `content` entry is not `nil`, all directory
---   buffers are forced to update.
---
---@param opts table|nil Table of options to update.
function M.refresh(opts)
	local explorer = M.get()
	if explorer == nil then
		return
	end

	-- Decide whether buffers should be forcefully updated
	local content_opts = (opts or {}).content or {}
	local force_update = #vim.tbl_keys(content_opts) > 0

	-- Confirm refresh if there is modified buffer
	if force_update then
		force_update = M.confirm_modified(explorer, "buffer updates")
	end

	-- Respect explorer local options supplied inside its `open()` call but give
	-- current `opts` higher precedence
	explorer.opts = utils.normalize_opts(explorer.opts, opts)

	M.explorer_refresh(explorer, { force_update = force_update })
end

--- Synchronize explorer
---
--- - Parse user edits in directory buffers.
--- - Convert edits to file system actions and apply them after confirmation.
--- - Update all directory buffers with the most relevant file system information.
---   Can be used without user edits to account for external file system changes.
function M.synchronize()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	-- Parse and apply file system operations
	local fs_actions = M.compute_fs_actions(explorer)
	if fs_actions ~= nil and fs.actions_confirm(fs_actions) then
		fs.actions_apply(fs_actions, explorer.opts)
	end

	M.explorer_refresh(explorer, { force_update = true })
end

--- Reset explorer
---
--- - Show single window focused on anchor directory (which was used as first
---   argument for |M.open()|).
--- - Reset all tracked directory cursors to point at first entry.
function M.reset()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	-- Reset branch
	explorer.branch = { explorer.anchor }
	explorer.depth_focus = 1

	-- Reset views
	for _, v in pairs(explorer.views) do
		v.cursor = { 1, 0 }
	end

	-- Skip update cursors, as they are already set
	M.explorer_refresh(explorer, { skip_update_cursor = true })
end

--- Go in entry under cursor
---
--- Depends on entry under cursor:
--- - If directory, focus on it in the window to the right.
--- - If file, open it in the window which was current during |M.open()|.
---   Explorer is not closed after that.
---
---@param opts Options. Possible fields:
---   - <close_on_file> `(boolean)` - whether to close explorer after going
---     inside a file. Powers the `go_in_plus` mapping.
---     Default: `false`.
function M.go_in(opts)
	local explorer = M.get()
	if explorer == nil then
		return
	end

	opts = vim.tbl_deep_extend("force", { close_on_file = false }, opts or {})

	local should_close = opts.close_on_file
	if should_close then
		local fs_entry = fs.get_fs_entry()
		should_close = fs_entry ~= nil and fs_entry.fs_type == "file"
	end

	local cur_line = vim.fn.line(".")
	explorer = M.go_in_range(explorer, vim.api.nvim_get_current_buf(), cur_line, cur_line)

	-- Always keep focus in the middle column
	explorer.depth_focus = 2

	-- Update the branch
	local new_path = explorer.branch[explorer.depth_focus]
	explorer.branch = { fs.get_parent(new_path) or "", new_path, "" }

	M.explorer_refresh(explorer)
	M.update_preview(explorer)
	if should_close then
		M.close()
	end
end

--- Go out to parent directory
---
--- - Focus on window to the left showing parent of current directory.
function M.go_out()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	-- Get the new parent directory
	local new_parent = fs.get_parent(explorer.branch[1]) or ""

	-- Update the branch
	if new_parent ~= "" then
		table.insert(explorer.branch, 1, new_parent)
		if #explorer.branch > 3 then
			table.remove(explorer.branch)
		end
	else
		return
	end

	-- Always keep focus on the middle column
	explorer.depth_focus = 2

	-- Make sure the views are properly initialized for all paths in the branch
	for i, path in ipairs(explorer.branch) do
		if path ~= "" and not explorer.views[path] then
			explorer.views[path] = view.view_ensure_proper({}, path, explorer.opts)
		end
	end

	local refreshed_explorer = M.explorer_refresh(explorer)

	-- Ensure the explorer is still registered as open
	local tabpage_id = vim.api.nvim_get_current_tabpage()
	utils.opened_explorers[tabpage_id] = refreshed_explorer or explorer
	utils.update_preview(explorer)
end
--- Trim left part of branch
---
--- - Remove all branch paths to the left of currently focused one. This also
---   results into current window becoming the most left one.
function M.trim_left()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	explorer = M.trim_branch_left(explorer)
	M.explorer_refresh(explorer)
end

--- Trim right part of branch
---
--- - Remove all branch paths to the right of currently focused one. This also
---   results into current window becoming the most right one.
function M.trim_right()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	explorer = M.trim_branch_right(explorer)
	M.explorer_refresh(explorer)
end

--- Reveal current working directory
---
--- - Prepend branch with parent paths until current working directory is reached.
---   Do nothing if not inside it.
function M.reveal_cwd()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	local cwd = fs.full_path(vim.fn.getcwd())
	local cwd_ancestor_pattern = string.format("^%s/.", vim.pesc(cwd))
	while explorer.branch[1]:find(cwd_ancestor_pattern) ~= nil do
		-- Add parent to branch
		local parent, name = fs.get_parent(explorer.branch[1]), fs.get_basename(explorer.branch[1])
		if parent ~= nil then
			table.insert(explorer.branch, 1, parent)

			explorer.depth_focus = explorer.depth_focus + 1

			-- Set cursor on child entry
			local parent_view = explorer.views[parent] or {}
			parent_view.cursor = name
			explorer.views[parent] = parent_view
		end
	end

	M.explorer_refresh(explorer)
end

--- Show help window
---
--- - Open window with helpful information about currently shown explorer and
---   focus on it. To close it, press `q`.
function M.show_help()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	local buf_id = vim.api.nvim_get_current_buf()
	if not utils.is_opened_buffer(buf_id) then
		return
	end

	M.explorer_show_help(buf_id, vim.api.nvim_get_current_win())
end

--- Get target window
---
---@return number|nil Window identifier inside which file will be opened or
---   `nil` if no explorer is opened.
function M.get_target_window()
	local explorer = M.get()
	if explorer == nil then
		return
	end

	explorer = M.ensure_target_window(explorer)
	return explorer.target_window
end

function M.go_in_with_count()
	for _ = 1, vim.v.count1 do
		M.go_in({})
	end
end

function M.go_in_plus ()
	for _ = 1, vim.v.count1 do
		M.go_in({ close_on_file = true })
	end
end

function M.go_out_with_count ()
	for _ = 1, vim.v.count1 do
		M.go_out()
	end
end

function M.go_out_plus ()
	M.go_out_with_count()
	M.trim_right()
end

return M
