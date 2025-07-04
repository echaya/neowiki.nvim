-- lua/neowiki/core/link.lua
local util = require("neowiki.util")
local state = require("neowiki.state")

local M = {}

---
-- Finds all valid markdown link targets on a single line of text.
-- @param line (string): The line to search.
-- @return (table): A list of processed link targets found on the line.
--
local function find_all_link_targets(line)
  local targets = {}

  -- Find standard markdown links: [text](target)
  for file in line:gmatch("%]%(<?([^)>]+)>?%)") do
    local processed = util.process_link_target(file, state.markdown_extension)
    if processed then
      table.insert(targets, processed)
    end
  end

  -- Find wikilinks: [[target]]
  for file in line:gmatch("%[%[([^]]+)%]%]") do
    local processed = util.process_link_target(file, state.markdown_extension)
    if processed then
      table.insert(targets, processed)
    end
  end

  return targets
end

---
-- Scans the current buffer for markdown links that point to non-existent files.
-- @return (table) A list of objects, where each object represents a line
--   containing at least one broken link. Each object contains `lnum` and `text`.
--   Returns an empty table if no broken links are found.
--
M.find_broken_links_in_buffer = function()
  local broken_links_info = {}
  local current_buf_path = vim.api.nvim_buf_get_name(0)
  if not current_buf_path or current_buf_path == "" then
    return broken_links_info -- Not a file buffer
  end

  local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
  local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  for i, line in ipairs(all_lines) do
    local has_broken_link_on_line = false
    local link_targets = find_all_link_targets(line)

    for _, target in ipairs(link_targets) do
      -- Ignore external URLs when checking for broken file links.
      if not util.is_web_link(target) then
        local full_target_path = util.join_path(current_dir, target)
        full_target_path = vim.fn.fnamemodify(full_target_path, ":p")
        -- A link is considered broken if the target file isn't readable.
        if vim.fn.filereadable(full_target_path) == 0 then
          has_broken_link_on_line = true
          break -- One broken link is enough to mark the entire line.
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

---
-- Processes a line to find and extract a link based on cursor position or a search pattern.
-- The function operates in two modes:
-- 1. **Cursor Mode** (default): When `pattern_to_match` is nil, it finds the link
--    (Markdown or Wikilink) that is currently under the editor's cursor.
-- 2. **"Hungry" Mode**: When `pattern_to_match` is a string, it ignores the cursor
--    and returns the *first* link found whose target contains `pattern_to_match`
--    as a substring.
-- @param cursor table A table representing the cursor's position, where `cursor[2]` is the 0-indexed column.
-- @param line string The line of text to be analyzed.
-- @param pattern_to_match string|nil The substring to search for in link targets ("hungry mode"), or nil to use cursor position.
-- @return string|nil The processed link target if a match is found, otherwise nil.
M.process_link = function(cursor, line, pattern_to_match)
  -- Determine the mode. If pattern_to_match is nil, use cursor position.
  local hungry_mode = pattern_to_match ~= nil
  local col = not hungry_mode and (cursor[2] + 1) or 0

  -- 1. Search for standard markdown links: [text](target)
  do
    local md_pattern = "%[(.-)%]%(<?([^)>]+)>?%)"
    local search_pos = 1
    while true do
      local s, e, _, target = line:find(md_pattern, search_pos)
      if not s then
        break
      end
      search_pos = e + 1

      if hungry_mode then
        if target and target:find(pattern_to_match, 1, true) then
          vim.notify(
            "hungry_mode taget found for []() pattern: "
              .. target
              .. " pattern: "
              .. pattern_to_match
          )
          return util.process_link_target(target, state.markdown_extension)
        end
      elseif col >= s and col <= e then
        return util.process_link_target(target, state.markdown_extension)
      end
    end
  end

  -- 2. If no markdown link was found/matched, search for wikilinks: [[target]]
  do
    local wiki_pattern = "%[%[(.-)%]%]"
    local search_pos = 1
    while true do
      local s, e, target = line:find(wiki_pattern, search_pos)
      if not s then
        break
      end
      search_pos = e + 1

      if hungry_mode then
        if target and target:find(pattern_to_match, 1, true) then
          vim.notify(
            "hungry_mode taget found for [[]] pattern: "
              .. target
              .. " pattern: "
              .. pattern_to_match
          )
          return util.process_link_target(target, state.markdown_extension)
        end
      elseif col >= s and col <= e then
        return util.process_link_target(target, state.markdown_extension)
      end
    end
  end

  return nil
end

---
-- Finds the first markdown or wikilink on a line and transforms it.
-- @param line (string) The line containing the link.
-- @param transform_fn (function) A function that receives the link components and returns the new link markup.
--   - For markdown links, receives (link_text, old_target). e.g., "My Page", "./my_page.md"
--   - For wikilinks, receives (link_text). e.g., "My Page"
-- @return (string, number) The modified line and the count of replacements.
--
M.find_and_transform_link_markup = function(line, transform_fn)
  -- 1. Try to transform a standard markdown link: [text](target)
  local md_pattern = "(%[.-%])(%(.-%))"
  local md_link_text, md_target_part = line:match(md_pattern)

  if md_link_text and md_target_part then
    local old_full_markup = md_link_text .. md_target_part
    -- Extract the raw target from within the parentheses
    local old_target = md_target_part:match("%((.*)%)")
    -- The transform function returns the complete new markup, e.g., "[My Page](./new.md)" or ""
    local new_full_markup = transform_fn(md_link_text, old_target)
    return line:gsub(vim.pesc(old_full_markup), new_full_markup, 1)
  end

  -- 2. If no markdown link, try to transform a wikilink: [[target]]
  local wiki_pattern = "%[%[(.-)%]%]"
  local old_link_text = line:match(wiki_pattern)

  if old_link_text then
    local old_full_markup = "[[" .. old_link_text .. "]]"
    local new_full_markup = transform_fn(old_link_text)
    return line:gsub(vim.pesc(old_full_markup), new_full_markup, 1)
  end

  return line, 0
end

return M
