-- lua/neowiki/core/ui.lua
local util = require("neowiki.util")
local finder = require("neowiki.core.finder")
local link = require("neowiki.core.link")
local config = require("neowiki.config")
local state = require("neowiki.state")

local M = {}

---
-- Opens a buffer in a styled floating window.
-- @param buffer_number (number): The buffer number to open.
--
M.open_file_in_float = function(buffer_number)
  -- Internal defaults to ensure the function is robust against malformed user config.
  -- These values should mirror the defaults exposed in `config.lua`.
  local internal_defaults = {
    open = {
      relative = "editor",
      width = 0.9,
      height = 0.9,
      border = "rounded",
    },
    style = {},
  }

  -- Merge the user's config from the global `config` object over our internal defaults.
  local final_float_config = util.deep_merge(internal_defaults, config.floating_wiki or {})

  local win_config = final_float_config.open
  local win_style_options = final_float_config.style

  local width = win_config.width > 0
      and win_config.width < 1
      and math.floor(vim.o.columns * win_config.width)
    or win_config.width
  local height = win_config.height > 0
      and win_config.height < 1
      and math.floor(vim.o.lines * win_config.height)
    or win_config.height

  local final_win_config = vim.deepcopy(win_config)
  final_win_config.width = width
  final_win_config.height = height

  if final_win_config.row == nil then
    final_win_config.row = math.floor((vim.o.lines - height) / 2)
  end
  if final_win_config.col == nil then
    final_win_config.col = math.floor((vim.o.columns - width) / 2)
  end

  local win_id = vim.api.nvim_open_win(buffer_number, true, final_win_config)

  for key, value in pairs(win_style_options) do
    -- Using pcall is still a good idea to protect against invalid option names.
    pcall(function()
      vim.wo[win_id][key] = value
    end)
  end
end

---
--- Safely prompts the user for input, handling cancellations gracefully.
-- @param opts (table): The options table passed directly to vim.ui.input.
-- @param on_confirm (function): The callback to execute. It receives the user's
--   input as a string, or nil if the input was empty or cancelled.
--
local safe_ui_input = function(opts, on_confirm)
  -- -- for debuggging
  -- vim.ui.input(opts, on_confirm)
  local success = pcall(vim.ui.input, opts, function(input)
    on_confirm(input)
  end)
  -- on_confirm should handle nil as input
  if not success then
    on_confirm(nil)
  end
end

---
-- Safely prompts the user for selct, handling cancellations gracefully.
-- errors when the user cancels with <Esc> or <C-c>.
-- @param items (table): The items table passed directly to vim.ui.input.
-- @param opts (table): The options table passed directly to vim.ui.input.
-- @param on_confirm (function): The callback to execute. It receives the user's
--   input as a string, or nil if the input was empty or cancelled.
--
local safe_ui_select = function(items, opts, on_choice)
  -- -- for debuggging
  -- vim.ui.select(items,items,opts)
  local success = pcall(vim.ui.select, items, opts, function(input)
    on_choice(input)
  end)
  -- on_confirm should handle nil as input
  if not success then
    on_choice(nil)
  end
end

---
-- Displays a `vim.ui.select` prompt for the user to choose a wiki.
-- @param wiki_dirs (table): A list of configured wiki directory objects.
-- @param on_complete (function): Callback to execute with the selected wiki path.
--
local function choose_wiki(wiki_dirs, on_complete)
  local items = {}
  for _, wiki_dir in ipairs(wiki_dirs) do
    table.insert(items, wiki_dir.name)
  end
  local options = {
    prompt = "Select wiki:",
    format_item = function(item)
      return "  " .. item
    end,
  }
  safe_ui_select(items, options, function(choice)
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
M.prompt_wiki_dir = function(user_config, on_complete)
  if not user_config.wiki_dirs or #user_config.wiki_dirs == 0 then
    vim.notify("No wiki directories configured.", vim.log.levels.ERROR, { title = "neowiki" })
    if on_complete then
      on_complete(nil)
    end
    return
  end

  if #user_config.wiki_dirs > 1 then
    choose_wiki(user_config.wiki_dirs, on_complete)
  else
    on_complete(user_config.wiki_dirs[1].path)
  end
end

---
-- Finds all wiki pages and filters out the current file and index files.
-- @param root (string) The absolute path of the ultimate wiki root to search within.
-- @param current_path (string) The absolute path of the current buffer to exclude.
-- @return (table|nil) A list of filtered page paths, or nil if no pages were found initially.
local function get_filtered_pages(root, current_path)
  -- Step 1: Find all pages in the given root directory.
  local all_pages = finder.find_wiki_pages(root, state.markdown_extension)
  if not all_pages or vim.tbl_isempty(all_pages) then
    vim.notify("No wiki pages found in: " .. root, vim.log.levels.INFO, { title = "neowiki" })
    return nil -- Indicate that the initial search found no pages.
  end

  -- Step 2: Prepare values needed for the filtering predicate.
  local current_file_path_normalized = util.normalize_path_for_comparison(current_path)
  local index_filename = vim.fn.fnamemodify(config.index_file, ":t")

  -- Step 3: Filter the list using a predicate function.
  local filtered = util.filter_list(all_pages, function(path)
    local page_filename = vim.fn.fnamemodify(path, ":t")
    -- Rule: Exclude index files.
    if page_filename == index_filename then
      return false
    end

    -- Rule: Exclude the current file itself.
    local normalized_path = util.normalize_path_for_comparison(path)
    if normalized_path == current_file_path_normalized then
      return false
    end

    return true -- Keep the item if no rules match.
  end)

  return filtered
end

---
-- Finds all linkable wiki pages and prompts the user to select one.
-- @param search_root (string) The absolute path of the ultimate wiki root to search within.
-- @param current_buf_path (string) The absolute path of the current buffer, to exclude it from results.
-- @param on_complete (function) A callback function to execute with the full path of the selected page.
--
M.prompt_wiki_page = function(search_root, current_buf_path, on_complete)
  -- Main logic for prompt_wiki_page starts here.
  local filtered_pages = get_filtered_pages(search_root, current_buf_path)

  -- Abort if the initial search returned nothing.
  if not filtered_pages then
    return
  end

  -- Abort if, after filtering, no linkable pages remain.
  if vim.tbl_isempty(filtered_pages) then
    vim.notify("No other linkable pages found.", vim.log.levels.INFO, { title = "neowiki" })
    return
  end

  -- Format the remaining pages for the UI selector.
  local items = {}
  for _, path in ipairs(filtered_pages) do
    table.insert(items, {
      display = vim.fn.fnamemodify(path, ":." .. search_root), -- Path relative to root
      path = path, -- Full absolute path
    })
  end

  -- Display the UI selector and handle the user's choice.
  local options = {
    prompt = "Select a page to link:",
    format_item = function(item)
      return " " .. item.display
    end,
  }
  safe_ui_select(items, options, function(choice)
    if not choice then
      vim.notify("Wiki link insertion cancelled.", vim.log.levels.INFO, { title = "neowiki" })
      on_complete(nil) -- User cancelled the prompt.
      return
    end
    on_complete(choice.path) -- Execute the callback with the chosen path.
  end)
end

---
-- Prompts the user to select a target file for an action (rename/delete).
-- It contextually asks whether to act on the linked file or the current file.
-- @param action_verb (string) The verb to use in the prompt (e.g., "Rename", "Delete").
-- @param callback (function) The function to call with the chosen file path.
M.prompt_for_action_target = function(action_verb, callback)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local link_target = link.process_link(cursor, line, nil)
  local current_buf_path = vim.api.nvim_buf_get_name(0)
  local path_to_action = nil
  local additional_fallback = nil

  if link_target and not util.is_web_link(link_target) then
    local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
    local linked_file_path = util.join_path(current_dir, link_target)
    local linked_filename = vim.fn.fnamemodify(linked_file_path, ":t")
    local current_filename = vim.fn.fnamemodify(current_buf_path, ":t")

    local prompt = string.format(
      "%s linked file ('%s') or current file ('%s')?",
      action_verb,
      linked_filename,
      current_filename
    )
    local _, choice = pcall(vim.fn.confirm, prompt, "&Linked File\n&Current File\n&Cancel")
    if choice == 1 then -- User chose "Linked File"
      path_to_action = linked_file_path
      additional_fallback = current_buf_path -- The current buffer is the other option
    elseif choice == 2 then -- User chose "Current File"
      path_to_action = current_buf_path
    else -- User cancelled
      vim.notify(action_verb .. " operation canceled.", vim.log.levels.INFO, { title = "neowiki" })
      return
    end
  else
    -- If not on a link, the action always targets the current file.
    path_to_action = current_buf_path
  end

  -- If a path has been determined, calculate fallbacks and execute the callback.
  if path_to_action then
    local fallback_targets = {}
    local wiki_root, _ = finder.find_wiki_for_buffer(path_to_action)
    if wiki_root then
      local wiki_root_index_file = util.join_path(wiki_root, config.index_file)
      fallback_targets[wiki_root_index_file] = true
    end
    if additional_fallback then
      fallback_targets[additional_fallback] = true
    end
    callback(path_to_action, fallback_targets)
  end
end

---
-- Prompts the user to enter new file name
-- @param default_name (string) The original_name of the file
-- @param callback (function) The callback to process input new file
--
M.prompt_rename_input = function(default_name, callback)
  local opts = {
    prompt = "Enter new page name:",
    default = default_name,
    completion = "file",
  }
  safe_ui_input(opts, function(input)
    if not input or input == "" or input == default_name then
      return callback(nil) -- Abort cleanly
    end
    local sanitized_input = util.sanitize_filename(input)
    local new_filename = (vim.fn.fnamemodify(sanitized_input, ":e") == "")
        and (input .. state.markdown_extension)
      or input
    callback({ new_filename = new_filename })
  end)
end

return M
