-- lua/neowiki/health.lua
local M = {}

-- Safely try to load the utility module to ensure path resolution matches the plugin core
local has_util, util = pcall(require, "neowiki.util")

local start = vim.health.start
local ok = vim.health.ok
local warn = vim.health.warn
local error = vim.health.error
local info = vim.health.info

---
-- Runs the health check for the neowiki plugin.
-- Validates external tools, dependencies, and configuration paths.
-- This function is invoked via `:checkhealth neowiki`.
--
M.check = function()
  start("neowiki: External Tools")

  local tools = { rg = { name = "rg" } }
  local tool_status = { rg = util.check_binary_installed(tools.rg) }

  if tool_status.rg then
    ok("ripgrep (rg): Installed")
  else
    info("active tool: [Native Glob] (Slow)")
    warn(
      "ripgrep (rg) not found. Performance may degrade on large wikis during search and file operations."
    )
  end

  start("neowiki: Dependencies")

  local required_parsers = { "markdown", "markdown_inline" }
  for _, parser in ipairs(required_parsers) do
    -- Check if the queries are in the runtime paths and the parser are installed.
    -- Query the path to make it independent of the treesitter support inside neovim.
    -- Treesitter support in neovim is changing quickly therefore internal function can't be relied on beyond
    -- a major version. This approach is tested beginning with neovim 0.7
    local has_parser = vim.api.nvim_exec([[echo nvim_get_runtime_file("parser/]] .. parser .. [[.*", v:true)]], true)
    local has_queries = vim.api.nvim_exec([[echo nvim_get_runtime_file("queries/]] .. parser .. [[", v:true)]], true)
    if string.find(has_parser, parser) ~= nil and string.find(has_queries, parser) ~= nil then
      ok(string.format(" - Parser '%s': Installed", parser))
    else
      warn(string.format(" - Parser '%s': Missing", parser))
      info("   Install parser using a treesitter manager plugin like `neovim-treesitter/nvim-treesitter`.")
      info("   Or manual install the parser and queries.")
    end
  end

  local repeat_loaded = vim.g.loaded_repeat
  local repeat_installed = vim.fn.globpath(vim.o.rtp, "autoload/repeat.vim") ~= ""

  if repeat_loaded then
    ok("vim-repeat: Installed and loaded")
  elseif repeat_installed then
    ok("vim-repeat: Installed")
  else
    warn("vim-repeat: Not found")
    info("GTD task toggling and other actions will NOT be repeatable with '.'.")
    info("Install 'tpope/vim-repeat' to enable this feature.")
  end

  start("neowiki: Configuration")

  if not has_util then
    error("Critical: Could not load 'neowiki.util'. Cannot validate paths.")
    return
  end

  local config_ok, config = pcall(require, "neowiki.config")
  if not config_ok then
    error("Could not load neowiki.config module.")
    return
  end

  local wiki_dirs = config.wiki_dirs

  if not wiki_dirs then
    -- Default path check
    local default_path = vim.fn.expand("~/wiki")
    if vim.fn.isdirectory(default_path) == 1 then
      ok("Using default wiki path: " .. default_path)
    else
      warn("Using default wiki path: " .. default_path .. " (Directory does not exist)")
      info("Run :neowiki or open a file in that path to create it.")
    end
  else
    if wiki_dirs.path and wiki_dirs[1] == nil then
      wiki_dirs = { wiki_dirs }
    end

    if #wiki_dirs == 0 then
      warn("wiki_dirs is empty in configuration.")
    else
      for _, wiki in ipairs(wiki_dirs) do
        local resolved_path = util.resolve_path(wiki.path)

        if resolved_path and vim.fn.isdirectory(resolved_path) == 1 then
          ok(string.format("Wiki '%s' found at: %s", wiki.name or "Unnamed", resolved_path))
        else
          local display_path = resolved_path or wiki.path
          error(string.format("Wiki '%s' path not found: %s", wiki.name or "Unnamed", display_path))
        end
      end
    end
  end
end

return M
