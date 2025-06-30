local util = require("neowiki.util")
local finder = require("neowiki.finder")
local config = require("neowiki.config")
local state = require("neowiki.state")

local wiki_action = {}

wiki_action.check_in_neowiki = function()
  if not vim.b[0] or not vim.b[0].wiki_root then
    vim.notify(
      "Not inside a neowiki wiki. Action aborted!",
      vim.log.levels.WARN,
      { title = "neowiki" }
    )
    return false
  else
    return true
  end
end

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
    rename_page = {
      n = { rhs = require("neowiki.wiki").rename_wiki_page, desc = "Rename current page" },
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
-- Creates a new wiki page file on disk, opens it, and handles registering
-- new wiki roots if an index file is created.
-- @param filename (string): The name of the file to create (e.g., "new_page.md").
-- @param open_cmd (string|nil): Optional command for opening the new file.
--
wiki_action.create_page_from_filename = function(filename, open_cmd)
  -- Get the context from the current buffer's variables.
  local current_buf_nr = vim.api.nvim_get_current_buf()
  local active_wiki_path = vim.b[current_buf_nr].active_wiki_path

  if not active_wiki_path then
    vim.notify(
      "Could not determine active wiki path. Action aborted.",
      vim.log.levels.ERROR,
      { title = "neowiki" }
    )
    return
  end

  local full_path = util.join_path(active_wiki_path, filename)
  local dir_path = vim.fn.fnamemodify(full_path, ":h")

  -- If the new file is an index file, register its directory as a new nested wiki root.
  if vim.fn.fnamemodify(filename, ":t") == config.index_file then
    wiki_action.add_wiki_root(dir_path)
  end

  util.ensure_path_exists(dir_path)
  if vim.fn.filereadable(full_path) == 0 then
    local ok, err = pcall(function()
      local file = assert(io.open(full_path, "w"), "Failed to open file for writing.")
      file:close()
    end)
    if not ok then
      vim.notify("Error creating file: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
      return
    end
  end

  -- Use the existing open_file action to handle opening in different ways.
  wiki_action.open_file(full_path, open_cmd)
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
-- Processes the text on a line to find and return a markdown link target.
-- If a cursor position is provided, it finds the link at that position.
-- If the cursor is nil, it finds the first link on the line.
-- @param cursor (table|nil): The cursor position `{row, col}`. Can be nil.
-- @param line (string): The content of the current line.
-- @return (string|nil): The processed link target, otherwise nil.
--
wiki_action.process_link = function(cursor, line)
  local col = cursor and (cursor[2] + 1) or -1 -- Use -1 to signify ignoring the cursor position

  -- 1. Search for standard markdown links: [text](target)
  do
    local md_pattern = "%[(.-)%]%(<?([^)>]+)>?%)"
    local search_pos = 1
    while true do
      local s, e, _, target = line:find(md_pattern, search_pos)
      if not s then
        break
      end
      search_pos = e + 1

      if col ~= -1 then -- Cursor mode: check if cursor is within this link's bounds
        if col >= s and col <= e then
          return util.process_link_target(target, state.markdown_extension)
        end
      else -- Find first mode: return the first link we find
        return util.process_link_target(target, state.markdown_extension)
      end
    end
  end

  -- 2. If no markdown link was found/matched, search for wikilinks: [[target]]
  do
    local wiki_pattern = "%[%[(.-)%]%]"
    local search_pos = 1
    while true do
      local s, e, target = line:find(wiki_pattern, search_pos)
      if not s then
        break
      end
      search_pos = e + 1

      if col ~= -1 then -- Cursor mode
        if col >= s and col <= e then
          local processed = util.process_link_target(target, state.markdown_extension)
          return processed and ("./" .. processed) or nil
        end
      else -- Find first mode
        local processed = util.process_link_target(target, state.markdown_extension)
        return processed and ("./" .. processed) or nil
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

---
-- Removes lines from the current buffer based on the provided broken links info
-- and notifies the user about the changes.
-- @param broken_links_info (table) A list of objects, each with an `lnum` and `text`.
--
wiki_action.remove_lines_with_broken_links = function(broken_links_info)
  if not broken_links_info or #broken_links_info == 0 then
    return
  end

  local lines_to_keep = {}
  local deleted_lines_details = {}
  local delete_map = {}

  for _, info in ipairs(broken_links_info) do
    delete_map[info.lnum] = true
    table.insert(deleted_lines_details, "Line " .. info.lnum .. ": " .. info.text)
  end

  -- Build a new list of lines to keep, which is safer than deleting
  -- lines one by one and dealing with shifting line numbers.
  local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, line in ipairs(all_lines) do
    if not delete_map[i] then
      table.insert(lines_to_keep, line)
    end
  end

  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines_to_keep)

  -- Notify user of the changes.
  local message = "Link cleanup complete.\nRemoved "
    .. #deleted_lines_details
    .. " line(s) with broken links:\n"
    .. table.concat(deleted_lines_details, "\n")

  vim.notify(message, vim.log.levels.INFO, {
    title = "neowiki",
    on_open = function(win)
      local width = vim.api.nvim_win_get_width(win)
      -- Calculate height based on number of deleted lines plus header lines.
      local height = #deleted_lines_details + 3
      vim.api.nvim_win_set_config(win, { height = height, width = math.min(width, 100) })
    end,
  })
end

-- Finds the first link on a line and replaces it with a new one,
-- intelligently preserving the original link's format.
-- @param line (string) The line containing the link to replace.
-- @param new_target_path (string) The new relative path for the link's target.
-- @return (string, number) The modified line and the count of replacements.
local function _find_and_replace_link_markup(line, new_target_path)
  -- 1. First, try to find and replace a standard markdown link: [text](target)
  --    We capture the link text part and the target part separately.
  local md_pattern = "(%[.-%])(%(.-%))"
  local link_text, old_target_part = line:match(md_pattern)

  if link_text and old_target_part then
    -- It's a markdown link. We preserve the `link_text` part.
    local old_full_markup = link_text .. old_target_part
    -- And create a new markup with the new path.
    local new_full_markup = link_text .. "(" .. new_target_path .. ")"
    return line:gsub(vim.pesc(old_full_markup), new_full_markup, 1)
  end

  -- 2. If no markdown link was found, try to find and replace a wikilink: [[target]]
  local wiki_pattern = "(%[%[.-%]%])"
  local old_full_markup = line:match(wiki_pattern)

  if old_full_markup then
    -- It's a wikilink. We create a new one, removing the file extension for the text.
    local new_link_text = vim.fn.fnamemodify(new_target_path, ":r")
    local new_full_markup = "[[" .. new_link_text .. "]]"
    return line:gsub(vim.pesc(old_full_markup), new_full_markup, 1)
  end

  -- 3. If no link of either type was found, return the original line.
  return line, 0
end

---
-- Processes a list of backlink candidates, verifies them, and updates the files.
-- This version now uses the new, smarter replacement helper function.
local function _update_verified_links(old_abs_path, new_full_path, backlink_candidates)
  local changes_for_qf = {}
  local files_to_update = {} -- Group changes by file to minimize I/O

  for _, match in ipairs(backlink_candidates) do
    local temp_cursor = { match.lnum, 0 }
    local processed_target = wiki_action.process_link(temp_cursor, match.text)

    if processed_target and not util.is_web_link(processed_target) then
      local match_dir = vim.fn.fnamemodify(match.file, ":p:h")
      local resolved_link_path =
        vim.fn.fnamemodify(vim.fs.joinpath(match_dir, processed_target), ":p")

      if
        util.normalize_path_for_comparison(resolved_link_path)
        == util.normalize_path_for_comparison(old_abs_path)
      then
        -- If verified, calculate the new relative path for the target file.
        local new_relative_path = util.get_relative_path(match_dir, new_full_path)

        -- Call the new all-in-one function to perform the format-aware replacement.
        local new_line, count = _find_and_replace_link_markup(match.text, new_relative_path)

        if count > 0 then
          if not files_to_update[match.file] then
            files_to_update[match.file] = {}
          end
          files_to_update[match.file][match.lnum] = new_line
        end
      end
    end
  end

  for file_path, changes in pairs(files_to_update) do
    local read_ok, lines = pcall(vim.fn.readfile, file_path)
    if read_ok then
      for lnum, new_line in pairs(changes) do
        lines[lnum] = new_line
        table.insert(
          changes_for_qf,
          { filename = file_path, lnum = lnum, text = "=> " .. new_line }
        )
      end
      pcall(vim.fn.writefile, lines, file_path)
    end
  end

  return changes_for_qf
end

---
-- Finds and updates all backlinks for a renamed file and reports results to the quickfix list.
-- This is a self-contained function to be called after a successful rename.
-- @param wiki_root (string) The immediate wiki root for fallback search.
-- @param ultimate_wiki_root (string) The top-level wiki directory to search within.
-- @param old_filename (string) The original filename (e.g., "old_page.md").
-- @param old_abs_path (string) The original absolute path to the file.
-- @param new_full_path (string) The new absolute path to the file.
--
local function update_backlinks_and_report(
  wiki_root,
  ultimate_wiki_root,
  old_filename,
  old_abs_path,
  new_full_path
)
  -- Find backlink candidates using rg.
  local search_term = vim.fn.fnamemodify(old_filename, ":r")
  local backlink_candidates = finder.find_backlinks(ultimate_wiki_root, search_term)

  if not backlink_candidates then
    vim.notify(
      "rg not found. Falling back to searching the immediate index.md file.",
      vim.log.levels.INFO,
      { title = "neowiki" }
    )
    backlink_candidates = {}
    -- Construct the path to the immediate index file.
    local index_file_path = vim.fs.joinpath(wiki_root, config.index_file)

    -- Check if the index file is readable.
    if vim.fn.filereadable(index_file_path) == 1 then
      local all_lines = vim.fn.readfile(index_file_path)
      for i, line in ipairs(all_lines) do
        -- If a line contains the search term, add it to the candidates.
        if line:find(search_term, 1, true) then
          table.insert(backlink_candidates, {
            file = index_file_path,
            lnum = i,
            text = line,
          })
        end
      end
    else
      vim.notify(
        "Could not read index file for backlink search: " .. index_file_path,
        vim.log.levels.WARN,
        { title = "neowiki" }
      )
    end
  end

  -- Verify candidates and replace links.
  local changes_for_qf = _update_verified_links(old_abs_path, new_full_path, backlink_candidates)

  -- Populate and open the quickfix list with the results.
  if #changes_for_qf > 0 then
    util.populate_quickfix_list(changes_for_qf, "Updated Backlinks")
    vim.notify(
      "Updated " .. #changes_for_qf .. " backlink(s). See quickfix list for details.",
      vim.log.levels.INFO,
      { title = "neowiki" }
    )
  else
    vim.notify("No backlinks were updated.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

---
-- This function is called by the main rename_wiki_page action.
-- @param old_abs_path (string) The absolute path of the file to rename.
-- @param is_current_file_rename (boolean) Flag to determine if we need to load the new file.
--
local function _execute_rename_logic(old_abs_path, is_current_file_rename)
  local wiki_root = vim.b[0].wiki_root
  local ultimate_wiki_root = vim.b[0].ultimate_wiki_root

  if vim.fn.filereadable(old_abs_path) == 0 then
    vim.notify("File does not exist: " .. old_abs_path, vim.log.levels.ERROR, { title = "neowiki" })
    return
  end

  local old_filename = vim.fn.fnamemodify(old_abs_path, ":t")
  if old_filename == config.index_file then
    vim.notify("Renaming an index file is not allowed.", vim.log.levels.WARN, { title = "neowiki" })
    return
  end

  vim.ui.input({
    prompt = "Enter new page name:",
    default = old_filename,
    completion = "file",
  }, function(input)
    local new_filename = input
    if vim.fn.fnamemodify(new_filename, ":e") == "" then
      new_filename = new_filename .. state.markdown_extension
    end
    if not input or input == "" or new_filename == old_filename then
      vim.notify("Rename cancelled or name unchanged.", vim.log.levels.INFO, { title = "neowiki" })
      return
    end

    local new_full_path = vim.fs.joinpath(vim.fn.fnamemodify(old_abs_path, ":h"), new_filename)

    local prompt =
      string.format("Rename '%s' to '%s' and update all backlinks?", old_filename, new_filename)
    local choice = vim.fn.confirm(prompt, "&Yes\n&No")

    if choice == 1 then
      local rename_ok, rename_err = pcall(vim.fn.rename, old_abs_path, new_full_path)
      if not rename_ok then
        vim.notify(
          "Error renaming file: " .. rename_err,
          vim.log.levels.ERROR,
          { title = "neowiki" }
        )
        return
      end

      vim.notify("Page renamed to " .. new_filename, vim.log.levels.INFO, { title = "neowiki" })
      update_backlinks_and_report(
        wiki_root,
        ultimate_wiki_root,
        old_filename,
        old_abs_path,
        new_full_path
      )

      local old_bufnr = vim.fn.bufnr(old_abs_path)
      if old_bufnr ~= -1 then
        vim.cmd("bdelete! " .. old_bufnr)
      end

      if is_current_file_rename then
        -- Todo check window for edit, use open_cmd?
        vim.cmd("edit " .. vim.fn.fnameescape(new_full_path))
      end

      vim.cmd("checktime")
    else
      vim.notify("Rename operation canceled.", vim.log.levels.INFO, { title = "neowiki" })
    end
  end)
end

---
-- Determines the context (on a link or not) and dispatches to the core logic.
--
wiki_action.rename_wiki_page = function()

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local old_link_target = wiki_action.process_link(cursor, line)
  local current_buf_path = vim.api.nvim_buf_get_name(0)
  local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")

  -- Context: Cursor is on a link.
  if old_link_target and not util.is_web_link(old_link_target) then
    local linked_file_path = vim.fs.joinpath(current_dir, old_link_target)
    local linked_filename = vim.fn.fnamemodify(linked_file_path, ":t")
    local current_filename = vim.fn.fnamemodify(current_buf_path, ":t")

    local prompt = string.format(
      "Rename linked file ('%s') or current file ('%s')?",
      linked_filename,
      current_filename
    )
    local choice = vim.fn.confirm(prompt, "&Linked File\n&Current File\n&Cancel")

    if choice == 1 then -- Rename Linked File
      _execute_rename_logic(linked_file_path, false)
    elseif choice == 2 then -- Rename Current File
      _execute_rename_logic(current_buf_path, true)
    else -- Cancel
      vim.notify("Rename operation canceled.", vim.log.levels.INFO, { title = "neowiki" })
    end
  else
    -- Context: Cursor is not on a link, so default to renaming the current file.
    _execute_rename_logic(current_buf_path, true)
  end
end

return wiki_action
