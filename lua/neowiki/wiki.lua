local util = require("neowiki.util")
local finder = require("neowiki.finder")
local wiki_action = require("neowiki.wiki_action")
local config = require("neowiki.config")
local state = require("neowiki.state")
local wiki = {}

---
-- Gets the default wiki path, which is `~/wiki`.
-- @return (string): The default wiki path.
--
wiki.get_default_path = function()
  return vim.fs.joinpath(vim.loop.os_homedir(), "wiki")
end

---
-- Sets up buffer-local variables and keymaps if the current buffer is a markdown file
-- located within a configured wiki directory.
-- This function is triggered by the BufEnter autocommand.
--
wiki.setup_buffer = function()
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
    wiki_action.create_buffer_keymaps(0)
  end
end

---
-- Finds a markdown link under the cursor and opens the target file.
-- @param open_cmd (string|nil): Optional command for opening the file (e.g., 'vsplit').
--
wiki.follow_link = function(open_cmd)
  if not wiki_action.check_in_neowiki() then
    return
  end
  local active_path
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path and buf_path ~= "" then
    active_path = vim.fn.fnamemodify(buf_path, ":h")
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.fn.getline(cursor[1])
  local filename = wiki_action.process_link(cursor, line)

  if filename and filename:len() > 0 then
    -- try open_external if the filename is a url
    if util.is_web_link(filename) then
      util.open_external(filename)
      return
    end

    local full_path = util.join_path(active_path, filename)

    -- reuse the current floating window to open the new link.
    if util.is_float() and not open_cmd then
      local bn_to_open = vim.fn.bufnr(full_path, true)
      vim.api.nvim_win_set_buf(0, bn_to_open)
    else
      wiki_action.open_file(full_path, open_cmd)
    end
  else
    vim.notify("No link under cursor.", vim.log.levels.WARN, { title = "neowiki" })
  end
end

---
-- Public function to open a wiki's index page in the current window.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
wiki.open_wiki = function(name)
  wiki_action.open_wiki_index(name)
end

---
-- Public function to open a wiki's index page in a new tab.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
wiki.open_wiki_new_tab = function(name)
  wiki_action.open_wiki_index(name, "tabnew")
end

---
-- Public function to open a wiki's index page in a floating window.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
wiki.open_wiki_floating = function(name)
  wiki_action.open_wiki_index(name, "float")
end

---
-- Creates a new wiki page from the visual selection, replacing the selection with a link.
-- This function handles the buffer text manipulation and delegates the file system
-- operations to wiki_action.create_page_from_filename.
-- @param open_cmd (string|nil): Optional command for opening the new file.
--
wiki.create_or_open_wiki_file = function(open_cmd)
  if not wiki_action.check_in_neowiki() then
    return
  end
  local selection_start_pos = vim.fn.getpos("'<")
  local selection_end_pos = vim.fn.getpos("'>")
  local start_row = selection_start_pos[2] - 1
  local start_col = selection_start_pos[3] - 1
  local end_row = selection_end_pos[2] - 1
  local end_col = selection_end_pos[3]
  local end_line_content = vim.api.nvim_buf_get_lines(0, end_row, end_row + 1, false)[1] or ""
  if end_col > #end_line_content then
    start_col = 0
    end_col = #end_line_content
  end
  local selected_lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
  local link_display_text = ((selected_lines[1] or ""):match("^%s*(.-)%s*$"))
  if link_display_text == "" then
    vim.notify(
      "No text selected on the first line; cannot create link.",
      vim.log.levels.WARN,
      { title = "neowiki" }
    )
    return
  end

  local filename = link_display_text:gsub(" ", "_"):gsub("[\\?%%*:|'\"<>]", "")
    .. state.markdown_extension
  local filename_link = "[" .. link_display_text .. "](" .. "./" .. filename .. ")"
  vim.api.nvim_buf_set_text(0, start_row, start_col, end_row, end_col, { filename_link })
  wiki_action.create_page_from_filename(filename, open_cmd)
end

---
-- Jumps to the config.index_file of the wiki that the current buffer belongs to.
--
wiki.jump_to_index = function()
  local root = vim.b[0].wiki_root
  if root and root ~= "" then
    local index_path = util.join_path(root, config.index_file)
    wiki_action.open_file(index_path)
  else
    vim.notify(
      "Not inside a neowiki wiki. Cannot jump to index.",
      vim.log.levels.WARN,
      { title = "neowiki" }
    )
  end
end

---
-- Deletes the current wiki page after confirmation. Prevents deletion of the
-- root config.index_file and then triggers a cleanup of broken links.
--
wiki.delete_wiki = function()
  -- Pre-check to ensure we are in a valid wiki context.
  if not wiki_action.check_in_neowiki() then
    return
  end
  -- Delegate the complex logic to the wiki_action module.
  wiki_action.delete_wiki_page()
end

---
-- Finds broken links, displays them, and prompts the user for action:
-- populate quickfix, remove lines, or cancel.
--
wiki.cleanup_broken_links = function()
  local broken_links_info = finder.find_broken_links_in_buffer()

  if not broken_links_info or #broken_links_info == 0 then
    vim.notify("No broken links were found.", vim.log.levels.INFO, { title = "neowiki" })
    return
  end

  local prompt_lines = {
    string.format("Found %d line(s) with broken links:", #broken_links_info),
    "", -- Add a blank line for readability.
  }
  for _, info in ipairs(broken_links_info) do
    -- Truncate long lines for a cleaner prompt.
    local display_line = info.text
    if #display_line > 70 then
      display_line = display_line:sub(1, 67) .. "..."
    end
    table.insert(prompt_lines, string.format("L%d: %s", info.lnum, display_line))
  end
  table.insert(prompt_lines, "\nWhat would you like to do?")
  local prompt_message = table.concat(prompt_lines, "\n")

  -- The '&' creates a hotkey for each option.
  local choice = vim.fn.confirm(prompt_message, "&Quickfix\n&Remove Lines\n&Cancel")

  if choice == 1 then
    util.populate_quickfix_list(broken_links_info)
  elseif choice == 2 then
    wiki_action.remove_lines_with_broken_links(broken_links_info)
  else -- choice is 3 (Cancel) or 0 (dialog closed).
    vim.notify("Link cleanup canceled.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

---
-- Finds a wiki page within the current wiki and inserts a relative link to it.
-- It uses a prompt from wiki_action to select the page.
--
wiki.insert_wiki_link = function()
  if not wiki_action.check_in_neowiki() then
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

  wiki_action.prompt_wiki_page(search_root, current_buf_path, on_page_select)
end

wiki.rename_wiki_page = function()
  -- Pre-check to ensure we are in a valid wiki context.
  if not wiki_action.check_in_neowiki() then
    return
  end
  wiki_action.rename_wiki_page()
end

return wiki
