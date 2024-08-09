local c = require("mini.config")

local M = {}

-- Namespaces

-- File system information
M.is_windows = vim.loop.os_uname().sysname == 'Windows_NT'

-- Register table to decide whether certain autocmd events should be triggered
M.block_event_trigger = {}

local augroup = vim.api.nvim_create_augroup('MiniFiles', {})
function M.au(event, pattern, callback, desc)
  vim.api.nvim_create_autocmd(event, { group = augroup, pattern = pattern, callback = callback, desc = desc })
end


---@return boolean Always `true`.
function M.default_filter(fs_entry)
	return true
end
--- Default filter of file system entries
---
--- Currently does not filter anything out.
---
---@param fs_entry table Table with the following fields:
--- __minifiles_fs_entry_data_fields
---

--- Default prefix of file system entries
---
--- - If |MiniIcons| is set up, use |MiniIcons.get()| for "directory"/"file" category.
--- - Otherwise:
---     - For directory return fixed icon and "MiniFilesDirectory" group name.
---     - For file try to use `get_icon()` from 'nvim-tree/nvim-web-devicons'.
---       If missing, return fixed icon and 'MiniFilesFile' group name.
---
---@param fs_entry table Table with the following fields:
--- __minifiles_fs_entry_data_fields
---
---@return ... Icon and highlight group name. For more details, see |M.config|
---   and |MiniFiles-examples|.
function M.default_prefix(fs_entry)
	-- Prefer 'mini.icons'
  -- TODO: get rid of global bs
	if _G.MiniIcons ~= nil then
		local category = fs_entry.fs_type == "directory" and "directory" or "file"
		local icon, hl = _G.MiniIcons.get(category, fs_entry.path)
		return icon .. " ", hl
	end
	-- Try falling back to 'nvim-web-devicons'
	if fs_entry.fs_type == "directory" then
		return " ", "MiniFilesDirectory"
	end
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")
	if not has_devicons then
		return " ", "MiniFilesFile"
	end

	local icon, hl = devicons.get_icon(fs_entry.name, nil, { default = false })
	return (icon or "") .. " ", hl or "MiniFilesFile"
end

--- Default sort of file system entries
---
--- Sort directories and files separately (alphabetically ignoring case) and
--- put directories first.
---
---@param fs_entries table Array of file system entry data.
---   Each one is a table with the following fields:
--- __minifiles_fs_entry_data_fields
---
---@return table Sorted array of file system entries.
function M.default_sort(fs_entries)
	-- Sort ignoring case
	local res = vim.tbl_map(function(x)
		return {
			fs_type = x.fs_type,
			name = x.name,
			path = x.path,
			lower_name = x.name:lower(),
			is_dir = x.fs_type == "directory",
		}
	end, fs_entries)

	-- Sort based on default order
	table.sort(res, M.compare_fs_entries)

	return vim.tbl_map(function(x)
		return { name = x.name, fs_type = x.fs_type, path = x.path }
	end, res)
end

function M.compare_fs_entries(a, b)
  -- Put directory first
  if a.is_dir and not b.is_dir then return true end
  if not a.is_dir and b.is_dir then return false end

  -- Otherwise order alphabetically ignoring case
  return a.lower_name < b.lower_name
end

function M.normalize_opts(explorer_opts, opts)
  opts = vim.tbl_deep_extend('force', c.get_config(), explorer_opts or {}, opts or {})
  opts.content.filter = opts.content.filter or M.default_filter
  opts.content.prefix = opts.content.prefix or M.default_prefix
  opts.content.sort = opts.content.sort or M.default_sort
  return opts
end

-- Autocommands ---------------------------------------------------------------
--- @return string | nil
function M.track_dir_edit(data)
  -- Make early returns
  if vim.api.nvim_get_current_buf() ~= data.buf then return end

  if vim.b.minifiles_processed_dir then
    -- Smartly delete directory buffer if already visited
    local alt_buf = vim.fn.bufnr('#')
    if alt_buf ~= data.buf and vim.fn.buflisted(alt_buf) == 1 then vim.api.nvim_win_set_buf(0, alt_buf) end
    return vim.api.nvim_buf_delete(data.buf, { force = true })
  end

  local path = vim.api.nvim_buf_get_name(0)
  if vim.fn.isdirectory(path) ~= 1 then return end

  -- Make directory buffer disappear when it is not needed
  vim.bo.bufhidden = 'wipe'
  vim.b.minifiles_processed_dir = true

  -- Open directory without history
  return path
end

function M.match_line_entry_name(l)
  if l == nil then return nil end
  local offset = M.match_line_offset(l)
  -- Go up until first occurrence of path separator allowing to track entries
  -- like `a/b.lua` when creating nested structure
  local res = l:sub(offset):gsub('/.*$', '')
  return res
end

function M.match_line_offset(l)
  if l == nil then return nil end
  return l:match('^/.-/.-/()') or 1
end

function M.match_line_path_id(l)
  if l == nil then return nil end

  local id_str = l:match('^/(%d+)')
  local ok, res = pcall(tonumber, id_str)
  if not ok then return nil end
  return res
end


function M.error(msg) error(string.format('(mini.files) %s', msg), 0) end

function M.notify(msg, level_name) vim.notify('(mini.files) ' .. msg, vim.log.levels[level_name]) end

function M.map(mode, lhs, rhs, opts)
  if lhs == '' then return end
  opts = vim.tbl_deep_extend('force', { silent = true }, opts or {})
  vim.keymap.set(mode, lhs, rhs, opts)
end

function M.trigger_event(event_name, data)
  if M.block_event_trigger[event_name] then return end
  vim.api.nvim_exec_autocmds('User', { pattern = event_name, data = data })
end

function M.is_valid_buf(buf_id) return type(buf_id) == 'number' and vim.api.nvim_buf_is_valid(buf_id) end

function M.is_valid_win(win_id) return type(win_id) == 'number' and vim.api.nvim_win_is_valid(win_id) end

function M.get_bufline(buf_id, line) return vim.api.nvim_buf_get_lines(buf_id, line - 1, line, false)[1] end

function M.set_buflines(buf_id, lines)
  local cmd =
    string.format('lockmarks lua vim.api.nvim_buf_set_lines(%d, 0, -1, false, %s)', buf_id, vim.inspect(lines))
  vim.cmd(cmd)
end

function M.get_first_valid_normal_window()
  for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win_id).relative == '' then return win_id end
  end
end

return M
