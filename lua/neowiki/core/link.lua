-- lua/neowiki/core/link.lua
local util = require("neowiki.util")
local state = require("neowiki.state")

local M = {}

local USE_TREESITTER = true
-- Regex Patterns
-- 1. Wikilink: [[target]]
local PATTERN_WIKI = "%[%[(.-)%]%]"
-- 2. Markdown Link (Balanced): [text](target) OR ![text](target)
local PATTERN_MD_BALANCED = "(!?%[[^%]]*%])(%b())"
-- 3. Markdown Link (Angle Brackets): [text](<target>)
local PATTERN_MD_ANGLE = "(!?%[[^%]]*%])%(<(.-)>%)"

--- Checks if a Treesitter node type is a valid markdown link container.
---@param node_type string The type of the node (e.g., "inline_link").
---@return boolean True if the node is a link container.
local function is_link_node(node_type)
  return node_type == "inline_link"
    or node_type == "full_reference_link"
    or node_type == "shortcut_link"
    or node_type == "image"
end

-- Partially re-implement (copy) legacy `nvim-treesitter.ts_utils.get_node_at_cursor`
-- `https://github.com/nvim-treesitter/nvim-treesitter/blob/cf12346a3414fa1b06af75c79faebe7f76df080a/lua/nvim-treesitter/ts_utils.lua#L163`
local function get_root_for_position(line, col, root_lang_tree)
  local lang_tree = root_lang_tree:language_for_range({ line, col, line, col })

  while true do
    for _, tree in pairs(lang_tree:trees()) do
      local root = tree:root()

      if root and vim.treesitter.is_in_node_range(root, line, col) then
        return root, tree, lang_tree
      end
    end

    if lang_tree == root_lang_tree then
      break
    end

    -- This case can happen when the cursor is at the start of a line that ends a injected region,
    -- e.g., the first `]` in the following lua code:
    -- ```
    -- vim.cmd[[
    -- ]]
    -- ```
    lang_tree = lang_tree:parent() -- NOTE: parent() method is private
  end

  -- This isn't a likely scenario, since the position must belong to a tree somewhere.
  return nil, nil, lang_tree
end

local function get_node_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_range = { cursor[1] - 1, cursor[2] }

  local buf = vim.api.nvim_win_get_buf(0)
  local root_lang_tree = vim.treesitter.get_parser(buf)
  if not root_lang_tree then
    return
  end

  local root ---@type TSNode|nil
  root = get_root_for_position(cursor_range[1], cursor_range[2], root_lang_tree)

  if not root then
    return
  end

  return root:named_descendant_for_range(cursor_range[1], cursor_range[2], cursor_range[1], cursor_range[2])
end

--- Uses Treesitter to extract the link target under the cursor.
--- Returns nil if Treesitter is unavailable, disabled, or no link is found.
---@return string|nil The raw link target text, or nil.
local function get_ts_link_target()
  if not USE_TREESITTER then
    return nil
  end

  local node = get_node_at_cursor()
  if not node then
    return nil
  end

  local expr = node
  while expr do
    local ntype = expr:type()
    -- Safety: Ignore links inside code blocks
    if ntype == "code_span" or ntype == "fenced_code_block" or ntype == "code_block" then
      return nil
    end

    if is_link_node(ntype) then
      for child in expr:iter_children() do
        if child:type() == "link_destination" then
          return vim.treesitter.get_node_text(child, 0)
        end
      end
    end
    expr = expr:parent()
  end
  return nil
end

--- Checks if the cursor is inside a code block or other ignored node (e.g., block quote).
--- Uses Treesitter to check the host language (Markdown) tree, ignoring injections.
---@return boolean True if the cursor is in an ignored block.
local function is_cursor_in_ignored_block()
  if not USE_TREESITTER or not (vim.treesitter and vim.treesitter.get_node) then
    return false
  end

  -- `ignore_injections = true` ensures we check the HOST (Markdown) tree.
  local node = vim.treesitter.get_node({ ignore_injections = true })
  while node do
    local ntype = node:type()
    if
      ntype == "code_span"
      or ntype == "fenced_code_block"
      or ntype == "code_block"
      or ntype == "block_quote"
    then
      return true
    end
    node = node:parent()
  end
  return false
end

--- Scans a line for a link target containing a specific pattern (Hungry Mode).
---@param line string The text line to search.
---@param pattern_to_match string The substring pattern to look for.
---@return string|nil The raw target text if found, or nil.
local function find_target_by_pattern(line, pattern_to_match)
  -- 1. Standard/Balanced Markdown links
  local search_pos = 1
  while true do
    local s, e, _, target_parens = line:find(PATTERN_MD_BALANCED, search_pos)
    if not s then
      break
    end
    search_pos = e + 1

    local target = target_parens:sub(2, -2) -- Strip parens
    if target and target:find(pattern_to_match, 1, true) then
      return target
    end
  end

  -- 2. Angle Bracket Markdown links
  search_pos = 1
  while true do
    local s, e, _, target = line:find(PATTERN_MD_ANGLE, search_pos)
    if not s then
      break
    end
    search_pos = e + 1
    if target and target:find(pattern_to_match, 1, true) then
      return target
    end
  end

  -- 3. Wikilinks
  search_pos = 1
  while true do
    local s, e, target = line:find(PATTERN_WIKI, search_pos)
    if not s then
      break
    end
    search_pos = e + 1
    if target and target:find(pattern_to_match, 1, true) then
      return target
    end
  end

  return nil
end

--- Scans a line for a link target located at a specific column index (Cursor Mode).
---@param line string The text line to search.
---@param col number The 1-based column index of the cursor.
---@return string|nil The raw target text if found, or nil.
local function find_target_at_cursor(line, col)
  -- 1. Wikilinks (Prioritize over MD to avoid false matches if nested)
  local search_pos = 1
  while true do
    local s, e, target = line:find(PATTERN_WIKI, search_pos)
    if not s then
      break
    end
    search_pos = e + 1
    if col >= s and col <= e then
      return target
    end
  end

  -- 2. Angle Bracket Markdown links (MOVED UP: Check specific syntax before generic balanced)
  search_pos = 1
  while true do
    local s, e, _, target = line:find(PATTERN_MD_ANGLE, search_pos)
    if not s then
      break
    end
    search_pos = e + 1
    if col >= s and col <= e then
      return target
    end
  end

  -- 3. Standard/Balanced Markdown links
  search_pos = 1
  while true do
    local s, e, _, target_parens = line:find(PATTERN_MD_BALANCED, search_pos)
    if not s then
      break
    end
    search_pos = e + 1
    if col >= s and col <= e then
      return target_parens:sub(2, -2) -- Strip parens
    end
  end

  return nil
end

--- Generic helper that iterates through all links on a line and applies a transformation.
---@param line string The line of text to process.
---@param transform_logic function A callback that receives a context table and returns a replacement string or nil.
---@return string, number The modified line and the count of replacements.
local function generic_link_transformer(line, transform_logic)
  local total_replacements = 0

  local function replacer(context)
    local replacement = transform_logic(context)
    if replacement ~= nil then
      total_replacements = total_replacements + 1
      return replacement
    else
      return context.full_markup
    end
  end

  -- 1. Handle angle bracket links: [text](<target>)
  line = line:gsub(PATTERN_MD_ANGLE, function(link_text_part, raw_target)
    return replacer({
      type = "markdown",
      display_text = link_text_part:match("^!?%[(.*)%]$"),
      raw_target = raw_target,
      full_markup = link_text_part .. "(<" .. raw_target .. ">)",
    })
  end)

  -- 2. Handle standard/balanced links: [text](target)
  line = line:gsub(PATTERN_MD_BALANCED, function(link_text_part, target_parens)
    -- Strip the surrounding parentheses from %b() capture
    local raw_target = target_parens:sub(2, -2)
    if raw_target:match("^<.*>$") then
      return nil
    end
    return replacer({
      type = "markdown",
      display_text = link_text_part:match("^!?%[(.*)%]$"),
      raw_target = raw_target,
      full_markup = link_text_part .. target_parens,
    })
  end)

  -- 3. Handle wikilinks: [[target]]
  line = line:gsub(PATTERN_WIKI, function(raw_target)
    return replacer({
      type = "wikilink",
      display_text = raw_target,
      raw_target = raw_target,
      full_markup = "[[" .. raw_target .. "]]",
    })
  end)

  return line, total_replacements
end

--- Finds all valid markdown link targets on a single line of text.
---@param line string The line to search.
---@return table<string> A list of processed link targets found on the line.
local function find_all_link_targets(line)
  local targets = {}
  generic_link_transformer(line, function(ctx)
    local processed = util.process_link_target(ctx.raw_target, state.markdown_extension)
    if processed then
      table.insert(targets, processed)
    end
    return nil
  end)
  return targets
end

--- Scans the current buffer for markdown links that point to non-existent files.
---@return table A list of objects {filename, lnum, text} representing broken links.
M.find_broken_links_in_buffer = function()
  local broken_links_info = {}
  local current_buf_path = vim.api.nvim_buf_get_name(0)
  if not current_buf_path or current_buf_path == "" then
    return broken_links_info
  end

  local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
  local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  for i, line in ipairs(all_lines) do
    local has_broken_link_on_line = false
    local link_targets = find_all_link_targets(line)

    for _, target in ipairs(link_targets) do
      if not util.is_web_link(target) then
        local full_target_path = util.join_path(current_dir, target)
        full_target_path = vim.fn.fnamemodify(full_target_path, ":p")
        if vim.fn.filereadable(full_target_path) == 0 then
          has_broken_link_on_line = true
          break
        end
      end
    end

    if has_broken_link_on_line then
      table.insert(broken_links_info, {
        filename = current_buf_path,
        lnum = i,
        text = line,
      })
    end
  end

  return broken_links_info
end

--- Processes a line to find and extract a link based on cursor position or a search pattern.
---@param cursor table The cursor position {row, col} (0-indexed).
---@param line string The text line to search.
---@param pattern_to_match? string Optional pattern to search for (Hungry Mode).
---@return string|nil The processed link target path, or nil.
M.process_link = function(cursor, line, pattern_to_match)
  local raw_target = nil

  -- MODE 1: Hungry Mode (Search by text pattern)
  if pattern_to_match then
    raw_target = find_target_by_pattern(line, pattern_to_match)
  else
    -- MODE 2: Cursor Mode (Search under cursor)
    -- A. Try Treesitter extraction first (Best context awareness)
    raw_target = get_ts_link_target()
    -- B. If no TS match, try Regex fallback (with Safety Checks)
    if not raw_target then
      if not is_cursor_in_ignored_block() then
        raw_target = find_target_at_cursor(line, cursor[2] + 1)
      end
    end
  end

  if raw_target then
    return util.process_link_target(raw_target, state.markdown_extension)
  end

  return nil
end

--- Finds and transforms all links on a line that match a specific filename pattern.
---@param line string The line containing links.
---@param pattern_to_match string The substring to find within a link's target.
---@param transform_fn function A function that returns the new link markup.
---@return string, number The modified line and the total count of replacements made.
M.find_and_transform_link_markup = function(line, pattern_to_match, transform_fn)
  return generic_link_transformer(line, function(contex)
    if contex.raw_target and contex.raw_target:find(pattern_to_match, 1, true) then
      if contex.type == "markdown" then
        return transform_fn("[" .. contex.display_text .. "]", contex.raw_target)
      else
        return transform_fn(contex.display_text)
      end
    end
    return nil
  end)
end

--- Finds and removes the markup for broken local links on a single line, preserving text.
---@param line string The line to process.
---@param current_dir string The absolute path of the file's directory.
---@return string, boolean The modified line and a boolean indicating if changes were made.
M.remove_broken_markup = function(line, current_dir)
  local modified_line, count = generic_link_transformer(line, function(context)
    if not util.is_web_link(context.raw_target) then
      local processed_target =
        util.process_link_target(context.raw_target, state.markdown_extension)
      local full_target_path = util.join_path(current_dir, processed_target)

      if vim.fn.filereadable(full_target_path) == 0 then
        return context.display_text
      end
    end
    return nil
  end)
  return modified_line, count > 0
end

return M
