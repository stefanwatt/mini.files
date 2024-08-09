local highlight = require("mini.highlight")
local utils = require("mini.utils")
local fs = require("mini.fs")
local M = {}

-- Register of opened buffer data for quick access. Tables per buffer id:
-- - <path> - path which contents this buffer displays.
-- - <win_id> - id of window this buffer is shown. Can be `nil`.
-- - <n_modified> - number of modifications since last update from this module.
--   Values bigger than 0 can be treated as if buffer was modified by user.
--   It uses number instead of boolean to overcome `TextChanged` event on
--   initial `buf_set_lines` (`noautocmd` doesn't quick work for this event).
M.opened_buffers = {}

function M.buffer_create(path, mappings)
	-- Create buffer
	local buf_id = vim.api.nvim_create_buf(false, true)

	-- Register buffer
	M.opened_buffers[buf_id] = { path = path }

	-- Make buffer mappings
	-- M.buffer_make_mappings(buf_id, mappings)

	-- Make buffer autocommands
	local augroup = vim.api.nvim_create_augroup("MiniFiles", { clear = false })
	local au = function(events, desc, callback)
		vim.api.nvim_create_autocmd(events, { group = augroup, buffer = buf_id, desc = desc, callback = callback })
	end

	-- TODO: circular dependency buffer <-> view
	-- au({ "CursorMoved", "CursorMovedI" }, "Tweak cursor position", M.view_track_cursor)
	-- au({ "TextChanged", "TextChangedI", "TextChangedP" }, "Track buffer modification", M.view_track_text_change)
	--
	-- Tweak buffer to be used nicely with other 'mini.nvim' modules
	vim.b[buf_id].minicursorword_disable = true

	-- Set buffer options
	vim.bo[buf_id].filetype = "minifiles"

	-- Trigger dedicated event
	utils.trigger_event("MiniFilesBufferCreate", { buf_id = buf_id })

	return buf_id
end

function M.buffer_update(buf_id, path, opts)
	if not (utils.is_valid_buf(buf_id) and fs.does_path_exist(path)) then
		return
	end

	-- Perform entry type specific updates
	local update_fun = fs.get_type(path) == "directory" and M.buffer_update_directory or M.buffer_update_file
	local fs_entries = update_fun(buf_id, path, opts)

	-- Trigger dedicated event
	utils.trigger_event("MiniFilesBufferUpdate", { buf_id = buf_id, win_id = M.opened_buffers[buf_id].win_id })

	-- Reset buffer as not modified
	M.opened_buffers[buf_id].n_modified = -1

	-- Return array with children entries path ids for future synchronization
	return vim.tbl_map(function(x)
		return x.path_id
	end, fs_entries)
end

function M.buffer_update_directory(buf_id, path, opts)
	local lines, icon_hl, name_hl = {}, {}, {}

	-- Compute lines
	-- buffer module should maybe not have a dependency on fs
	local fs_entries = fs.read_dir(path, opts.content)

	-- - Compute format expression resulting into same width path ids
	local path_width = math.floor(math.log10(#fs.path_index)) + 1
	local line_format = "/%0" .. path_width .. "d/%s/%s"

	local prefix_fun = opts.content.prefix
	for _, entry in ipairs(fs_entries) do
		local prefix, hl = prefix_fun(entry)
		prefix, hl = prefix or "", hl or ""
		table.insert(lines, string.format(line_format, fs.path_index[entry.path], prefix, entry.name))
		table.insert(icon_hl, hl)
		table.insert(name_hl, entry.fs_type == "directory" and "MiniFilesDirectory" or "MiniFilesFile")
	end

	-- Set lines
	utils.set_buflines(buf_id, lines)
	highlight.add_highlights(buf_id, lines, icon_hl, name_hl)

	return fs_entries
end

function M.buffer_update_file(buf_id, path, opts)
	-- Determine if file is text. This is not 100% proof, but good enough.
	-- Source: https://github.com/sharkdp/content_inspector
	local fd = vim.loop.fs_open(path, "r", 1)
	if fd == nil then
		utils.error("file or directory not found: " .. path)
		return
	end
	local is_text = vim.loop.fs_read(fd, 1024):find("\0") == nil
	vim.loop.fs_close(fd)
	if not is_text then
		utils.set_buflines(buf_id, { "-Non-text-file" .. string.rep("-", opts.windows.width_preview) })
		return {}
	end

	-- Compute lines. Limit number of read lines to work better on large files.
	local has_lines, read_res = pcall(vim.fn.readfile, path, "", vim.o.lines)
	-- - Make sure that lines don't contain '\n' (might happen in binary files).
	local lines = has_lines and vim.split(table.concat(read_res, "\n"), "\n") or {}

	-- Set lines
	utils.set_buflines(buf_id, lines)

	-- Add highlighting if reasonable (for performance or functionality reasons)
	if highlight.buffer_should_highlight(buf_id) then
		local ft = vim.filetype.match({ buf = buf_id, filename = path })
    if not ft then
      utils.error("could not determine filetype of path: " .. path)
      return
    end
		local has_lang, lang = pcall(vim.treesitter.language.get_lang, ft)
		local has_ts, _ = pcall(vim.treesitter.start, buf_id, has_lang and lang or ft)
		if not has_ts then
			vim.bo[buf_id].syntax = ft
		end
	end

	return {}
end

function M.buffer_delete(buf_id)
	if buf_id == nil then
		return
	end
	pcall(vim.api.nvim_buf_delete, buf_id, { force = true })
	M.opened_buffers[buf_id] = nil
end

function M.buffer_compute_fs_diff(buf_id, ref_path_ids)
	if not M.is_modified_buffer(buf_id) then
		return {}
	end

	local path = M.opened_buffers[buf_id].path
	local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
	local res, present_path_ids = {}, {}

	-- Process present file system entries
	for _, l in ipairs(lines) do
		local path_id = M.match_line_path_id(l)
		local path_from = M.path_index[path_id]

		-- Use whole line as name if no path id is detected
		local name_to = path_id ~= nil and l:sub(M.match_line_offset(l)) or l

		-- Preserve trailing '/' to distinguish between creating file or directory
		local path_to = fs.child_path(path, name_to) .. (vim.endswith(name_to, "/") and "/" or "")

		-- Ignore blank lines and already synced entries (even several user-copied)
		if l:find("^%s*$") == nil and path_from ~= path_to then
			table.insert(res, { from = path_from, to = path_to })
		elseif path_id ~= nil then
			present_path_ids[path_id] = true
		end
	end

	-- Detect missing file system entries
	for _, ref_id in ipairs(ref_path_ids) do
		if not present_path_ids[ref_id] then
			table.insert(res, { from = M.path_index[ref_id], to = nil })
		end
	end

	return res
end

function M.is_opened_buffer(buf_id)
	return M.opened_buffers[buf_id] ~= nil
end

function M.is_modified_buffer(buf_id)
	local data = M.opened_buffers[buf_id]
	return data ~= nil and data.n_modified and data.n_modified > 0
end

function M.rename_loaded_buffer(buf_id, from, to)
	if not (vim.api.nvim_buf_is_loaded(buf_id) and vim.bo[buf_id].buftype == "") then
		return
	end
	-- Make sure buffer name is normalized (same as `from` and `to`)
	local cur_name = fs.normalize_path(vim.api.nvim_buf_get_name(buf_id))

	-- Use `gsub('^' ...)` to also take into account directory renames
	local new_name = cur_name:gsub("^" .. vim.pesc(from), to)
	if cur_name == new_name then
		return
	end
	vim.api.nvim_buf_set_name(buf_id, new_name)

	-- Force write to avoid the 'overwrite existing file' error message on write
	-- for normal files
	vim.api.nvim_buf_call(buf_id, function()
		vim.cmd("silent! write! | edit")
	end)
end

function M.validate_opened_buffer(x)
	if x == nil or x == 0 then
		x = vim.api.nvim_get_current_buf()
	end
	if not M.is_opened_buffer(x) then
		M.error("`buf_id` should be an identifier of an opened directory buffer.")
	end
	return x
end

function M.validate_line(buf_id, x)
	x = x or vim.fn.line(".")
	if not (type(x) == "number" and 1 <= x and x <= vim.api.nvim_buf_line_count(buf_id)) then
		M.error("`line` should be a valid line number in buffer " .. buf_id .. ".")
	end
	return x
end

return M
