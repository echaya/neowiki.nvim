local state = require("neowiki.state")

local util = {}

---
-- Recursively merges two tables. Values in `override` take precedence.
-- @param base (table): The table to merge into.
-- @param override (table): The table with values to merge from.
-- @return (table): A new table containing the merged result.
--
util.deep_merge = function(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" and not vim.islist(v) then
      result[k] = util.deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

---
-- Gets the default wiki path, which is `~/wiki`.
-- @return (string): The default wiki path.
--
util.get_default_path = function()
  return vim.fs.joinpath(vim.loop.os_homedir(), "wiki")
end

---
-- Sorts a list of wiki path objects by path length, descending.
-- This ensures that more specific (deeper) paths are matched first.
-- @param paths (table): The list of path objects to sort.
--
util.sort_wiki_paths = function(paths)
  table.sort(paths, function(a, b)
    return #a.normalized > #b.normalized
  end)
end

---
-- Resolves a configuration path string (e.g., "~/notes") into a full, absolute path.
-- @param path_str (string): The path string from the configuration.
-- @return (string|nil): The resolved absolute path, or nil if input is invalid.
--
util.resolve_path = function(path_str)
  if not path_str or path_str == "" then
    return nil
  end

  -- Resolve path relative to home directory if it's not absolute.
  local path_to_resolve
  if vim.fn.isabsolutepath(path_str) == 0 then
    path_to_resolve = vim.fs.joinpath(vim.loop.os_homedir(), path_str)
  else
    path_to_resolve = path_str
  end

  return vim.fn.fnamemodify(path_to_resolve, ":p")
end

---
-- Ensures a directory exists at the given path, creating it if necessary.
-- @param path (string): The absolute path of the directory to check.
--
util.ensure_path_exists = function(path)
  if not path or path == "" then
    return
  end
  -- Create the directory if it doesn't exist.
  if vim.fn.isdirectory(path) ~= 1 then
    pcall(vim.fn.mkdir, path, "p")
    vim.notify("  " .. path .. " created.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

---
-- Processes a raw link target, cleaning it and appending the configured extension if necessary.
-- @param target (string): The raw link target string (e.g., "my page").
-- @return (string|nil): The processed link target (e.g., "my_page.md"), or nil.
--
local process_link_target = function(target)
  if not target or not target:match("%S") then
    return nil
  end
  local clean_target = target:match("^%s*(.-)%s*$")

  local ext = state.markdown_extension
  if not clean_target:match("^%a+://") and not clean_target:match("%.%w+$") then
    clean_target = clean_target .. ext
  end
  return clean_target
end

---
-- Finds all valid markdown link targets on a single line of text.
-- @param line (string): The line to search.
-- @return (table): A list of processed link targets found on the line.
--
util.find_all_link_targets = function(line)
  local targets = {}

  -- Find standard markdown links: [text](target)
  for file in line:gmatch("%]%(<?([^)>]+)>?%)") do
    local processed = process_link_target(file)
    if processed then
      table.insert(targets, processed)
    end
  end

  -- Find wikilinks: [[target]]
  for file in line:gmatch("%[%[([^]]+)%]%]") do
    local processed = process_link_target(file)
    if processed then
      table.insert(targets, processed)
    end
  end

  return targets
end

---
-- Processes the text under the cursor to find and return a markdown link target, if one exists.
-- @param cursor (table): The cursor position `{row, col}`.
-- @param line (string): The content of the current line.
-- @return (string|nil): The processed link target if the cursor is on a link, otherwise nil.
--
util.process_link = function(cursor, line)
  cursor[2] = cursor[2] + 1 -- Adjust to 1-based indexing for find.
  -- Pattern for [title](file)
  local pattern1 = "%[(.-)%]%(<?([^)>]+)>?%)"
  local start_pos1 = 1
  while true do
    local match_start, match_end, _, file = line:find(pattern1, start_pos1)
    if not match_start then
      break
    end
    start_pos1 = match_end + 1

    if cursor[2] >= match_start and cursor[2] <= match_end then
      return process_link_target(file)
    end
  end
  -- Pattern for [[file]]
  local pattern2 = "%[%[(.-)%]%]"
  local start_pos2 = 1
  while true do
    local match_start, match_end, file = line:find(pattern2, start_pos2)
    if not match_start then
      break
    end
    start_pos2 = match_end + 1

    if cursor[2] >= match_start and cursor[2] <= match_end then
      local processed_link = process_link_target(file)
      if processed_link then
        return "./" .. processed_link
      end
    end
  end

  return nil
end

---
-- Displays a `vim.ui.select` prompt for the user to choose a wiki.
-- @param wiki_dirs (table): A list of configured wiki directory objects.
-- @param on_complete (function): Callback to execute with the selected wiki path.
--
local choose_wiki = function(wiki_dirs, on_complete)
  local items = {}
  for _, wiki_dir in ipairs(wiki_dirs) do
    table.insert(items, wiki_dir.name)
  end
  vim.ui.select(items, {
    prompt = "Select wiki:",
    format_item = function(item)
      return "  " .. item
    end,
  }, function(choice)
    if not choice then
      vim.notify("Wiki selection cancelled.", vim.log.levels.INFO, { title = "neowiki" })
      on_complete(nil)
      return
    end
    for _, wiki_dir in pairs(wiki_dirs) do
      if wiki_dir.name == choice then
        on_complete(wiki_dir.path)
        return
      end
    end
    vim.notify(
      "Error: Could not find path for selected wiki.",
      vim.log.levels.ERROR,
      { title = "neowiki" }
    )
    on_complete(nil)
  end)
end

---
-- Prompts the user to select a wiki if multiple are configured; otherwise,
-- directly provides the path to the single configured wiki.
-- @param config (table): The plugin configuration table.
-- @param on_complete (function): Callback to execute with the resulting wiki path.
--
util.prompt_wiki_dir = function(config, on_complete)
  if not config.wiki_dirs or #config.wiki_dirs == 0 then
    vim.notify("No wiki directories configured.", vim.log.levels.ERROR, { title = "neowiki" })
    if on_complete then
      on_complete(nil)
    end
    return
  end

  if #config.wiki_dirs > 1 then
    choose_wiki(config.wiki_dirs, on_complete)
  else
    on_complete(config.wiki_dirs[1].path)
  end
end

---
-- Finds all directories under a given search_path that contain the specified index_filename.
-- @param search_path (string): The base path to search from.
-- @param index_filename (string): The name of the index file (e.g., "index.md").
-- @return (table): A list of absolute paths to the directories containing the index file.
--
util.find_nested_roots = function(search_path, index_filename)
  local roots = {}
  if not search_path or search_path == "" then
    return roots
  end

  local search_pattern = vim.fs.joinpath("**", index_filename)
  local index_files = vim.fn.globpath(search_path, search_pattern, false, true)

  for _, file_path in ipairs(index_files) do
    local root_path = vim.fn.fnamemodify(file_path, ":p:h")
    table.insert(roots, root_path)
  end

  return roots
end

---
-- Normalizes a file path for case-insensitive and slash-consistent comparison.
-- @param path (string): The file path to normalize.
-- @return (string): The normalized path.
--
util.normalize_path_for_comparison = function(path)
  if not path then
    return ""
  end
  return path:lower():gsub("\\", "/"):gsub("//", "/")
end

---
-- Wraps a function in a keymap that can be repeated with the `.` operator.
-- It leverages the `repeat.vim` plugin functionality.
-- @param mode (string|table): The keymap mode (e.g., "n", "v").
-- @param lhs (string): The left-hand side of the mapping (must start with `<Plug>`).
-- @param rhs (function): The function to execute.
-- @return (string): The `lhs` of the mapping.
--
util.make_repeatable = function(mode, lhs, rhs)
  vim.validate({
    mode = { mode, { "string", "table" } },
    rhs = { rhs, "function" },
    lhs = { lhs, "string" },
  })
  if not vim.startswith(lhs, "<Plug>") then
    error("`lhs` should start with `<Plug>`, given: " .. lhs)
  end
  vim.keymap.set(mode, lhs, function()
    rhs()
    -- Make the action repeatable with '.'
    pcall(vim.fn["repeat#set"], vim.api.nvim_replace_termcodes(lhs, true, true, true))
  end)
  return lhs
end

return util
