local highlight = require "lua.mini.highlight"
local buffer    = require "lua.mini.buffer"
local M = {}

function M.window_open(buf_id, config)
  -- Add always the same extra data
  config.anchor = 'NW'
  config.border = 'single'
  config.focusable = true
  config.relative = 'editor'
  config.style = 'minimal'
  -- - Use 99 to allow built-in completion to be on top
  config.zindex = 99

  -- Add temporary data which will be updated later
  config.row = 1

  -- Ensure it works on Neovim<0.9
  if vim.fn.has('nvim-0.9') == 0 then config.title = nil end

  -- Open without entering
  local win_id = vim.api.nvim_open_win(buf_id, false, config)

  -- Set permanent window options
  vim.wo[win_id].concealcursor = 'nvic'
  vim.wo[win_id].foldenable = false
  vim.wo[win_id].wrap = false

  -- Conceal path id and prefix separators
  vim.api.nvim_win_call(win_id, function()
    vim.fn.matchadd('Conceal', [[^/\d\+/]])
    vim.fn.matchadd('Conceal', [[^/\d\+/[^/]*\zs/\ze]])
  end)

  -- Set permanent window highlights
  highlight.window_update_highlight(win_id, 'NormalFloat', 'MiniFilesNormal')
  highlight.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitle')
  highlight.window_update_highlight(win_id, 'CursorLine', 'MiniFilesCursorLine')

  -- Trigger dedicated event
  M.trigger_event('MiniFilesWindowOpen', { buf_id = buf_id, win_id = win_id })

  return win_id
end

function M.window_update(win_id, config)
  -- Compute helper data
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local max_height = M.window_get_max_height()

  -- Ensure proper fit
  config.row = has_tabline and 1 or 0
  -- config.height = config.height ~= nil and math.min(config.height, max_height) or nil
  config.height = max_height
  config.width = config.width ~= nil and math.min(config.width, vim.o.columns) or nil

  -- Ensure proper title on Neovim>=0.9 (as they are not supported earlier)
  if vim.fn.has('nvim-0.9') == 1 and config.title ~= nil then
    -- Show only tail if title is too long
    local title_string, width = config.title, config.width
    local title_chars = vim.fn.strcharlen(title_string)
    if width < title_chars then
      title_string = '…' .. vim.fn.strcharpart(title_string, title_chars - width + 1, width - 1)
    end
    config.title = title_string
    -- Preserve some config values
    local win_config = vim.api.nvim_win_get_config(win_id)
    config.border, config.title_pos = win_config.border, win_config.title_pos
  else
    config.title = nil
  end

  -- Update config
  config.relative = 'editor'
  vim.api.nvim_win_set_config(win_id, config)

  -- Reset basic highlighting (removes possible "focused" highlight group)
  highlight.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitle')

  -- Make sure that 'cursorline' is not overridden by `config.style`
  vim.wo[win_id].cursorline = true

  -- Make sure proper `conceallevel` (can be not the case with 'noice.nvim')
  vim.wo[win_id].conceallevel = 3
end


function M.window_focus(win_id)
  vim.api.nvim_set_current_win(win_id)
  highlight.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitleFocused')
end

function M.window_close(win_id)
  if win_id == nil then return end
  local has_buffer, buf_id = pcall(vim.api.nvim_win_get_buf, win_id)
  if has_buffer then M.opened_buffers[buf_id].win_id = nil end
  pcall(vim.api.nvim_win_close, win_id, true)
end

function M.window_set_view(win_id, view)
  -- Set buffer
  local buf_id = view.buf_id
  vim.api.nvim_win_set_buf(win_id, buf_id)
  -- - Update buffer register. No need to update previous buffer data, as it
  --   should already be invalidated.
  M.opened_buffers[buf_id].win_id = win_id

  -- Set cursor
  pcall(M.window_set_cursor, win_id, view.cursor)

  -- Set 'cursorline' here also because changing buffer might have removed it
  vim.wo[win_id].cursorline = true

  -- Update border highlight based on buffer status
  local buffer_opened = buffer.is_opened_buffer(buf_id)
  local buffer_modified = buffer.is_modified_buffer(buf_id)
  highlight.window_update_border_hl(win_id, buffer_opened, buffer_modified)
end

function M.window_set_cursor(win_id, cursor)
  if type(cursor) ~= 'table' then return end

  vim.api.nvim_win_set_cursor(win_id, cursor)

  -- Tweak cursor here and don't rely on `CursorMoved` event to reduce flicker
  M.window_tweak_cursor(win_id, vim.api.nvim_win_get_buf(win_id))
end

function M.window_tweak_cursor(win_id, buf_id)
  local cursor = vim.api.nvim_win_get_cursor(win_id)
  local l = M.get_bufline(buf_id, cursor[1])

  local cur_offset = M.match_line_offset(l)
  if cursor[2] < (cur_offset - 1) then
    cursor[2] = cur_offset - 1
    vim.api.nvim_win_set_cursor(win_id, cursor)
    -- Ensure icons are shown (may be not the case after horizontal scroll)
    vim.cmd('normal! 1000zh')
  end

  return cursor
end


function M.window_get_max_height()
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local has_statusline = vim.o.laststatus > 0
  -- Remove 2 from maximum height to account for top and bottom borders
  return vim.o.lines - vim.o.cmdheight - (has_tabline and 1 or 0) - (has_statusline and 1 or 0) - 2
end

return M
