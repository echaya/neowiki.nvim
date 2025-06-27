local state = require("neowiki.state")

local util = {}

-- Variable to ensure the fallback notification is only shown once per session.
local native_fallback_notified = false

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
-- Filters a table by applying a predicate function to each item.
-- This is a pure function that does not depend on any external state or modules.
-- @param list (table): The list to filter.
-- @param predicate (function): A function that takes an item and returns `true` to keep it or `false` to discard it.
-- @return (table): A new table containing only the items for which the predicate returned true.
--
util.filter_list = function(list, predicate)
  local result = {}
  for _, item in ipairs(list) do
    if predicate(item) then
      table.insert(result, item)
    end
  end
  return result
end

---
-- Generic file finder that uses fast command-line tools if available.
-- It prioritizes rg > fd > git, falling back to a native vim glob.
-- All returned paths are made absolute.
-- @param search_path (string) The absolute path of the directory to search.
-- @param search_term (string) The filename or extension to find.
-- @param search_type (string) 'name' to find by exact filename, or 'ext' for extension.
-- @return (table) A list of absolute paths to the found files.
--
local _find_files = function(search_path, search_term, search_type)
  local command
  local files
  local glob_pattern

  if vim.fn.executable("rg") == 1 then
    if search_type == "ext" then
      glob_pattern = "*" .. search_term
    else -- 'name'
      glob_pattern = search_term
    end
    command = { "rg", "--files", "--no-follow", "--crlf", "--iglob", glob_pattern, search_path }
    files = vim.fn.systemlist(command)
    if vim.v.shell_error == 0 then
      -- rg can return relative paths; ensure they are absolute.
      local absolute_files = {}
      for _, file in ipairs(files) do
        table.insert(absolute_files, vim.fn.fnamemodify(file, ":p"))
      end
      -- vim.notify("rg is used")
      return absolute_files
    end
  end

  if vim.fn.executable("fd") == 1 then
    if search_type == "ext" then
      -- fd expects the extension without the dot.
      command = { "fd", "--type=f", "--no-follow", "-e", search_term:sub(2), ".", search_path }
    else -- 'name'
      command = { "fd", "--type=f", "--no-follow", "--glob", search_term, ".", search_path }
    end
    files = vim.fn.systemlist(command)
    if vim.v.shell_error == 0 then
      -- fd with a base directory returns absolute paths.
      -- vim.notify("fd is used")
      return files
    end
  end

  if vim.fn.executable("git") == 1 and vim.fn.isdirectory(vim.fs.joinpath(search_path, ".git")) then
    command = { "git", "-C", search_path, "ls-files", "--cached", "--others", "--exclude-standard" }
    local all_files = vim.fn.systemlist(command)
    if vim.v.shell_error == 0 then
      local results = {}
      for _, file in ipairs(all_files) do
        local should_add = false
        if search_type == "ext" then
          if file:match(vim.pesc(search_term) .. "$") then
            should_add = true
          end
        else -- 'name'
          if vim.fn.fnamemodify(file, ":t") == search_term then
            should_add = true
          end
        end

        if should_add then
          -- git ls-files returns paths relative to `search_path`, so join them to make them absolute.
          table.insert(results, vim.fs.joinpath(search_path, file))
        end
      end
      -- vim.notify("git is used")
      return results
    end
  end

  -- 4. Fallback to native globpath if all CLI tools failed.
  if not native_fallback_notified then
    vim.notify(
      "rg, fd, and git not available or failed. Falling back to slower native search.",
      vim.log.levels.INFO,
      { title = "neowiki" }
    )
    native_fallback_notified = true
  end

  if search_type == "ext" then
    glob_pattern = "**/*" .. search_term
  else -- 'name'
    glob_pattern = "**/" .. search_term
  end
  -- globpath returns absolute paths when the base path is absolute.
  return vim.fn.globpath(search_path, glob_pattern, false, true)
end

---
-- Finds all wiki pages within a directory by calling the generic file finder.
-- @param search_path (string) The absolute path of the directory to search.
-- @param extension (string) The file extension to look for (e.g., ".md").
-- @return (table) A list of absolute paths to the found wiki pages.
--
util.find_wiki_pages = function(search_path, extension)
  -- Delegate to the main file-finding function with 'ext' type.
  return _find_files(search_path, extension, "ext")
end

---
-- Calculates the relative path from a starting directory to a target file path.
-- @param from_dir (string) The absolute path of the source directory.
-- @param to_path (string) The absolute path of the target file.
-- @return (string) The calculated relative path using forward slashes.
--
util.get_relative_path = function(from_dir, to_path)
  -- Step 1: Normalize paths to be absolute and use forward slashes.
  local from_abs = vim.fn.fnamemodify(from_dir, ":p"):gsub("\\", "/")
  local to_abs = vim.fn.fnamemodify(to_path, ":p"):gsub("\\", "/")

  -- Remove trailing slashes to ensure consistent splitting.
  from_abs = from_abs:gsub("/$", "")
  to_abs = to_abs:gsub("/$", "")

  local from_parts = vim.split(from_abs, "/")
  local to_parts = vim.split(to_abs, "/")

  -- On Windows, if the drives are different, a relative path is impossible.
  if vim.fn.has("win32") == 1 and from_parts[1]:lower() ~= to_parts[1]:lower() then
    return to_abs -- Return the absolute path as a fallback.
  end

  -- Step 2: Find the last common directory in the paths.
  local common_base_idx = 0
  -- We compare directories, so the loop limit is the shorter of the two directory paths.
  local min_len = math.min(#from_parts, #to_parts - 1)
  for i = 1, min_len do
    -- Perform case-insensitive comparison on Windows.
    local part_from = vim.fn.has("win32") == 1 and from_parts[i]:lower() or from_parts[i]
    local part_to = vim.fn.has("win32") == 1 and to_parts[i]:lower() or to_parts[i]

    if part_from ~= part_to then
      break
    end
    common_base_idx = i
  end

  local rel_parts = {}

  -- Step 3: For each remaining directory in `from_parts`, add a '..'
  local up_levels = #from_parts - common_base_idx
  for _ = 1, up_levels do
    table.insert(rel_parts, "..")
  end

  -- Step 4: Add the remaining parts of the `to_path`.
  for i = common_base_idx + 1, #to_parts do
    table.insert(rel_parts, to_parts[i])
  end

  -- If the resulting path is empty, it means the target is in the same directory.
  -- In this case, the relative path is just the filename.
  if #rel_parts == 0 then
    table.insert(rel_parts, to_parts[#to_parts])
  end

  local final_path = table.concat(rel_parts, "/")

  -- Prepend "./" to make it an explicit relative link for markdown consistency.
  if not final_path:match("^%./") and not final_path:match("^%.%./") then
    final_path = "./" .. final_path
  end

  return final_path
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

  local index_files = _find_files(search_path, index_filename, "name")

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

---
-- Opens a given URL in the default external application (e.g., a web browser).
-- This function is cross-platform and supports macOS, Linux, and Windows.
-- @param url (string): The URL to open.
--
util.open_external = function(url)
  if not url or url == "" then
    return
  end

  local os_name = vim.loop.os_uname().sysname
  local command

  if os_name == "Darwin" then
    -- Use `shellescape` without the second argument for POSIX shells.
    command = "open " .. vim.fn.shellescape(url)
  elseif os_name == "Linux" then
    command = "xdg-open " .. vim.fn.shellescape(url)
  elseif os_name:find("Windows") then
    -- Use `shellescape` with `true` for Windows' cmd.exe.
    command = "start " .. vim.fn.shellescape(url, true)
  end

  if command then
    vim.cmd("!" .. command)
    vim.notify("Opening in external app: " .. url, vim.log.levels.INFO, { title = "neowiki" })
  else
    vim.notify(
      "Unsupported OS for opening external links: " .. os_name,
      vim.log.levels.WARN,
      { title = "neowiki" }
    )
  end
end

return util
