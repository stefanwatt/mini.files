local explorer = require("mini.explorer")
local utils = require("mini.utils")
local highlight = require("mini.highlight")
local config = require("mini.config")
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
---@param user_config table|nil Module config table. See |M.config|.
---
---@usage >lua
---   require('mini.files').setup() -- use default config
---   -- OR
---   require('mini.files').setup({}) -- replace {} with your config table
--- <
function M.setup(user_config)
	-- Setup config
	user_config = config.setup_config(user_config)

	-- Apply config
	config.apply_config(user_config)

	-- Define behavior
	utils.au("VimResized", "*", explorer.resize, "Refresh on resize")

	if user_config.options.use_as_default_explorer then
		-- Stop 'netrw' from showing. Needs `VimEnter` event autocommand if
		-- this is called prior 'netrw' is set up
		vim.cmd("silent! autocmd! FileExplorer *")
		vim.cmd("autocmd VimEnter * ++once silent! autocmd! FileExplorer *")
		utils.au("BufEnter", "*", function(data)
			local path = utils.track_dir_edit(data)
			if not path then return end
			vim.schedule(function()
				explorer.open(path, false)
			end)
		end, "Track directory edit")
	end

	-- Create default highlighting
	highlight.create_default_hl()
end

return M
