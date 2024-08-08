
-- TODO: where should this be located
local function setup_keymaps(buf_id, mappings)
	local go_in_visual = function()
		-- React only on linewise mode, as others can be used for editing
		if vim.fn.mode() ~= "V" then
			return mappings.go_in
		end

		-- Schedule actions because they are not allowed inside expression mapping
		local line_1, line_2 = vim.fn.line("v"), vim.fn.line(".")
		local from_line, to_line = math.min(line_1, line_2), math.max(line_1, line_2)
		vim.schedule(function()
			local explorer = M.explorer_get()
			explorer = M.explorer_go_in_range(explorer, buf_id, from_line, to_line)
			M.explorer_refresh(explorer)
		end)

		-- Go to Normal mode. '\28\14' is an escaped version of `<C-\><C-n>`.
		return [[<C-\><C-n>]]
	end

	local buf_map = function(mode, lhs, rhs, desc)
		-- Use `nowait` to account for non-buffer mappings starting with `lhs`
		M.map(mode, lhs, rhs, { buffer = buf_id, desc = desc, nowait = true })
	end

  --stylua: ignore start
  buf_map('n', mappings.close,       api.close,       'Close')
  buf_map('n', mappings.go_in,       xp.go_in_with_count,      'Go in entry')
  buf_map('n', mappings.go_in_plus,  xp.go_in_plus,            'Go in entry plus')
  buf_map('n', mappings.go_out,      xp.go_out_with_count,     'Go out of directory')
  buf_map('n', mappings.go_out_plus, xp.go_out_plus,           'Go out of directory plus')
  buf_map('n', mappings.reset,       xp.reset,       'Reset')
  buf_map('n', mappings.reveal_cwd,  xp.reveal_cwd,  'Reveal cwd')
  buf_map('n', mappings.show_help,   xp.show_help,   'Show Help')
  buf_map('n', mappings.synchronize, xp.synchronize, 'Synchronize')
  buf_map('n', mappings.trim_left,   xp.trim_left,   'Trim branch left')
  buf_map('n', mappings.trim_right,  xp.trim_right,  'Trim branch right')

  M.map('x', mappings.go_in, go_in_visual, { buffer = buf_id, desc = 'Go in selected entries', expr = true })
	--stylua: ignore end
end
