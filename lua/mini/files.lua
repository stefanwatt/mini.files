local explorer = require("lua.mini.explorer")
local utils = require("lua.mini.utils")
local highlight = require("lua.mini.highlight")
---@alias __minifiles_fs_entry_data_fields   - <fs_type> `(string)` - one of "file" or "directory".
---   - <name> `(string)` - basename of an entry (including extension).
---   - <path> `(string)` - full path of an entry.

---@diagnostic disable:undefined-field
---@diagnostic disable:discard-returns
---@diagnostic disable:unused-local
---@diagnostic disable:cast-local-type

-- Module definition ==========================================================
local M = {
	open = explorer.open,
	close = explorer.close,
}

--- Module setup
---
---@param config table|nil Module config table. See |M.config|.
---
---@usage >lua
---   require('mini.files').setup() -- use default config
---   -- OR
---   require('mini.files').setup({}) -- replace {} with your config table
--- <
function M.setup(config)
	-- Setup config
	config = utils.setup_config(config)

	-- Apply config
	utils.apply_config(config)

	-- Define behavior
	utils.create_autocommands(config)

	-- Create default highlighting
	highlight.create_default_hl()
end

return M
