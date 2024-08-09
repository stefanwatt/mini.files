local utils = require("mini.utils")
local M = {}
-- Index of all visited files
M.path_index = {}


-- Register of latest used paths per tabpage
M.latest_paths = {}

---@class fs_entry
---@field name string Base name.
---@field fs_type string One of "directory" or "file".
---@field path string Full path.
---@field path_id number Id of full path.
---@private
function M.read_dir(path, content_opts)
  local fs = vim.loop.fs_scandir(path)
  local res = {}
  if not fs then return res end

  -- Read all entries
  local name, fs_type = vim.loop.fs_scandir_next(fs)
  while name do
    if not (fs_type == 'file' or fs_type == 'directory') then fs_type = M.get_type(M.child_path(path, name)) end
    table.insert(res, { fs_type = fs_type, name = name, path = M.child_path(path, name) })
    name, fs_type = vim.loop.fs_scandir_next(fs)
  end

  -- Filter and sort entries
  --HACK: what in the fuck even is this architecture....
  --putting callback functions inside the explorer.opts 
  --nobody in the world can understand this nonsense
  res = content_opts.sort(vim.tbl_filter(content_opts.filter, res))

  -- Add new data: absolute file path and its index
  for _, entry in ipairs(res) do
    entry.path_id = M.add_path_to_index(entry.path)
  end

  return res
end

function M.add_path_to_index(path)
  local cur_id = M.path_index[path]
  if cur_id ~= nil then return cur_id end

  local new_id = #M.path_index + 1
  M.path_index[new_id] = path
  M.path_index[path] = new_id

  return new_id
end

function M.replace_path_in_index(from, to)
  local from_id, to_id = M.path_index[from], M.path_index[to]
  M.path_index[from_id], M.path_index[to] = to, from_id
  if to_id then M.path_index[to_id] = nil end
  -- Remove `from` from index assuming it doesn't exist anymore (no duplicates)
  M.path_index[from] = nil
end

function M.normalize_path(path) return (path:gsub('/+', '/'):gsub('(.)/$', '%1')) end
if M.is_windows then
  function M.normalize_path(path) return (path:gsub('\\', '/'):gsub('/+', '/'):gsub('(.)/$', '%1')) end
end

-- formerly is_present_path
function M.does_path_exist(path) return vim.loop.fs_stat(path) ~= nil end

function M.child_path(dir, name) return M.normalize_path(string.format('%s/%s', dir, name)) end

function M.full_path(path) return M.normalize_path(vim.fn.fnamemodify(path, ':p')) end

function M.shorten_path(path)
  -- Replace home directory with '~'
  path = M.normalize_path(path)
  local home_dir = M.normalize_path(vim.loop.os_homedir() or '~')
  local res = path:gsub('^' .. vim.pesc(home_dir), '~')
  return res
end

function M.get_basename(path) return M.normalize_path(path):match('[^/]+$') end

function M.get_parent(path)
  path = M.full_path(path)

  -- Deal with top root paths
  local is_top = M.is_windows_top(path) or path == '/'
  if is_top then return nil end

  -- Compute parent
  local res = M.normalize_path(path:match('^.*/'))
  -- - Deal with Windows top directory separately
  local suffix = M.is_windows_top(res) and '/' or ''
  return res .. suffix
end

function M.is_windows_top(path) return M.is_windows and path:find('^%w:[\\/]?$') ~= nil end

function M.get_type(path)
  if not M.does_path_exist(path) then return nil end
  return vim.fn.isdirectory(path) == 1 and 'directory' or 'file'
end

-- File system actions --------------------------------------------------------
-- TODO: find better name
function M.actions_confirm(fs_actions)
  if not require("mini.config").config.options.confirm_fs_actions then
		return true
	end
  local msg = table.concat(M.actions_to_lines(fs_actions), '\n')
  local confirm_res = vim.fn.confirm(msg, '&Yes\n&No', 1, 'Question')
  return confirm_res == 1
end

function M.actions_to_lines(fs_actions)
  -- Gather actions per source directory
  local actions_per_dir = {}

  local get_dir_actions = function(path)
    local dir_path = M.shorten_path(M.get_parent(path))
    local dir_actions = actions_per_dir[dir_path] or {}
    actions_per_dir[dir_path] = dir_actions
    return dir_actions
  end

  local get_quoted_basename = function(path) return string.format("'%s'", M.get_basename(path)) end

  for _, diff in ipairs(fs_actions.copy) do
    local dir_actions = get_dir_actions(diff.from)
    local l = string.format("    COPY: %s to '%s'", get_quoted_basename(diff.from), M.shorten_path(diff.to))
    table.insert(dir_actions, l)
  end

  for _, path in ipairs(fs_actions.create) do
    local dir_actions = get_dir_actions(path)
    local fs_type = path:find('/$') == nil and 'file' or 'directory'
    local l = string.format('  CREATE: %s (%s)', get_quoted_basename(path), fs_type)
    table.insert(dir_actions, l)
  end

  for _, path in ipairs(fs_actions.delete) do
    local dir_actions = get_dir_actions(path)
    local l = string.format('  DELETE: %s', get_quoted_basename(path))
    table.insert(dir_actions, l)
  end

  for _, diff in ipairs(fs_actions.move) do
    local dir_actions = get_dir_actions(diff.from)
    local l = string.format("    MOVE: %s to '%s'", get_quoted_basename(diff.from), M.shorten_path(diff.to))
    table.insert(dir_actions, l)
  end

  for _, diff in ipairs(fs_actions.rename) do
    local dir_actions = get_dir_actions(diff.from)
    local l = string.format('  RENAME: %s to %s', get_quoted_basename(diff.from), get_quoted_basename(diff.to))
    table.insert(dir_actions, l)
  end

  -- Convert to lines
  local res = { 'CONFIRM FILE SYSTEM ACTIONS', '' }
  for path, dir_actions in pairs(actions_per_dir) do
    table.insert(res, path .. ':')
    vim.list_extend(res, dir_actions)
    table.insert(res, '')
  end

  return res
end

function M.actions_apply(fs_actions, opts)
  -- Copy first to allow later proper deleting
  for _, diff in ipairs(fs_actions.copy) do
    local ok, success = pcall(M.copy, diff.from, diff.to)
    local data = { action = 'copy', from = diff.from, to = diff.to }
    if ok and success then utils.trigger_event('MiniFilesActionCopy', data) end
  end

  for _, path in ipairs(fs_actions.create) do
    local ok, success = pcall(M.create, path)
    local data = { action = 'create', to = M.normalize_path(path) }
    if ok and success then utils.trigger_event('MiniFilesActionCreate', data) end
  end

  for _, diff in ipairs(fs_actions.move) do
    local ok, success = pcall(M.move, diff.from, diff.to)
    local data = { action = 'move', from = diff.from, to = diff.to }
    if ok and success then utils.trigger_event('MiniFilesActionMove', data) end
  end

  for _, diff in ipairs(fs_actions.rename) do
    local ok, success = pcall(M.rename, diff.from, diff.to)
    local data = { action = 'rename', from = diff.from, to = diff.to }
    if ok and success then utils.trigger_event('MiniFilesActionRename', data) end
  end

  -- Delete last to not lose anything too early (just in case)
  for _, path in ipairs(fs_actions.delete) do
    local ok, success = pcall(M.delete, path, opts.options.permanent_delete)
    local data = { action = 'delete', from = path }
    if ok and success then utils.trigger_event('MiniFilesActionDelete', data) end
  end
end

function M.create(path)
  -- Don't override existing path
  if M.does_path_exist(path) then return M.warn_existing_path(path, 'create') end

  -- Create parent directory allowing nested names
  vim.fn.mkdir(M.get_parent(path), 'p')

  -- Create
  local fs_type = path:find('/$') == nil and 'file' or 'directory'
  if fs_type == 'directory' then
    return vim.fn.mkdir(path) == 1
  else
    return vim.fn.writefile({}, path) == 0
  end
end

function M.copy(from, to)
  -- Don't override existing path
  if M.does_path_exist(to) then return M.warn_existing_path(from, 'copy') end

  local from_type = M.get_type(from)
  if from_type == nil then return false end

  -- Allow copying inside non-existing directory
  vim.fn.mkdir(M.get_parent(to), 'p')

  -- Copy file directly
  if from_type == 'file' then return vim.loop.fs_copyfile(from, to) end

  -- Recursively copy a directory
  local fs_entries = M.read_dir(from, { filter = function() return true end, sort = function(x) return x end })
  -- NOTE: Create directory *after* reading entries to allow copy inside itself
  vim.fn.mkdir(to)

  local success = true
  for _, entry in ipairs(fs_entries) do
    success = success and M.copy(entry.path, M.child_path(to, entry.name))
  end

  return success
end

function M.delete(path, permanent_delete)
  if permanent_delete then return vim.fn.delete(path, 'rf') == 0 end

  -- Move to trash instead of permanent delete
  local trash_dir = M.child_path(vim.fn.stdpath('data'), 'mini.files/trash')
  vim.fn.mkdir(trash_dir, 'p')

  local trash_path = M.child_path(trash_dir, M.get_basename(path))

  -- Ensure that same basenames are replaced
  pcall(vim.fn.delete, trash_path, 'rf')

  return vim.loop.fs_rename(path, trash_path)
end

function M.move(from, to)
  -- Don't override existing path
  if M.does_path_exist(to) then return M.warn_existing_path(from, 'move or rename') end

  -- Move while allowing to create directory
  vim.fn.mkdir(M.get_parent(to), 'p')
  local success = vim.loop.fs_rename(from, to)

  if not success then return success end

  -- Update path index to allow consecutive moves after undo (which also
  -- restores previous concealed path index)
  M.replace_path_in_index(from, to)

  -- Rename in loaded buffers
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    M.rename_loaded_buffer(buf_id, from, to)
  end

  return success
end

M.rename = M.move


function M.warn_existing_path(path, action)
  M.notify(string.format('Can not %s %s. Target path already exists.', action, path), 'WARN')
  return false
end

--- Get file system entry data
---
---@param buf_id number|nil Buffer identifier of valid directory buffer.
---   Default: current buffer.
---@param line number|nil Line number of entry for which to return information.
---   Default: cursor line.
---
---@return table|nil Table of file system entry data with the following fields:
--- __minifiles_fs_entry_data_fields
---
--- Returns `nil` if there is no proper file system entry path at the line.
function M.get_fs_entry(buf_id, line)
  local path_id = utils.match_line_path_id(utils.get_bufline(buf_id, line))
  if path_id == nil then return nil end

  local path = M.path_index[path_id]
  return { fs_type = M.get_type(path), name = M.get_basename(path), path = path }
end

--- Get latest used anchor path
---
--- Note: if latest used `path` argument for |M.open()| was for file,
--- this will return its parent (as it was used as anchor path).
function M.get_latest_path()
	return utils.latest_paths[vim.api.nvim_get_current_tabpage()]
end

return M
