local config = require("neowiki.config")
local util = require("neowiki.util")
local finder = require("neowiki.finder")
local wiki = require("neowiki.wiki")
local state = require("neowiki.state")

local M = {}
local markdown_patterns = {
  "*.md",
  "*.markdown",
  "*.mdown",
  "*.mkd",
}

--- Public API ---

M.VERSION = "0.2.0"
M.open_wiki = wiki.open_wiki
M.open_wiki_new_tab = wiki.open_wiki_new_tab
M.open_wiki_floating = wiki.open_wiki_floating

--- Private Functions ---

---
-- Processes the user's configuration to identify all wiki root directories,
-- including nested ones, and returns them as a sorted list.
-- @param local_config (table) The merged configuration table.
-- @return {table} A list of processed wiki path objects, sorted by path length descending.
--
local function process_wiki_paths(local_config)
  local manual_wiki_dirs = {}

  if local_config.wiki_dirs and type(local_config.wiki_dirs) == "table" then
    for _, wiki_dir in ipairs(local_config.wiki_dirs) do
      local resolved_path = util.resolve_path(wiki_dir.path)
      if resolved_path then
        util.ensure_path_exists(resolved_path)
        table.insert(manual_wiki_dirs, resolved_path)
      end
    end
  else
    -- Fallback to default path if no wiki_dirs are provided.
    local default_path = wiki.get_default_path()
    local resolved_path = util.resolve_path(default_path)
    if resolved_path then
      util.ensure_path_exists(resolved_path)
      table.insert(manual_wiki_dirs, resolved_path)
    end
  end

  local all_roots_set = {}
  for _, path in ipairs(manual_wiki_dirs) do
    all_roots_set[path] = true

    -- Find nested roots using the full index_file name from config.
    local nested_roots = finder.find_nested_roots(path, local_config.index_file)
    for _, nested_root in ipairs(nested_roots) do
      all_roots_set[nested_root] = true
    end
  end

  local processed_wiki_paths = {}
  for path, _ in pairs(all_roots_set) do
    table.insert(processed_wiki_paths, {
      resolved = path,
      normalized = util.normalize_path_for_comparison(path),
    })
  end

  util.sort_wiki_paths(processed_wiki_paths)
  return processed_wiki_paths
end

---
-- Validates the 'index_file' setting from the configuration.
-- Ensures it has a supported Markdown extension and extracts the base name
-- and extension into the state module. Resets to a default if invalid.
--
local function process_index_file()
  -- Parse config.index_file to populate state.index_name and state.markdown_extension.
  local index_file = config.index_file
  local ext_part = vim.fn.fnamemodify(index_file, ":e")

  local is_supported = false
  if ext_part == "" or ext_part == index_file then
    vim.notify(
      "`index_file` must have an extension. Reverting back to default, `index.md`.",
      vim.log.levels.WARN,
      { title = "neowiki" }
    )
  else
    local user_pattern = "*." .. ext_part:lower()
    for _, pattern in ipairs(markdown_patterns) do
      if pattern == user_pattern then
        is_supported = true
        break
      end
    end
    if not is_supported then
      vim.notify(
        "Invalid extension '."
          .. ext_part
          .. "' is not in the supported list. Reverting back to default, `index.md`.",
        vim.log.levels.WARN,
        { title = "neowiki" }
      )
    end
  end

  -- If validation failed at any point, reset to a safe default.
  if not is_supported then
    config.index_file = "index.md"
    ext_part = "md"
  end

  state.index_name = vim.fn.fnamemodify(config.index_file, ":t:r")
  state.markdown_extension = "." .. ext_part
end

---
-- Initializes the neowiki plugin with user-provided options.
-- @param opts (table|nil): User configuration options to override defaults.
--
M.setup = function(opts)
  opts = opts or {}
  -- Merge user config into the default config.
  local local_config = util.deep_merge(config, opts)
  for k, v in pairs(local_config) do
    config[k] = v
  end

  process_index_file()

  -- Normalize the `wiki_dirs` structure for consistency.
  if config.wiki_dirs and type(config.wiki_dirs) == "table" then
    if config.wiki_dirs.path and config.wiki_dirs[1] == nil then
      config.wiki_dirs = { config.wiki_dirs } -- Normalize single wiki_dir object into a list
    end
  end
  state.processed_wiki_paths = process_wiki_paths(config)

  -- Autocommand to set up keymaps when entering a markdown file.
  local neowiki_augroup = vim.api.nvim_create_augroup("neowiki", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = neowiki_augroup,
    pattern = markdown_patterns,
    callback = function()
      wiki.setup_buffer()
      if vim.b.wiki_root then
        require("neowiki.gtd").attach_to_buffer(vim.api.nvim_get_current_buf())
      end
    end,
    desc = "Set neowiki keymaps for markdown files in wiki directories.",
  })
end

return M

