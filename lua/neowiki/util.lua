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

---
-- Helper function to detect if the current window is a float.
-- @return boolean True if the window is a float, false otherwise.
--
util.is_float = function()
  local win_id = vim.api.nvim_get_current_win()
  local conf = vim.api.nvim_win_get_config(win_id)
  return conf.relative and conf.relative ~= ""
end

util.is_web_link = function(target)
  if not target or target == "" then
    return false
  end
  -- Returns true if the string starts with a protocol like http:// or with www.
  return target:match("^%a+://") or target:match("^www%.")
end

---
-- Populates the quickfix list with the provided broken link information and opens it.
-- @param broken_links_info (table) A list of objects, each with an `lnum` and `line`.
--
util.populate_quickfix_list = function(quickfix_info)
  local qf_list = {}
  -- Get the filename of the current buffer to make quickfix entries jumpable.
  local filename = vim.api.nvim_buf_get_name(0)

  for _, info in ipairs(quickfix_info) do
    table.insert(qf_list, {
      filename = filename,
      lnum = info.lnum,
      text = info.line,
    })
  end

  if #qf_list > 0 then
    -- Set the quickfix list with our findings.
    vim.fn.setqflist(qf_list)
    -- Open the quickfix window to display the list.
    vim.cmd("copen")
    vim.notify(
      #qf_list .. " broken link(s) added to quickfix list.",
      vim.log.levels.INFO,
      { title = "neowiki" }
    )
  end
end

---
-- Processes a raw link target, cleaning it and appending the configured extension if necessary.
-- @param target (string): The raw link target string (e.g., "my page").
-- @param ext (string): The extension (e.g., ".md").
-- @return (string|nil): The processed link target (e.g., "my_page.md"), or nil.
--
util.process_link_target = function(target, ext)
  if not target or not target:match("%S") then
    return nil
  end
  local clean_target = target:match("^%s*(.-)%s*$")

  if not util.is_web_link(clean_target) then
    clean_target = clean_target .. ext
  end
  return clean_target
end

return util
