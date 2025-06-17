-- lua/neowiki/state.lua

---@class neowiki.State
---@field public processed_wiki_paths table A list of processed wiki root path objects.
---@field public index_name string|nil The base name of the index file (e.g., "index").
---@field public markdown_extension string|nil The extension for markdown files (e.g., ".md").
local M = {
  -- A list of all discovered wiki roots, sorted by path length descending
  -- to ensure the most specific path is matched first.
  -- Each item is a table: { resolved = "...", normalized = "..." }
  processed_wiki_paths = {},

  -- These values are derived from config.index_file during setup.
  index_name = nil,
  markdown_extension = nil,
}

return M
