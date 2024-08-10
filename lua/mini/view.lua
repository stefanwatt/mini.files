local buffer    = require("mini.buffer")
local win    = require("mini.window")
local highlight = require("mini.highlight")
local utils     = require("mini.utils")
local M         = {}

---@alias RefreshExplorerFun fun(explorer: Explorer, opts: ExplorerOpts)
---@alias SyncCursorFun fun(explorer: Explorer, depth: number)

---@class MiniFilesViewEventListeners 
 ---@field refresh_explorer RefreshExplorerFun
M.event_listeners = {}

---@param event "refresh_explorer" | "sync_cursor"
---@param callback RefreshExplorerFun | SyncCursorFun
function M.add_event_listener(event, callback)
	--TODO: should we allow to register more than one cb for a given event?
	M.event_listeners[event] = callback
end

function M.ensure_proper(view, path, explorer)
	-- Ensure proper buffer
	if not utils.is_valid_buf(view.buf_id) then
		buffer.buffer_delete(view.buf_id)
		local function track_cursor(data)
			M.track_cursor(explorer,data)
		end
		buffer.add_event_listener('track_cursor', track_cursor)
		view.buf_id = buffer.buffer_create(path)
		-- Make sure that pressing `u` in new buffer does nothing
		local cache_undolevels = vim.bo[view.buf_id].undolevels
		vim.bo[view.buf_id].undolevels = -1
		view.children_path_ids = buffer.buffer_update(view.buf_id, path, explorer.opts)
		vim.bo[view.buf_id].undolevels = cache_undolevels
	end

	-- Ensure proper cursor. If string, find it as line in current buffer.
	view.cursor = view.cursor or { 1, 0 }
	if type(view.cursor) == "string" then
		view = M.decode_cursor(view)
	end

	return view
end

function M.encode_cursor(view)
	local buf_id, cursor = view.buf_id, view.cursor
	if not utils.is_valid_buf(buf_id) or type(cursor) ~= "table" then
		return view
	end

	-- Replace exact cursor coordinates with entry name to try and find later.
	-- This allows more robust opening explorer from history (as directory
	-- content may have changed and exact cursor position would be not valid).
	local l = utils.get_bufline(buf_id, cursor[1])
	view.cursor = utils.match_line_entry_name(l)
	return view
end

function M.decode_cursor(view)
	local buf_id, cursor = view.buf_id, view.cursor
	if not utils.is_valid_buf(buf_id) or type(cursor) ~= "string" then
		return view
	end

	-- Find entry name named as stored in `cursor`. If not - use {1, 0}.
	local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
	for i, l in ipairs(lines) do
		if cursor == utils.match_line_entry_name(l) then
			view.cursor = { i, 0 }
		end
	end

	if type(view.cursor) ~= "table" then
		view.cursor = { 1, 0 }
	end

	return view
end

function M.invalidate_buffer(view)
	buffer.buffer_delete(view.buf_id)
	view.buf_id = nil
	view.children_path_ids = nil
	return view
end

---@param explorer Explorer
---@param data CursorChangedData
M.track_cursor = vim.schedule_wrap(function(explorer, data)
	-- Schedule this in order to react *after* all pending changes are applied
	local buf_id = data.buf
	local buf_data = require("mini.buffer").opened_buffers[buf_id]
	if buf_data == nil then
		return
	end

	local win_id = buf_data.win_id
	if not utils.is_valid_win(win_id) then
		return
	end

	-- Ensure cursor doesn't go over path id and icon
	local cur_cursor = win.tweak_cursor(win_id, buf_id)

	-- Ensure cursor line doesn't contradict window on the right
	local tabpage_id = vim.api.nvim_win_get_tabpage(win_id)
	if explorer == nil then
		return
	end

	local buf_depth = utils.get_path_depth(explorer.branch, buf_data.path)
	if buf_depth == nil then
		return
	end

	-- Update cursor in view and sync it with branch
	local view = explorer.views[buf_data.path]
	if view ~= nil then
		view.cursor = cur_cursor
		explorer.views[buf_data.path] = view
	end

	explorer = M.event_listeners['sync_cursor'](explorer, buf_depth)

	-- Don't trigger redundant window update events
	require("mini.utils").block_event_trigger["MiniFilesWindowUpdate"] = true
	M.event_listeners["refresh_explorer"](explorer, explorer.opts)
	require("mini.utils").block_event_trigger["MiniFilesWindowUpdate"] = false
end)



---@param data TextChangedData
function M.track_text_change(data)
	-- Track 'modified'
	local buf_id = data.buf
	local opened_buffers = require("mini.buffer").opened_buffers
	local new_n_modified = opened_buffers[buf_id].n_modified + 1
	opened_buffers[buf_id].n_modified = new_n_modified
	local win_id = opened_buffers[buf_id].win_id
	if new_n_modified > 0 and utils.is_valid_win(win_id) then
		local buffer_opened = buffer.is_opened_buffer(buf_id)
		local buffer_modified = buffer.is_modified_buffer(buf_id)
		highlight.window_update_border_hl(win_id, buffer_opened, buffer_modified)
	end

	-- Track window height
	if not utils.is_valid_win(win_id) then
		return
	end

	--TODO: not sure if this is neede
	-- Ensure that only buffer lines are shown. This can be not the case if after
	-- text edit cursor moved past previous last line.
	-- local n_lines = vim.api.nvim_buf_line_count(buf_id)
	-- local height = win.window_get_max_height()
	-- local last_visible_line = vim.fn.line("w0", win_id) + height - 1
	-- local out_of_buf_lines = last_visible_line - n_lines
	-- -- - Possibly scroll window upward (`\25` is an escaped `<C-y>`)
	-- if out_of_buf_lines > 0 then
	-- 	vim.cmd("normal! " .. out_of_buf_lines .. "\25")
	-- end
end

return M
