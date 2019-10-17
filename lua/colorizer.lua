--- Highlights terminal CSI ANSI color codes.
-- @module terminal
local nvim = require 'nvim'
local Trie = require 'trie'

--- Default namespace used in `highlight_buffer` and `attach_to_buffer`.
-- The name is "terminal_highlight"
-- @see highlight_buffer
-- @see attach_to_buffer
local DEFAULT_NAMESPACE = nvim.create_namespace 'colorizer'

local COLOR_MAP
local COLOR_TRIE

local function initialize_trie()
	if not COLOR_TRIE then
		COLOR_MAP = nvim.get_color_map()
		COLOR_TRIE = Trie()

		for k in pairs(COLOR_MAP) do
			COLOR_TRIE:insert(k)
		end
	end
end

local b_a = string.byte('a')
local b_z = string.byte('z')
local b_A = string.byte('A')
local b_Z = string.byte('Z')
local b_0 = string.byte('0')
local b_9 = string.byte('9')
local b_f = string.byte('f')
local b_hash = string.byte('#')
local bnot = bit.bnot
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

-- TODO use lookup table?
local function byte_is_hex(byte)
	byte = bor(byte, 0x20)
	return (byte >= b_0 and byte <= b_9) or (byte >= b_a and byte <= b_f)
end

--- Determine whether to use black or white text
-- Ref: https://stackoverflow.com/a/1855903/837964
-- https://stackoverflow.com/questions/596216/formula-to-determine-brightness-of-rgb-color
local function color_is_bright(r, g, b)
	-- Counting the perceptive luminance - human eye favors green color
	local luminance = (0.299*r + 0.587*g + 0.114*b)/255
	if luminance > 0.5 then
		return true -- Bright colors, black font
	else
		return false -- Dark colors, white font
	end
end

local HIGHLIGHT_NAME_PREFIX = "colorizer_"
--- Make a deterministic name for a highlight given these attributes
local function make_highlight_name(rgb)
	return table.concat {HIGHLIGHT_NAME_PREFIX, rgb}
end

local highlight_cache = {}

-- Ref: https://stackoverflow.com/questions/1252539/most-efficient-way-to-determine-if-a-lua-table-is-empty-contains-no-entries
local function table_is_empty(t)
	return next(t) == nil
end

local function create_highlight(rgb_hex, options)
	-- TODO validate rgb format?
	local highlight_name = highlight_cache[rgb_hex]
	-- Look up in our cache.
	if not highlight_name then
		-- Create the highlight
		highlight_name = make_highlight_name(rgb_hex)
		if options.mode == 'foreground' then
			nvim.ex.highlight(highlight_name, "guifg=#"..rgb_hex)
		else
			local r, g, b = rgb_hex:sub(1,2), rgb_hex:sub(3,4), rgb_hex:sub(5,6)
			r, g, b = tonumber(r,16), tonumber(g,16), tonumber(b,16)
			local fg_color
			if color_is_bright(r,g,b) then
				fg_color = "Black"
			else
				fg_color = "White"
			end
			nvim.ex.highlight(highlight_name, "guifg="..fg_color, "guibg=#"..rgb_hex)
		end
		highlight_cache[rgb_hex] = highlight_name
	end
	return highlight_name
end

--- Highlight a region in a buffer from the attributes specified
local function highlight_region(buf, ns, highlight_name,
		 region_line_start, region_byte_start,
		 region_line_end, region_byte_end)
	-- TODO should I bother with highlighting normal regions?
	if region_line_start == region_line_end then
		nvim.buf_add_highlight(buf, ns, highlight_name, region_line_start, region_byte_start, region_byte_end)
	else
		nvim.buf_add_highlight(buf, ns, highlight_name, region_line_start, region_byte_start, -1)
		for linenum = region_line_start + 1, region_line_end - 1 do
			nvim.buf_add_highlight(buf, ns, highlight_name, linenum, 0, -1)
		end
		nvim.buf_add_highlight(buf, ns, highlight_name, region_line_end, 0, region_byte_end)
	end
end

--[[-- Highlight the buffer region.
Highlight starting from `line_start` (0-indexed) for each line described by `lines` in the
buffer `buf` and attach it to the namespace `ns`.

@tparam integer buf buffer id.
@tparam[opt=DEFAULT_NAMESPACE] integer ns the namespace id. Create it with `vim.api.create_namespace`
@tparam {string,...} lines the lines to highlight from the buffer.
@tparam integer line_start should be 0-indexed
]]
local function highlight_buffer(buf, ns, lines, line_start, options)
	options = options or {}
	-- TODO do I have to put this here?
	initialize_trie()
	ns = ns or DEFAULT_NAMESPACE
	for current_linenum, line in ipairs(lines) do
		-- @todo it's possible to skip processing the new code if the attributes hasn't changed.
		current_linenum = current_linenum - 1 + line_start
		local i = 1
		while i < #line do
			local byte = line:byte(i)
			if byte == b_hash then
				i = i + 1
				if #line >= i + 5 then
					local invalid = false
					for n = i, i+5 do
						byte = line:byte(n)
						if not byte_is_hex(byte) then
							invalid = true
							break
						end
					end
					if not invalid then
						local rgb_hex = line:sub(i, i+5)
						-- TODO figure out proper background/foreground
						local highlight_name = create_highlight(rgb_hex, options)
						-- Subtract one because 0-indexed, subtract another 1 for the '#'
						nvim.buf_add_highlight(buf, ns, highlight_name, current_linenum, i-1-1, i+6-1)
						i = i + 5
					end
				end
			else
				-- TODO skip if the remaining length is less than the shortest length
				-- of an entry in our trie.
				local prefix = COLOR_TRIE:longest_prefix(line:sub(i))
				if prefix then
					local rgb = COLOR_MAP[prefix]
					local rgb_hex = bit.tohex(rgb):sub(-6)
					-- TODO figure out proper background/foreground
					local highlight_name = create_highlight(rgb_hex, options)
					nvim.buf_add_highlight(buf, ns, highlight_name, current_linenum, i-1, i+#prefix-1)
					i = i + #prefix
				else
					i = i + 1
				end
			end
		end
	end
end

--- Attach to a buffer and continuously highlight changes.
-- @tparam[opt=0] integer buf A value of 0 implies the current buffer.
-- @see highlight_buffer
local function attach_to_buffer(buf, options)
	local ns = DEFAULT_NAMESPACE
	if buf == 0 or buf == nil then
		buf = nvim.get_current_buf()
	end
	-- Already attached.
	if pcall(vim.api.nvim_buf_get_var, buf, "colorizer_attached") then
		return
	end
	nvim.buf_set_var(buf, "colorizer_attached", true)
	do
		nvim.buf_clear_namespace(buf, ns, 0, -1)
		local lines = nvim.buf_get_lines(buf, 0, -1, true)
		highlight_buffer(buf, ns, lines, 0, options)
	end
	-- send_buffer: true doesn't actually do anything in Lua (yet)
	nvim.buf_attach(buf, false, {
		on_lines = function(event_type, buf, changed_tick, firstline, lastline, new_lastline)
			nvim.buf_clear_namespace(buf, ns, firstline, new_lastline)
			local lines = nvim.buf_get_lines(buf, firstline, new_lastline, true)
			highlight_buffer(buf, ns, lines, firstline, options)
		end;
	})
end

--- Easy to use function if you want the full setup without fine grained control.
-- Establishes an autocmd for `FileType terminal`
-- @usage require'colorizer'.setup()
local function auto_setup(filetypes, default_options)
	if not nvim.o.termguicolors then
		nvim.err_writeln("&termguicolors must be set")
		return
	end
	initialize_trie()
	local filetype_options = {}
	function COLORIZER_SETUP_HOOK()
		local filetype = nvim.bo.filetype
		local options = filetype_options[filetype] or default_options
		attach_to_buffer(nvim.get_current_buf(), options)
	end
	nvim.ex.augroup("ColorizerSetup")
	nvim.ex.autocmd_()
	if not filetypes then
		nvim.ex.autocmd("FileType * lua COLORIZER_SETUP_HOOK()")
	else
		for k, v in pairs(filetypes) do
			local filetype
			local options = default_options or {}
			if type(k) == 'string' then
				filetype = k
				if type(v) ~= 'table' then
					nvim.err_writeln("colorizer: Invalid option type for filetype "..filetype)
				else
					options = vim.tbl_extend("keep", v, default_options)
				end
			else
				filetype = v
			end
			filetype_options[filetype] = options
			-- TODO What's the right mode for this? BufEnter?
			nvim.ex.autocmd("FileType", filetype, "lua COLORIZER_SETUP_HOOK(%s)")
		end
	end
	nvim.ex.augroup("END")
end

--- @export
return {
	DEFAULT_NAMESPACE = DEFAULT_NAMESPACE;
	setup = auto_setup;
	attach_to_buffer = attach_to_buffer;
	highlight_buffer = highlight_buffer;
	initialize = initialize_trie;
}
