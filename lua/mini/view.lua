local buffer = require("lua.mini.buffer")
local highlight = require("lua.mini.highlight")
local utils     = require("lua.mini.utils")
local M = {}

function M.view_ensure_proper(view, path, opts)
	-- Ensure proper buffer
	if not M.is_valid_buf(view.buf_id) then
		M.buffer_delete(view.buf_id)
		view.buf_id = M.buffer_create(path, opts.mappings)
		-- Make sure that pressing `u` in new buffer does nothing
		local cache_undolevels = vim.bo[view.buf_id].undolevels
		vim.bo[view.buf_id].undolevels = -1
		view.children_path_ids = M.buffer_update(view.buf_id, path, opts)
		vim.bo[view.buf_id].undolevels = cache_undolevels
	end

	-- Ensure proper cursor. If string, find it as line in current buffer.
	view.cursor = view.cursor or { 1, 0 }
	if type(view.cursor) == "string" then
		view = M.view_decode_cursor(view)
	end

	return view
end

function M.view_encode_cursor(view)
	local buf_id, cursor = view.buf_id, view.cursor
	if not M.is_valid_buf(buf_id) or type(cursor) ~= "table" then
		return view
	end

	-- Replace exact cursor coordinates with entry name to try and find later.
	-- This allows more robust opening explorer from history (as directory
	-- content may have changed and exact cursor position would be not valid).
	local l = M.get_bufline(buf_id, cursor[1])
	view.cursor = M.match_line_entry_name(l)
	return view
end

function M.view_decode_cursor(view)
	local buf_id, cursor = view.buf_id, view.cursor
	if not M.is_valid_buf(buf_id) or type(cursor) ~= "string" then
		return view
	end

	-- Find entry name named as stored in `cursor`. If not - use {1, 0}.
	local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
	for i, l in ipairs(lines) do
		if cursor == M.match_line_entry_name(l) then
			view.cursor = { i, 0 }
		end
	end

	if type(view.cursor) ~= "table" then
		view.cursor = { 1, 0 }
	end

	return view
end

function M.view_invalidate_buffer(view)
	M.buffer_delete(view.buf_id)
	view.buf_id = nil
	view.children_path_ids = nil
	return view
end

M.view_track_cursor = vim.schedule_wrap(function(data)
	-- Schedule this in order to react *after* all pending changes are applied
	local buf_id = data.buf
	local buf_data = M.opened_buffers[buf_id]
	if buf_data == nil then
		return
	end

	local win_id = buf_data.win_id
	if not M.is_valid_win(win_id) then
		return
	end

	-- Ensure cursor doesn't go over path id and icon
	local cur_cursor = M.window_tweak_cursor(win_id, buf_id)

	-- Ensure cursor line doesn't contradict window on the right
	local tabpage_id = vim.api.nvim_win_get_tabpage(win_id)
	local explorer = M.explorer_get(tabpage_id)
	if explorer == nil then
		return
	end

	local buf_depth = M.explorer_get_path_depth(explorer, buf_data.path)
	if buf_depth == nil then
		return
	end

	-- Update cursor in view and sync it with branch
	local view = explorer.views[buf_data.path]
	if view ~= nil then
		view.cursor = cur_cursor
		explorer.views[buf_data.path] = view
	end

	explorer = M.explorer_sync_cursor_and_branch(explorer, buf_depth)

	-- Don't trigger redundant window update events
	M.block_event_trigger["MiniFilesWindowUpdate"] = true
	M.explorer_refresh(explorer)
	M.block_event_trigger["MiniFilesWindowUpdate"] = false
end)

function M.view_track_text_change(data)
	-- Track 'modified'
	local buf_id = data.buf
	local new_n_modified = M.opened_buffers[buf_id].n_modified + 1
	M.opened_buffers[buf_id].n_modified = new_n_modified
	local win_id = M.opened_buffers[buf_id].win_id
	if new_n_modified > 0 and utils.is_valid_win(win_id) then
    local buffer_opened = buffer.is_opened_buffer(buf_id)
    local buffer_modified = buffer.is_modified_buffer(buf_id)
		highlight.window_update_border_hl(win_id, buffer_opened, buffer_modified)
	end

	-- Track window height
	if not M.is_valid_win(win_id) then
		return
	end

	local n_lines = vim.api.nvim_buf_line_count(buf_id)
	-- local height = math.min(n_lines, H.window_get_max_height())
	local height = M.window_get_max_height()
	vim.api.nvim_win_set_height(win_id, height)

	-- Ensure that only buffer lines are shown. This can be not the case if after
	-- text edit cursor moved past previous last line.
	local last_visible_line = vim.fn.line("w0", win_id) + height - 1
	local out_of_buf_lines = last_visible_line - n_lines
	-- - Possibly scroll window upward (`\25` is an escaped `<C-y>`)
	if out_of_buf_lines > 0 then
		vim.cmd("normal! " .. out_of_buf_lines .. "\25")
	end
end

return M
