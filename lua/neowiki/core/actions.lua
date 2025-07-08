-- lua/neowiki/core/actions.lua
local util = require("neowiki.util")
local finder = require("neowiki.core.finder")
local ui = require("neowiki.core.ui")
local link = require("neowiki.core.link")
local config = require("neowiki.config")
local state = require("neowiki.state")

local M = {}

---
-- Adds a new path to the navigation history.
-- This function handles truncation of "forward" history if a new path is
-- visited after navigating back.
-- @param path (string): The absolute path of the page to add to the history.
local function add_to_history(path)
  if not path or path == "" then
    return
  end

  -- If the cursor is pointing to the same path, do nothing.
  if state.history_cursor > 0 and state.navigation_history[state.history_cursor] == path then
    return
  end

  -- If we've navigated back and are now opening a new link,
  -- truncate the "forward" part of the history.
  if state.history_cursor > 0 and state.history_cursor < #state.navigation_history then
    state.navigation_history = vim.list_slice(state.navigation_history, 1, state.history_cursor)
  end

  table.insert(state.navigation_history, path)
  state.history_cursor = #state.navigation_history
end

---
-- Initializes the navigation history with the given path if the history is empty.
-- @param path (string): The path of the first wiki page visited.
--
M.initialize_history_if_needed = function(path)
  if #state.navigation_history == 0 then
    add_to_history(path)
  end
end

---
-- Checks if the current buffer is recognized as being inside a Neowiki directory.
-- @return (boolean) Returns `true` if the buffer is part of a Neowiki, otherwise `false`.
--
M.check_in_neowiki = function()
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
-- Opens a file at a given path. If the file is already open in a window,
-- it jumps to that window. Otherwise, it opens the file in the current window
-- or via a specified command (e.g., 'vsplit').
-- @param full_path (string): The absolute path to the file.
-- @param open_cmd (string|nil): Optional vim command to open the file (e.g., "vsplit", "tabnew", "float").
--
local open_file = function(full_path, open_cmd)
  local abs_path = vim.fn.fnamemodify(full_path, ":p")
  local buffer_number = vim.fn.bufnr(abs_path, true)

  if open_cmd == "float" then
    -- reusing the existing floating window for new file
    ui.open_file_in_float(buffer_number)
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
-- generate wiki link based on visually selected text
-- @return (string) Returns processed filename cleaned up for page creation
--
M.gen_link_from_selection = function()
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

  local filename = util.sanitize_filename(link_display_text) .. state.markdown_extension
  local filename_link = "[" .. link_display_text .. "](" .. "./" .. filename .. ")"
  vim.api.nvim_buf_set_text(0, start_row, start_col, end_row, end_col, { filename_link })
  return filename
end

---
-- Finds a markdown link under the cursor and opens the target file.
-- @param open_cmd (string|nil): Optional command for opening the file (e.g., 'vsplit').
--
M.follow_link = function(open_cmd)
  local active_path
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path and buf_path ~= "" then
    active_path = vim.fn.fnamemodify(buf_path, ":h")
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.fn.getline(cursor[1])
  local filename = link.process_link(cursor, line, nil)

  if filename and filename:len() > 0 then
    -- try open_external if the filename is a url
    if util.is_web_link(filename) then
      util.open_external(filename)
      return
    end

    local full_path = util.join_path(active_path, filename)
    add_to_history(full_path)

    -- reuse the current floating window to open the new link.
    if util.is_float() and not open_cmd then
      local bn_to_open = vim.fn.bufnr(full_path, true)
      vim.api.nvim_win_set_buf(0, bn_to_open)
    else
      open_file(full_path, open_cmd)
    end
  else
    vim.notify("No link under cursor.", vim.log.levels.WARN, { title = "neowiki" })
  end
end

---
-- Jumps to the config.index_file of the wiki that the current buffer belongs to.
--
M.jump_to_index = function()
  local root = vim.b[0].wiki_root
  local index_path = util.join_path(root, config.index_file)
  add_to_history(index_path)
  open_file(index_path)
end

---
-- Adds a new wiki root path to the processed list at runtime.
-- This is triggered when a new nested wiki config.index_file is created.
-- @param path (string) The absolute path to the new wiki root directory.
--
M.add_wiki_root = function(path)
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
-- Creates a new wiki page file on disk, opens it, and handles registering
-- new wiki roots if an index file is created.
-- @param filename (string): The name of the file to create (e.g., "new_page.md").
-- @param open_cmd (string|nil): Optional command for opening the new file.
--
M.create_page_from_filename = function(filename, open_cmd)
  -- Get the context from the current buffer's variables.
  local current_buf_nr = vim.api.nvim_get_current_buf()
  local active_wiki_path = vim.b[current_buf_nr].active_wiki_path
  local full_path = util.join_path(active_wiki_path, filename)
  local dir_path = vim.fn.fnamemodify(full_path, ":h")

  -- If the new file is an index file, register its directory as a new nested wiki root.
  if vim.fn.fnamemodify(filename, ":t") == config.index_file and config.discover_nested_roots then
    M.add_wiki_root(dir_path)
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

  add_to_history(full_path)
  -- Use the existing open_file action to handle opening in different ways.
  open_file(full_path, open_cmd)
end

---
-- Opens the config.index_file of a selected or specified wiki.
-- @param name (string|nil): The name of the wiki to open. If nil, prompts the user.
-- @param open_cmd (string|nil): Optional command for opening the file.
--
M.open_wiki_index = function(name, open_cmd)
  -- Reset history when opening a wiki index directly
  state.navigation_history = {}
  state.history_cursor = 0

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

    add_to_history(wiki_index_path)
    open_file(wiki_index_path, open_cmd)
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
      ui.prompt_wiki_dir(config, open_index_from_path)
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
-- Removes markup from broken links within the current buffer, preserving the text.
-- @param broken_links_info (table) A list of objects, each with an `lnum`.
--
local remove_broken_links_markup = function(broken_links_info)
  if not broken_links_info or #broken_links_info == 0 then
    return
  end

  local buf_nr = vim.api.nvim_get_current_buf()
  local all_lines = vim.api.nvim_buf_get_lines(buf_nr, 0, -1, false)
  local modified_lines_details = {}
  local current_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf_nr), ":p:h")

  local line_num_set = {}
  for _, info in ipairs(broken_links_info) do
    line_num_set[info.lnum] = true
  end

  local any_line_modified = false
  for i, line in ipairs(all_lines) do
    if line_num_set[i] then
      local new_line, was_modified = link.remove_broken_markup(line, current_dir)
      if was_modified then
        all_lines[i] = new_line
        table.insert(modified_lines_details, "Line " .. i .. ": " .. line:match("^%s*(.-)%s*$"))
        any_line_modified = true
      end
    end
  end

  if any_line_modified then
    vim.api.nvim_buf_set_lines(buf_nr, 0, -1, false, all_lines)

    local message = "Link cleanup complete.\nRemoved broken links from "
      .. #modified_lines_details
      .. " line(s):\n"
      .. table.concat(modified_lines_details, "\n")

    vim.notify(message, vim.log.levels.INFO, {
      title = "neowiki",
      on_open = function(win)
        local width = vim.api.nvim_win_get_width(win)
        local height = #modified_lines_details + 3
        vim.api.nvim_win_set_config(win, { height = height, width = math.min(width, 100) })
      end,
    })
  else
    vim.notify(
      "Could not remove links. They might be web links or the syntax is unusual.",
      vim.log.levels.INFO,
      { title = "neowiki" }
    )
  end
end

---
-- Finds broken links, displays them, and prompts the user for action:
-- populate quickfix, remove links, or cancel.
--
M.cleanup_broken_links = function()
  local broken_links_info = link.find_broken_links_in_buffer()

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

  local _, choice = pcall(vim.fn.confirm, prompt_message, "&Quickfix\n&Remove Links\n&Cancel")

  if choice == 1 then
    util.populate_quickfix_list(broken_links_info)
  elseif choice == 2 then
    remove_broken_links_markup(broken_links_info)
  else -- choice is 3 (Cancel) or 0 (dialog closed).
    vim.notify("Link cleanup canceled.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

---
-- Verifies backlink candidates and prepares a list of changes.
-- This function iterates through potential backlinks, confirms they point to the
-- target file, and applies a transformation to generate the new line content.
-- @param old_abs_path (string) The absolute path of the file that was changed.
-- @param backlink_candidates (table) A list of potential backlink match objects from the finder.
-- @param line_transformer (function) The function to apply to each verified backlink line.
-- @return (table) A table mapping file paths to a list of changes, e.g., { [file_path] = { [lnum] = new_line } }.
--
local function verify_and_transform_backlinks(old_abs_path, backlink_candidates, line_transformer)
  local files_to_update = {}
  local target_filename_no_ext = vim.fn.fnamemodify(old_abs_path, ":t:r")

  for _, match in ipairs(backlink_candidates) do
    local temp_cursor = { match.lnum, 0 }
    local processed_target = link.process_link(temp_cursor, match.text, target_filename_no_ext)

    if processed_target and not util.is_web_link(processed_target) then
      local match_dir = vim.fn.fnamemodify(match.file, ":p:h")
      local resolved_link_path = util.join_path(match_dir, processed_target)

      if
        util.normalize_path_for_comparison(resolved_link_path)
        == util.normalize_path_for_comparison(old_abs_path)
      then
        -- If verified, apply the specific transformation (rename or delete).
        local new_line, count = line_transformer(match.text, match_dir, old_abs_path)
        if count > 0 then
          if not files_to_update[match.file] then
            files_to_update[match.file] = {}
          end
          files_to_update[match.file][match.lnum] = new_line
        end
      end
    end
  end

  return files_to_update
end

---
-- Applies file modifications and prepares data for the quickfix list.
-- This function takes a table of changes, reads each affected file, applies
-- the new line content, writes the file back, and generates a list of
-- changes for the user to review.
-- @param files_to_update (table) A table of changes generated by `verify_and_transform_backlinks`.
-- @return (table) A list of change objects suitable for populating the quickfix list.
--
local function apply_backlink_updates(files_to_update)
  local changes_for_qf = {}

  for file_path, changes in pairs(files_to_update) do
    local read_ok, lines = pcall(vim.fn.readfile, file_path)
    if read_ok then
      for i = 1, #lines do
        lines[i] = lines[i]:gsub("\r$", "")
      end

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
-- Generic backlink processor that verifies links and applies a transformation.
-- @param old_abs_path (string) The absolute path of the file that was changed.
-- @param backlink_candidates (table) The candiates for transformation
-- @param line_transformer (function) A function to apply to each verified backlink line.
--   It receives `(line_content, file_dir, old_abs_path)` and should return the modified line.
-- @return (table|nil) A list of changes suitable for the quickfix list, or nil if no candidates were provided.
--
local function process_backlinks(old_abs_path, backlink_candidates, line_transformer)
  if not backlink_candidates or #backlink_candidates == 0 then
    return nil -- Indicate that rg failed or found nothing.
  end

  local files_to_update =
    verify_and_transform_backlinks(old_abs_path, backlink_candidates, line_transformer)
  local changes_for_qf = apply_backlink_updates(files_to_update)

  return changes_for_qf
end

---
-- Core logic to execute a file action (rename/delete), including backlink updates.
-- @param path_to_action (string) Absolute path of the file to modify.
-- @param fallback_targets (table) Paths to fall back to if the current buffer is closed.
-- @param action_config (table) A table defining the specific action to perform.
--
local function execute_file_action(path_to_action, fallback_targets, action_config)
  -- 1. Pre-flight checks
  if vim.fn.filereadable(path_to_action) == 0 then
    vim.notify(
      "File does not exist: " .. path_to_action,
      vim.log.levels.ERROR,
      { title = "neowiki" }
    )
    return
  end

  local filename = vim.fn.fnamemodify(path_to_action, ":t")
  if filename == config.index_file then
    vim.notify(
      string.sub(action_config.verb, 1, -2) .. "ing an index file is not allowed.",
      vim.log.levels.WARN,
      { title = "neowiki" }
    )
    return
  end

  -- 2. Action-specific setup (e.g., get new name via vim.ui.input)
  action_config.setup(filename, function(context)
    if not context then -- User cancelled the setup phase
      vim.notify(
        action_config.verb .. " operation canceled.",
        vim.log.levels.INFO,
        { title = "neowiki" }
      )
      return
    end

    -- 3. Final confirmation
    local confirm_prompt = action_config.get_confirm_prompt(filename, context)
    local _, choice = pcall(vim.fn.confirm, confirm_prompt, "&Yes\n&No")
    if choice ~= 1 then
      vim.notify(
        action_config.verb .. " operation canceled.",
        vim.log.levels.INFO,
        { title = "neowiki" }
      )
      return
    end

    local was_current_buffer = util.normalize_path_for_comparison(path_to_action)
      == util.normalize_path_for_comparison(vim.api.nvim_buf_get_name(0))

    -- 4. Execute the file system operation
    local ok, err = pcall(action_config.file_op, path_to_action, context)
    if not ok then
      vim.notify(
        "Error " .. action_config.verb:lower() .. "ing file: " .. err,
        vim.log.levels.ERROR,
        { title = "neowiki" }
      )
      return
    end

    -- 5. Notify user and manage buffers
    local ultimate_wiki_root = vim.b[0].ultimate_wiki_root
    vim.notify(
      action_config.get_success_message(filename, context),
      vim.log.levels.INFO,
      { title = "neowiki" }
    )
    util.delete_target_buffer(path_to_action)

    if was_current_buffer and action_config.post_action_buffer_fn then
      action_config.post_action_buffer_fn(fallback_targets, context)
    end

    -- 6. Find and process backlinks
    local target_filename_no_ext = vim.fn.fnamemodify(path_to_action, ":t:r")
    context.target_filename_no_ext = target_filename_no_ext
    local backlink_candidates = finder.find_backlinks(ultimate_wiki_root, target_filename_no_ext)
    if not backlink_candidates then
      backlink_candidates = finder.find_backlink_fallback(fallback_targets, target_filename_no_ext)
    end

    local line_transformer = action_config.get_backlink_transformer(context)
    local changes_for_qf = process_backlinks(path_to_action, backlink_candidates, line_transformer)

    -- 7. Update UI with backlink results
    if changes_for_qf then
      if #changes_for_qf > 0 then
        util.populate_quickfix_list(changes_for_qf)
        vim.notify(
          string.format(
            "%s %d backlink(s). See quickfix list.",
            action_config.verb,
            #changes_for_qf
          ),
          vim.log.levels.INFO,
          { title = "neowiki" }
        )
      else
        vim.notify("No backlinks found to update.", vim.log.levels.INFO, { title = "neowiki" })
      end
    end
    vim.cmd("checktime")
  end)
end

---
-- Entry point for deleting a wiki page.
M.delete_wiki_page = function()
  local delete_config = {
    verb = "Delete",
    setup = function(_, callback)
      callback({})
    end, -- No setup needed for delete
    get_confirm_prompt = function(filename, _)
      return string.format("Permanently delete '%s' and clean up all backlinks?", filename)
    end,
    file_op = function(path, _)
      return os.remove(path)
    end,
    get_success_message = function(filename, _)
      return "Page deleted: " .. filename
    end,
    post_action_buffer_fn = function(fallbacks, _)
      local fallback_path, _ = next(fallbacks)
      if fallback_path then
        vim.cmd("edit " .. vim.fn.fnameescape(fallback_path))
      end
    end,
    get_backlink_transformer = function(context)
      return function(line_content, _, _)
        return link.find_and_transform_link_markup(
          line_content,
          context.target_filename_no_ext,
          function(link_text, old_target)
            if old_target then -- This is a markdown link: [text](target)
              -- Extract the text from between the brackets.
              return link_text:match("^%[(.*)%]$") or ""
            else -- This is a wikilink: [[text]]
              -- The link_text is already the display text.
              return link_text
            end
          end
        )
      end
    end,
  }

  ui.prompt_for_action_target(delete_config.verb, function(path, fallbacks)
    execute_file_action(path, fallbacks, delete_config)
  end)
end

---
-- Entry point for renaming a wiki page.
M.rename_wiki_page = function()
  local rename_config = {
    verb = "Rename",
    setup = ui.prompt_rename_input,
    get_confirm_prompt = function(old_filename, context)
      return string.format(
        "Rename '%s' to '%s' and update all backlinks?",
        old_filename,
        context.new_filename
      )
    end,
    file_op = function(old_path, context)
      local new_path = util.join_path(vim.fn.fnamemodify(old_path, ":h"), context.new_filename)
      context.new_full_path = new_path -- Save for later steps
      return vim.fn.rename(old_path, new_path)
    end,
    get_success_message = function(_, context)
      return "Page renamed to " .. context.new_filename
    end,
    post_action_buffer_fn = function(_, context)
      vim.cmd("edit " .. vim.fn.fnameescape(context.new_full_path))
    end,
    get_backlink_transformer = function(context)
      return function(line_content, file_dir, _)
        local new_relative_path = util.get_relative_path(file_dir, context.new_full_path)
        return link.find_and_transform_link_markup(
          line_content,
          context.target_filename_no_ext,
          function(link_text, old_target)
            if old_target then -- Markdown link
              return link_text .. "(" .. new_relative_path .. ")"
            else -- Wikilink
              local new_link_text = vim.fn.fnamemodify(new_relative_path, ":r")
              return "[[" .. new_link_text .. "]]"
            end
          end
        )
      end
    end,
  }

  ui.prompt_for_action_target(rename_config.verb, function(path, fallbacks)
    execute_file_action(path, fallbacks, rename_config)
  end)
end

---
-- Navigates to the previous page in the history.
M.navigate_back = function()
  if not M.check_in_neowiki() then
    return
  end

  if state.history_cursor > 1 then
    local target_cursor = state.history_cursor - 1
    local path_to_open = state.navigation_history[target_cursor]

    if vim.fn.filereadable(path_to_open) == 1 then
      state.history_cursor = target_cursor
      open_file(path_to_open)
    else
      vim.notify(
        "History entry not found, removing: " .. vim.fn.fnamemodify(path_to_open, ":~"),
        vim.log.levels.WARN,
        { title = "neowiki" }
      )
      table.remove(state.navigation_history, target_cursor)
      -- After removing the item before the current cursor, we must decrement the cursor
      -- to maintain its position relative to the rest of the list.
      state.history_cursor = state.history_cursor - 1
    end
  else
    vim.notify("No more history to go back to.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

---
-- Navigates to the next page in the history.
M.navigate_forward = function()
  if not M.check_in_neowiki() then
    return
  end

  if state.history_cursor < #state.navigation_history then
    local target_cursor = state.history_cursor + 1
    local path_to_open = state.navigation_history[target_cursor]

    if vim.fn.filereadable(path_to_open) == 1 then
      state.history_cursor = target_cursor
      open_file(path_to_open)
    else
      vim.notify(
        "History entry not found, removing: " .. vim.fn.fnamemodify(path_to_open, ":~"),
        vim.log.levels.WARN,
        { title = "neowiki" }
      )
      table.remove(state.navigation_history, target_cursor)
      -- No cursor change is needed here, as we removed an item *after* the current one.
      -- The next press of 'forward' will try the next item in the shrunk list.
    end
  else
    vim.notify("No more history to go forward to.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

return M
