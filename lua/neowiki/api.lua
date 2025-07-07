-- lua/neowiki/api.lua
local util = require("neowiki.util")
local finder = require("neowiki.core.finder")
local actions = require("neowiki.core.actions")
local ui = require("neowiki.core.ui")
local keymaps = require("neowiki.keymaps")

local M = {}

---
-- Sets up buffer-local variables and keymaps if the current buffer is a markdown file
-- located within a configured wiki directory.
-- This function is triggered by the BufEnter autocommand.
--
M.setup_buffer = function()
  if vim.bo.filetype ~= "markdown" then
    return
  end

  local buf_path = vim.api.nvim_buf_get_name(0)
  if not buf_path or buf_path == "" then
    return
  end

  local wiki_root, active_wiki_path, ultimate_wiki_root = finder.find_wiki_for_buffer(buf_path)
  if wiki_root and active_wiki_path and ultimate_wiki_root then
    vim.b[0].wiki_root = wiki_root
    vim.b[0].active_wiki_path = active_wiki_path
    vim.b[0].ultimate_wiki_root = ultimate_wiki_root
    keymaps.create_buffer_keymaps(0)

    -- Initialize navigation history if this is the first wiki page entered.
    actions.initialize_history_if_needed(buf_path)
  end
end

---
-- Finds a markdown link under the cursor and opens the target file.
-- @param open_cmd (string|nil): Optional command for opening the file (e.g., 'vsplit').
--
M.follow_link = function(open_cmd)
  if not actions.check_in_neowiki() then
    return
  end
  actions.follow_link(open_cmd)
end

---
-- Public function to open a wiki's index page in the current window.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
M.open_wiki = function(name)
  actions.open_wiki_index(name)
end

---
-- Public function to open a wiki's index page in a new tab.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
M.open_wiki_new_tab = function(name)
  actions.open_wiki_index(name, "tabnew")
end

---
-- Public function to open a wiki's index page in a floating window.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
M.open_wiki_floating = function(name)
  actions.open_wiki_index(name, "float")
end

---
-- Creates a new wiki page from the visual selection, replacing the selection with a link.
-- This function handles the buffer text manipulation and delegates the file system
-- operations to wiki_action.create_page_from_filename.
-- @param open_cmd (string|nil): Optional command for opening the new file.
--
M.create_or_open_wiki_file = function(open_cmd)
  if not actions.check_in_neowiki() then
    return
  end
  local filename = actions.gen_link_from_selection()
  if not filename then
    return
  end
  actions.create_page_from_filename(filename, open_cmd)
end

---
-- Jumps to the config.index_file of the wiki that the current buffer belongs to.
--
M.jump_to_index = function()
  if not actions.check_in_neowiki() then
    return
  end
  actions.jump_to_index()
end

---
-- Finds broken links, displays them, and prompts the user for action:
-- populate quickfix, remove lines, or cancel.
--
M.cleanup_broken_links = function()
  if not actions.check_in_neowiki() then
    return
  end
  actions.cleanup_broken_links()
end

---
-- Finds a wiki page within the current wiki and inserts a relative link to it.
-- It uses a prompt from ui.prompt_wiki_page to select the page.
--
M.insert_wiki_link = function()
  if not actions.check_in_neowiki() then
    return
  end

  local search_root = vim.b[0].ultimate_wiki_root
  local current_buf_path = vim.api.nvim_buf_get_name(0)

  local function on_page_select(selected_path)
    if not selected_path then
      return -- Operation was cancelled by the user.
    end

    local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
    local relative_path = util.get_relative_path(current_dir, selected_path)
    local link_name = vim.fn.fnamemodify(selected_path, ":t:r") -- Filename without extension
    local link_text = string.format("[%s](%s)", link_name, relative_path)

    -- Get the current cursor line to insert the new link below it.
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    vim.api.nvim_buf_set_lines(0, cursor_line, cursor_line, false, { link_text })
  end

  ui.prompt_wiki_page(search_root, current_buf_path, on_page_select)
end

M.rename_wiki_page = function()
  if not actions.check_in_neowiki() then
    return
  end
  actions.rename_wiki_page()
end

---
-- Deletes the current wiki page after confirmation. Prevents deletion of the
-- root config.index_file and then triggers a cleanup of broken links.
--
M.delete_wiki_page = function()
  if not actions.check_in_neowiki() then
    return
  end
  -- Delegate the complex logic to the actions module.
  actions.delete_wiki_page()
end

M.navigate_back = function()
  if not actions.check_in_neowiki() then
    return
  end
  actions.navigate_back()
end

M.navigate_forward = function()
  if not actions.check_in_neowiki() then
    return
  end
  actions.navigate_forward()
end

return M
