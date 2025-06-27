local util = require("neowiki.util")
local config = require("neowiki.config")
local state = require("neowiki.state")

local finder = {}

-- Variable to ensure the fallback notification is only shown once per session.
local native_fallback_notified = false

---
-- Generic file finder that uses fast command-line tools if available.
-- It prioritizes rg > fd > git, falling back to a native vim glob.
-- All returned paths are made absolute.
-- @param search_path (string) The absolute path of the directory to search.
-- @param search_term (string) The filename or extension to find.
-- @param search_type (string) 'name' to find by exact filename, or 'ext' for extension.
-- @return (table) A list of absolute paths to the found files.
--
local find_files = function(search_path, search_term, search_type)
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
finder.find_wiki_pages = function(search_path, extension)
  -- Delegate to the main file-finding function with 'ext' type.
  return find_files(search_path, extension, "ext")
end

---
-- Finds all directories under a given search_path that contain the specified index_filename.
-- @param search_path (string): The base path to search from.
-- @param index_filename (string): The name of the index file (e.g., "index.md").
-- @return (table): A list of absolute paths to the directories containing the index file.
--
finder.find_nested_roots = function(search_path, index_filename)
  local roots = {}
  if not search_path or search_path == "" then
    return roots
  end

  local index_files = find_files(search_path, index_filename, "name")

  for _, file_path in ipairs(index_files) do
    local root_path = vim.fn.fnamemodify(file_path, ":p:h")
    table.insert(roots, root_path)
  end

  return roots
end

---
-- Finds the most specific wiki root that contains the given buffer path.
-- @param buf_path (string) The absolute path of the buffer to check.
-- @return (string|nil, string|nil, string|nil) Returns three paths: the primary 'wiki_root' for navigation
--   (e.g., jumping to index), the 'active_wiki_path' which is the most specific root
--   containing the buffer, and the 'ultimate_wiki_root' which is the top-most parent wiki.
--
finder.find_wiki_for_buffer = function(buf_path)
  local current_file_path = vim.fn.fnamemodify(buf_path, ":p")
  local normalized_current_path = util.normalize_path_for_comparison(current_file_path)
  local current_filename = vim.fn.fnamemodify(buf_path, ":t"):lower()

  -- Find all wiki roots that contain the current file.
  local matching_wikis = {}
  for _, wiki_info in ipairs(state.processed_wiki_paths) do
    local dir_to_check = wiki_info.normalized
    if not dir_to_check:find("/$") then
      dir_to_check = dir_to_check .. "/"
    end

    if normalized_current_path:find(dir_to_check, 1, true) == 1 then
      table.insert(matching_wikis, wiki_info)
    end
  end

  if #matching_wikis == 0 then
    return nil, nil, nil -- No matching wiki found
  end

  -- The list is pre-sorted by path length (desc), so the first match is the most specific.
  local most_specific_match = matching_wikis[1]
  local wiki_root
  local active_wiki_path = most_specific_match.resolved
  -- The last match is the shortest path, making it the ultimate parent root.
  local ultimate_wiki_root = matching_wikis[#matching_wikis].resolved

  -- If we are in an index file of a nested wiki, the effective root for jumping
  -- to index should be the parent wiki's root.
  if current_filename == config.index_file:lower() and #matching_wikis >= 2 then
    wiki_root = matching_wikis[2].resolved
  else
    -- Otherwise, the most specific path is the root.
    wiki_root = most_specific_match.resolved
  end

  return wiki_root, active_wiki_path, ultimate_wiki_root
end

return finder
