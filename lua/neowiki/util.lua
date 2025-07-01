local util = {}
local is_windows = vim.fn.has("win32") == 1

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

util.delete_target_buffer = function(abs_path)
  local old_bufnr = vim.fn.bufnr(abs_path)
  if old_bufnr ~= -1 then
    vim.cmd("bdelete! " .. old_bufnr)
  end
end

--- Normalizes a given path for reliable comparison.
-- @param path (string) The file or directory path.
-- @return (string) A clean, absolute path using forward slashes.
local normalize_path = function(path)
  -- 1. Get the absolute path.
  local abs_path = vim.fn.fnamemodify(path, ":p")
  -- 2. Standardize to forward slashes.
  abs_path = abs_path:gsub("\\", "/")
  -- 3. Collapse any multiple slashes into a single one (e.g., "a//b" -> "a/b").
  --    This is critical to prevent empty strings when splitting the path.
  abs_path = abs_path:gsub("//+", "/")
  -- 4. Remove any trailing slash to ensure consistency before splitting.
  return abs_path:gsub("/$", "")
end

--- Calculates the relative path from a source directory to a target file/directory.
-- @param from_path (string) The absolute or relative path of the source. Can be a directory or a file.
-- @param to_path (string) The absolute or relative path of the target file or directory.
-- @return (string) The relative path from `from_path` to `to_path`.
function util.get_relative_path(from_path, to_path)
  -- Step 1: Determine the correct base directory from `from_path`.
  local from_base_path
  -- Check if the provided 'from_path' is a directory.
  if vim.fn.isdirectory(from_path) == 1 then
    -- If it's a directory, use it directly.
    from_base_path = from_path
  else
    -- If it's a file, get its containing directory using ':h'.
    from_base_path = vim.fn.fnamemodify(from_path, ":h")
  end

  -- Normalize both paths.
  local from_dir = normalize_path(from_base_path)
  local to_abs = normalize_path(to_path)

  local from_parts = vim.split(from_dir, "/")
  local to_parts = vim.split(to_abs, "/")

  -- On Windows, if the drives are different, a relative path is not possible.
  if
    is_windows
    and from_parts[1]
    and to_parts[1]
    and from_parts[1]:lower() ~= to_parts[1]:lower()
  then
    return to_abs -- Fallback to the absolute path of the target.
  end

  -- Step 2: Find the last common directory in the paths.
  local common_base_idx = 0
  local max_common_len = math.min(#from_parts, #to_parts)
  for i = 1, max_common_len do
    local part_from = is_windows and from_parts[i]:lower() or from_parts[i]
    local part_to = is_windows and to_parts[i]:lower() or to_parts[i]

    if part_from ~= part_to then
      break
    end
    common_base_idx = i
  end

  local rel_parts = {}

  -- Step 3: For each directory we need to move up from `from_dir`, add '..'.
  for _ = common_base_idx + 1, #from_parts do
    table.insert(rel_parts, "..")
  end

  -- Step 4: Add the remaining parts of the `to_path` to navigate to the target.
  for i = common_base_idx + 1, #to_parts do
    table.insert(rel_parts, to_parts[i])
  end

  -- If paths resolve to the same directory, the relative path is './'.
  if #rel_parts == 0 then
    return "./"
  end

  local final_path = table.concat(rel_parts, "/")

  -- Prepend "./" if the path doesn't already indicate it's relative.
  if not final_path:match("^%.%.?/") then
    final_path = "./" .. final_path
  end

  -- If the result is just '.', return './' for consistency in links.
  if final_path == "." then
    return "./"
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
  return normalize_path(path):lower()
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

-- Populates the quickfix list with the provided broken link information and opens it.
-- @param broken_links_info (table) A list of objects, each with `filename`, `lnum` and `text`
--
util.populate_quickfix_list = function(quickfix_info, title)
  if not quickfix_info or #quickfix_info == 0 then
    return
  end

  local qf_list = {}
  for _, info in ipairs(quickfix_info) do
    table.insert(qf_list, {
      filename = info.filename,
      lnum = info.lnum,
      text = info.text,
    })
  end

  if #qf_list > 0 then
    -- Set the quickfix list with our findings.
    vim.fn.setqflist(qf_list)
    -- Open the quickfix window to display the list.
    vim.schedule(function()
      vim.cmd("copen")
    end)

    -- Use the provided title or a sensible default.
    local notification_message = title or (#qf_list .. " item(s) added to quickfix list.")
    vim.notify(notification_message, vim.log.levels.INFO, { title = "neowiki" })
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

  if util.is_web_link(clean_target) then
    return clean_target
  end

  local has_extension = clean_target:match("%.%w+$")
  if not has_extension then
    clean_target = clean_target .. ext
  end
  return clean_target
end

---
-- Reads a file, applies a list of replacements, and writes it back.
-- @param file_path (string): The absolute path to the file to modify.
-- @param replacements (table): A list of tables, each with a `search` and `replace` key.
--   e.g., {{ search = "foo", replace = "bar" }, { search = "baz", replace = "qux" }}
-- @return (boolean, string|nil): Returns true on success, or false and an error message.
--
util.replace_in_file = function(file_path, replacements)
  -- Ensure the file is readable before proceeding.
  if vim.fn.filereadable(file_path) == 0 then
    return false, "File not readable: " .. file_path
  end

  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return false, "Failed to read file: " .. file_path
  end

  local was_modified = false
  for i, line in ipairs(lines) do
    local line_was_modified = false
    for _, rep in ipairs(replacements) do
      -- Escape the search string to ensure it's treated as a literal string.
      -- This prevents issues with special characters in filenames or link formats.
      local search_pattern = vim.pesc(rep.search)
      local new_line, count = line:gsub(search_pattern, rep.replace)
      if count > 0 then
        line = new_line -- Use the updated line for any subsequent replacements
        line_was_modified = true
      end
    end

    if line_was_modified then
      lines[i] = line
      was_modified = true
    end
  end

  if was_modified then
    local write_ok, write_err = pcall(vim.fn.writefile, lines, file_path)
    if not write_ok then
      return false, "Failed to write to file: " .. (write_err or "unknown error")
    end
  end

  return true
end

--- Joins a base path and a filename and resolves it to a full, canonical path.
--
-- @param file_path string The base path (e.g., a directory). Can be relative or absolute.
-- @param filename string The name of the file or sub-directory to append.
-- @return string The absolute, canonical path to the resulting file or directory.
--
util.join_path = function(file_path, filename)
  local joined_path = vim.fs.joinpath(file_path, filename)
  return vim.fn.resolve(joined_path)
end
return util
