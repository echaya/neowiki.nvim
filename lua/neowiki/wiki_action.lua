local util = require("neowiki.util")
local finder = require("neowiki.finder")
local config = require("neowiki.config")
local state = require("neowiki.state")

local wiki_action = {}

---
-- Creates buffer-local keymaps for the current wiki file.
-- These keymaps are defined in the user's configuration.
-- @param buffer_number (number): The buffer number to attach the keymaps to.
--
wiki_action.create_buffer_keymaps = function(buffer_number)
  -- Make the gtd toggle function repeatable for normal mode.
  util.make_repeatable("n", "<Plug>(neowikiToggleTask)", function()
    require("neowiki.gtd").toggle_task()
  end)
  ---
  -- Jumps the cursor to the next or previous link in the buffer without wrapping.
  -- Displays a notification if no more links are found in the given direction.
  -- @param direction (string): The direction to search ('next' or 'prev').
  --
  local function jump_to_link(direction)
    -- This pattern finds [text](target) or [[target]] style links.
    local link_pattern = [[\(\[.\{-}\](.\{-})\)\|\(\[\[.\{-}\]\]\)]]
    local flags = direction == "next" and "W" or "bW"

    if vim.fn.search(link_pattern, flags) == 0 then
      vim.notify(
        "No more links found in this direction",
        vim.log.levels.INFO,
        { title = "neowiki" }
      )
    else
      -- Clear search highlighting after a successful jump.
      vim.cmd("noh")
    end
  end

  -- Defines the behavior of logical actions across different modes.
  local logical_actions = {
    action_link = {
      n = { rhs = require("neowiki.wiki").follow_link, desc = "Follow Wiki Link" },
      v = {
        rhs = ":'<,'>lua require('neowiki.wiki').create_or_open_wiki_file()<CR>",
        desc = "Create Link from Selection",
      },
    },
    action_link_vsplit = {
      n = {
        rhs = function()
          require("neowiki.wiki").follow_link("vsplit")
        end,
        desc = "Follow Wiki Link (VSplit)",
      },
      v = {
        rhs = ":'<,'>lua require('neowiki.wiki').create_or_open_wiki_file('vsplit')<CR>",
        desc = "Create Link from Selection (VSplit)",
      },
    },
    action_link_split = {
      n = {
        rhs = function()
          require("neowiki.wiki").follow_link("split")
        end,
        desc = "Follow Wiki Link (Split)",
      },
      v = {
        rhs = ":'<,'>lua require('neowiki.wiki').create_or_open_wiki_file('split')<CR>",
        desc = "Create Link from Selection (Split)",
      },
    },
    toggle_task = {
      n = { rhs = "<Plug>(neowikiToggleTask)", desc = "Toggle Task Status", remap = true },
      v = {
        rhs = ":'<,'>lua require('neowiki.gtd').toggle_task({ visual = true })<CR>",
        desc = "Toggle Tasks in Selection",
      },
    },
    next_link = {
      n = {
        rhs = function()
          jump_to_link("next")
        end,
        desc = "Jump to Next Link",
      },
    },
    prev_link = {
      n = {
        rhs = function()
          jump_to_link("prev")
        end,
        desc = "Jump to Prev Link",
      },
    },
    jump_to_index = {
      n = { rhs = require("neowiki.wiki").jump_to_index, desc = "Jump to Index" },
    },
    delete_page = {
      n = { rhs = require("neowiki.wiki").delete_wiki, desc = "Delete Wiki Page" },
    },
    cleanup_links = {
      n = { rhs = require("neowiki.wiki").cleanup_broken_links, desc = "Clean Broken Links" },
    },
    insert_link = {
      n = { rhs = require("neowiki.wiki").insert_wiki_link, desc = "Insert link to a page" },
    },
  }

  -- If we are in a floating window, override split actions to show a notification.
  if util.is_float() then
    local function notify_disabled()
      vim.notify(
        "(V)Split actions are disabled in a floating window.",
        vim.log.levels.INFO,
        { title = "neowiki" }
      )
    end

    local disabled_action = {
      n = { rhs = notify_disabled, desc = "Action disabled in float" },
      v = { rhs = notify_disabled, desc = "Action disabled in float" },
    }
    logical_actions.action_link_vsplit = disabled_action
    logical_actions.action_link_split = disabled_action

    local close_lhs = config.keymaps.close_float
    if close_lhs and close_lhs ~= "" then
      vim.keymap.set("n", close_lhs, "<cmd>close<CR>", {
        buffer = buffer_number,
        desc = "neowiki: Close floating window",
        silent = true,
      })
    end
  end

  -- Iterate through the user's flattened keymap config and apply the mappings.
  for action_name, lhs in pairs(config.keymaps) do
    if lhs and lhs ~= "" and logical_actions[action_name] then
      local modes = logical_actions[action_name]
      -- For each logical action, create a keymap for every mode defined (n, v, etc.).
      for mode, action_details in pairs(modes) do
        vim.keymap.set(mode, lhs, action_details.rhs, {
          buffer = buffer_number,
          desc = "neowiki: " .. action_details.desc,
          remap = action_details.remap,
          silent = true,
        })
      end
    end
  end
end

---
-- Opens a buffer in a styled floating window.
-- @param buffer_number (number): The buffer number to open.
--
local _open_file_in_float = function(buffer_number)
  -- Internal defaults to ensure the function is robust against malformed user config.
  -- These values should mirror the defaults exposed in `config.lua`.
  local internal_defaults = {
    open = {
      relative = "editor",
      width = 0.85,
      height = 0.85,
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
local prompt_wiki_dir = function(user_config, on_complete)
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
wiki_action.prompt_wiki_page = function(search_root, current_buf_path, on_complete)
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
  vim.ui.select(items, {
    prompt = "Select a page to link:",
    format_item = function(item)
      return " " .. item.display
    end,
  }, function(choice)
    if not choice then
      vim.notify("Wiki link insertion cancelled.", vim.log.levels.INFO, { title = "neowiki" })
      on_complete(nil) -- User cancelled the prompt.
      return
    end
    on_complete(choice.path) -- Execute the callback with the chosen path.
  end)
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
wiki_action.find_all_link_targets = function(line)
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
wiki_action.process_link = function(cursor, line)
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
-- Opens a file at a given path. If the file is already open in a window,
-- it jumps to that window. Otherwise, it opens the file in the current window
-- or via a specified command (e.g., 'vsplit').
-- @param full_path (string): The absolute path to the file.
-- @param open_cmd (string|nil): Optional vim command to open the file (e.g., "vsplit", "tabnew", "float").
--
wiki_action.open_file = function(full_path, open_cmd)
  local abs_path = vim.fn.fnamemodify(full_path, ":p")
  local buffer_number = vim.fn.bufnr(abs_path, true)

  if open_cmd == "float" then
    _open_file_in_float(buffer_number)
    return
  end

  -- If buffer is already open and visible, jump to its window.
  if buffer_number ~= -1 then
    local win_nr = vim.fn.bufwinnr(buffer_number)
    if win_nr ~= -1 then
      local win_id = vim.fn.win_getid(win_nr)
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end

  -- Open the file using the specified command or in the current window.
  if open_cmd and type(open_cmd) == "string" and #open_cmd > 0 then
    vim.cmd(open_cmd .. " " .. vim.fn.fnameescape(full_path))
  else
    local bn_to_open = vim.fn.bufnr(full_path, true)
    vim.api.nvim_win_set_buf(0, bn_to_open)
  end
end



---
-- Adds a new wiki root path to the processed list at runtime.
-- This is triggered when a new nested wiki config.index_file is created.
-- @param path (string) The absolute path to the new wiki root directory.
--
wiki_action.add_wiki_root = function(path)
  if not path or path == "" then
    vim.notify("Attempted to add an empty wiki path.", vim.log.levels.WARN, { title = "neowiki" })
    return
  end

  if not state.processed_wiki_paths then
    state.processed_wiki_paths = {}
  end

  -- Check for duplicates to prevent re-adding the same path
  for _, existing_path in ipairs(state.processed_wiki_paths) do
    if existing_path.resolved == path then
      return -- Path already exists, no action needed.
    end
  end
  -- Add the new path to the list
  table.insert(state.processed_wiki_paths, {
    resolved = path,
    normalized = util.normalize_path_for_comparison(path),
  })

  -- Re-sort the list to maintain the descending length order
  util.sort_wiki_paths(state.processed_wiki_paths)
  vim.notify(
    "New wiki root detected and registered: " .. vim.fn.fnamemodify(path, ":~"),
    vim.log.levels.INFO,
    { title = "neowiki" }
  )
end

---
-- Opens the config.index_file of a selected or specified wiki.
-- @param name (string|nil): The name of the wiki to open. If nil, prompts the user.
-- @param open_cmd (string|nil): Optional command for opening the file.
--
wiki_action.open_wiki_index = function(name, open_cmd)
  local function open_index_from_path(wiki_path)
    if not wiki_path then
      return
    end
    local resolved_path = util.resolve_path(wiki_path)
    if not resolved_path then
      vim.notify("Could not resolve wiki path.", vim.log.levels.ERROR, { title = "neowiki" })
      return
    end
    util.ensure_path_exists(resolved_path)
    local wiki_index_path = vim.fs.joinpath(resolved_path, config.index_file)
    wiki_action.open_file(wiki_index_path, open_cmd)
  end

  if config.wiki_dirs and #config.wiki_dirs > 0 then
    if name then
      local found_path = nil
      for _, wiki_dir in ipairs(config.wiki_dirs) do
        if wiki_dir.name == name then
          found_path = wiki_dir.path
          break
        end
      end
      open_index_from_path(found_path)
    else
      prompt_wiki_dir(config, open_index_from_path)
    end
  else
    if state.processed_wiki_paths and #state.processed_wiki_paths > 0 then
      open_index_from_path(state.processed_wiki_paths[1].resolved)
    else
      vim.notify("No wiki path found.", vim.log.levels.ERROR, { title = "neowiki" })
    end
  end
end

return wiki_action
