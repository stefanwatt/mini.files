local utils = require("lua.mini.utils")
local M = {}

M.ns_id = {
	highlight = vim.api.nvim_create_namespace("MiniFilesHighlight"),
}

function M.window_update_highlight(win_id, new_from, new_to)
	local new_entry = new_from .. ":" .. new_to
	local replace_pattern = string.format("(%s:[^,]*)", vim.pesc(new_from))
	local new_winhighlight, n_replace = vim.wo[win_id].winhighlight:gsub(replace_pattern, new_entry)
	if n_replace == 0 then
		new_winhighlight = new_winhighlight .. "," .. new_entry
	end

	vim.wo[win_id].winhighlight = new_winhighlight
end

function M.buffer_should_highlight(buf_id)
	-- Highlight if buffer size is not too big, both in total and per line
	local buf_size = vim.api.nvim_buf_call(buf_id, function()
		return vim.fn.line2byte(vim.fn.line("$") + 1)
	end)
	return buf_size <= 1000000 and buf_size <= 1000 * vim.api.nvim_buf_line_count(buf_id)
end

function M.create_default_hl()
	local hi = function(name, opts)
		opts.default = true
		vim.api.nvim_set_hl(0, name, opts)
	end

	hi("MiniFilesBorder", { link = "FloatBorder" })
	hi("MiniFilesBorderModified", { link = "DiagnosticFloatingWarn" })
	hi("MiniFilesCursorLine", { link = "CursorLine" })
	hi("MiniFilesDirectory", { link = "Directory" })
	hi("MiniFilesFile", {})
	hi("MiniFilesNormal", { link = "NormalFloat" })
	hi("MiniFilesTitle", { link = "FloatTitle" })
	hi("MiniFilesTitleFocused", { link = "FloatTitle" })
end

---@param win_id number
function M.window_update_border_hl(win_id, buffer_opened, buffer_modified)
	local buf_id = vim.api.nvim_win_get_buf(win_id)
	-- Check if the buffer is valid and opened before checking if it's modified
	-- TODO: probably can refactor further and do the checks outside
	if utils.is_valid_buf(buf_id) and buffer_opened then
		local border_hl = buffer_modified and "MiniFilesBorderModified" or "MiniFilesBorder"
		M.window_update_highlight(win_id, "FloatBorder", border_hl)
	end
end

---@param buf_id number
---@param lines string[]
---@param icon_hl string[]
---@param name_hl string[]
function M.add_highlights(buf_id, lines, icon_hl, name_hl)
	local ns_id = M.ns_id.highlight
	vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)

	local set_hl = function(line, col, hl_opts)
		M.set_extmark(buf_id, ns_id, line, col, hl_opts)
	end

	for i, l in ipairs(lines) do
		local icon_start, name_start = l:match("^/%d+/().-()/")

		-- NOTE: Use `right_gravity = false` for persistent highlights during edit
		local icon_opts = { hl_group = icon_hl[i], end_col = name_start - 1, right_gravity = false }
		set_hl(i - 1, icon_start - 1, icon_opts)

		local name_opts = { hl_group = name_hl[i], end_row = i, end_col = 0, right_gravity = false }
		set_hl(i - 1, name_start - 1, name_opts)
	end
end

return M
