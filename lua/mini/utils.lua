local M = {}

-- Namespaces

-- Timers
M.timers = {
  focus = vim.loop.new_timer(),
}

-- File system information
M.is_windows = vim.loop.os_uname().sysname == 'Windows_NT'

-- Register table to decide whether certain autocmd events should be triggered
M.block_event_trigger = {}

local augroup = vim.api.nvim_create_augroup('MiniFiles', {})
local function au(event, pattern, callback, desc)
  vim.api.nvim_create_autocmd(event, { group = augroup, pattern = pattern, callback = callback, desc = desc })
end

function M.create_autocommands(config)
  au('VimResized', '*', MiniFiles.refresh, 'Refresh on resize')

  if config.options.use_as_default_explorer then
    -- Stop 'netrw' from showing. Needs `VimEnter` event autocommand if
    -- this is called prior 'netrw' is set up
    vim.cmd('silent! autocmd! FileExplorer *')
    vim.cmd('autocmd VimEnter * ++once silent! autocmd! FileExplorer *')

    au('BufEnter', '*', M.track_dir_edit, 'Track directory edit')
  end
end

--stylua: ignore
function M.get_config(config)
  return vim.tbl_deep_extend('force', require("lua.mini.config").config, vim.b.minifiles_config or {}, config or {})
end

function M.normalize_opts(explorer_opts, opts)
  opts = vim.tbl_deep_extend('force', M.get_config(), explorer_opts or {}, opts or {})
  opts.content.filter = opts.content.filter or MiniFiles.default_filter
  opts.content.prefix = opts.content.prefix or MiniFiles.default_prefix
  opts.content.sort = opts.content.sort or MiniFiles.default_sort

  return opts
end

-- Autocommands ---------------------------------------------------------------
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
  vim.schedule(function() MiniFiles.open(path, false) end)
end

M.timers = {
  focus = vim.loop.new_timer(),
}

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

function M.set_extmark(...) pcall(vim.api.nvim_buf_set_extmark, ...) end

function M.get_first_valid_normal_window()
  for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win_id).relative == '' then return win_id end
  end
end

return M
