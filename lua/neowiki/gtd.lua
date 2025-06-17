local config = require("neowiki.config")
local gtd = {}

---
-- The namespace for placing virtual text for GTD progress.
-- @type integer
local progress_ns = vim.api.nvim_create_namespace("neowiki_gtd_progress")

---
-- Calculates the starting column of a task's text content, i.e., after the `* [ ] ` marker.
-- @param line (string): The line content.
-- @return (number|nil): The indentation level (number of characters), or nil if not a task.
--
local function get_task_content_start_col(line)
  if not line then
    return nil
  end
  -- Matches unordered lists: "* [ ]"
  local indent_str = line:match("^(%s*)[%*%-+]%s*%[.%]%s")
  if indent_str then
    return #indent_str
  end
  -- Matches ordered lists: "1. [ ]"
  indent_str = line:match("^(%s*)%d+[.%)%)]%s*%[.%]%s")
  if indent_str then
    return #indent_str
  end
  return nil
end

---
-- Calculates the indentation level of a list marker (`*`, `1.`, etc.) by counting leading spaces.
-- @param line (string): The line content.
-- @return (number|nil): The indentation level, or nil if not a list item.
--
local function get_list_item_indent(line)
  if not line then
    return nil
  end
  -- Matches both ordered and unordered list markers at the start of the line.
  local indent_str = line:match("^(%s*)[%*%-+]%s") or line:match("^(%s*)%d+[.%)%)]%s")
  if indent_str then
    return #indent_str
  end
  return nil
end

---
-- Finds the starting column of the text content in a plain markdown list item.
-- @param line (string): The line content.
-- @return (number|nil): The 1-based column number, or nil if not a list item.
--
local function get_list_marker_info(line)
  if not line then
    return nil
  end
  local _, match_end = line:find("^%s*[%*%-+]%s+") -- Unordered
  if match_end then
    return match_end + 1
  end
  _, match_end = line:find("^%s*%d+[.%)%)]%s+") -- Ordered
  if match_end then
    return match_end + 1
  end
  return nil
end

---
-- Checks if a task is marked as done (e.g., "[x]").
-- @param line (string): The line content.
-- @return (boolean|nil): True if done, false if not, nil if not a valid task checkbox.
--
local function is_marked_done(line)
  local state = line:match("%[(.)%]")
  if state == "x" then
    return true
  elseif state == " " then
    return false
  end
  return nil
end

---
-- Recursively calculates progress and counts incomplete items for a task.
-- @param lines (table): The buffer lines.
-- @param start_ln (number): The 1-based line number of the task to analyze.
-- @return (number, boolean, number): A tuple with progress (0.0-1.0), a boolean for has_children, and the count of incomplete sub-tasks.
--
local function calculate_progress(lines, start_ln)
  local line = lines[start_ln]
  if not line then
    return 0, false, 0
  end

  local parent_bound = get_task_content_start_col(line)
  if not parent_bound then
    return 0, false, 0
  end
  local parent_indent = get_list_item_indent(line)
  if not parent_indent then
    return 0, false, 0
  end

  local children_progress_total = 0
  local children_count = 0
  local total_incomplete_count = 0
  local direct_child_bound = nil

  for ln = start_ln + 1, #lines do
    local child_line = lines[ln]
    local child_indent = get_list_item_indent(child_line)

    if child_indent and child_indent <= parent_indent then
      break
    end

    local child_bound = get_task_content_start_col(child_line)
    if child_bound then
      if not direct_child_bound then
        direct_child_bound = child_bound
      end

      if child_bound == direct_child_bound then
        children_count = children_count + 1
        local child_progress, _, child_incomplete = calculate_progress(lines, ln)
        children_progress_total = children_progress_total + child_progress
        total_incomplete_count = total_incomplete_count + child_incomplete
      end
    end
  end

  if children_count > 0 then
    return children_progress_total / children_count, true, total_incomplete_count
  else
    local done = is_marked_done(line)
    return done and 1.0 or 0.0, false, done and 0 or 1
  end
end

---
-- Clears old progress indicators and renders new ones for the entire buffer.
-- @param lines (table|nil): Optional. A table of buffer lines to avoid re-reading.
--
gtd.update_progress = function(lines)
  local bufnr = vim.api.nvim_get_current_buf()

  if not config.gtd or not config.gtd.show_gtd_progress then
    vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)
    return
  end

  if not lines then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  -- If no tasks exist in the file, skip the rest of the checking
  local content = table.concat(lines, "\n")
  if not content:match("%[%s%]") and not content:match("%[x%]") then
    vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)

  for ln = 1, #lines do
    local line = lines[ln]
    if get_task_content_start_col(line) then
      local progress, has_children, incomplete_count = calculate_progress(lines, ln)
      if has_children and incomplete_count > 0 then
        local display_text = string.format(" [ %.1f%% ]", progress * 100)
        local hl_group = config.gtd.gtd_progress_hl_group or "Comment"
        vim.api.nvim_buf_set_extmark(bufnr, progress_ns, ln - 1, -1, {
          virt_text = { { display_text, hl_group } },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

---
-- Sets the state of a task in the provided table of lines.
-- @param lines (table): The buffer lines.
-- @param line_nr (number): The 1-based line number to modify.
-- @param should_be_done (boolean): The target state (true for done, false for not done).
--
local function set_task_state(lines, line_nr, should_be_done)
  local line = lines[line_nr]
  if not line or get_task_content_start_col(line) == nil then
    return
  end
  if is_marked_done(line) == should_be_done then
    return
  end
  if should_be_done then
    lines[line_nr] = line:gsub("%[ %]", "[x]", 1)
  else
    lines[line_nr] = line:gsub("%[x%]", "[ ]", 1)
  end
end

---
-- Toggles the state of all child tasks recursively.
-- @param lines (table): The buffer lines.
-- @param line_number (number): The 1-based line number of the parent task.
-- @param state (boolean): The new state to apply to all children.
--
local function toggle_children(lines, line_number, state)
  local parent_indent = get_list_item_indent(lines[line_number])
  if not parent_indent then
    return
  end

  for ln = line_number + 1, #lines do
    local line = lines[ln]
    local new_indent = get_list_item_indent(line)

    if new_indent and new_indent <= parent_indent then
      break
    end

    if get_task_content_start_col(line) then
      set_task_state(lines, ln, state)
    end
  end
end

---
-- Finds the parent task of a given task.
-- It stops searching up a branch if it finds a structural parent that is not a task.
-- @param lines (table): The buffer lines.
-- @param cursor (number): The 1-based line number of the child task.
-- @return (number|nil): The line number of the parent task, or nil if none is found.
--
local function find_parent(lines, cursor)
  local child_line = lines[cursor]
  if not child_line then
    return nil
  end

  local child_indent = get_list_item_indent(child_line)
  if not child_indent then
    return nil -- Not a list item, can't have a parent.
  end

  for ln = cursor - 1, 1, -1 do
    local line = lines[ln]
    local parent_indent = get_list_item_indent(line)

    if parent_indent then
      if parent_indent < child_indent then
        -- This is the structural parent. If it's a task, we've found our parent.
        if get_task_content_start_col(line) then
          return ln
        else
          -- If the structural parent is NOT a task, there is no valid task parent.
          return nil
        end
      end
    end
  end
  return nil -- No parent found.
end

---
-- Checks if all immediate children of a parent task are complete.
-- @param lines (table): The buffer lines.
-- @param cursor (number): The 1-based line number of the parent task.
-- @return (boolean): True if all direct children are complete, otherwise false.
--
local function is_children_complete(lines, cursor)
  local parent_indent = get_list_item_indent(lines[cursor])
  if not parent_indent then
    return true
  end

  local child_bound = nil
  local found_a_child = false
  local all_done = true
  for ln = cursor + 1, #lines do
    local line = lines[ln]
    local new_indent = get_list_item_indent(line)

    if new_indent and new_indent <= parent_indent then
      break
    end

    local new_bound = get_task_content_start_col(line)
    if new_bound then
      if not child_bound then
        child_bound = new_bound
      end
      if new_bound == child_bound then
        found_a_child = true
        if not is_marked_done(line) then
          all_done = false
        end
      end
    end
  end
  return not found_a_child or all_done
end

---
-- Updates the status of parent tasks based on the completion of their children.
-- @param lines (table): The buffer lines.
-- @param cursor (number): The 1-based line number of the task that was changed.
--
local function validate_parent_tasks(lines, cursor)
  local current_ln = cursor
  while true do
    local parent_ln = find_parent(lines, current_ln)
    if not parent_ln then
      break
    end

    if is_children_complete(lines, parent_ln) then
      set_task_state(lines, parent_ln, true)
    else
      set_task_state(lines, parent_ln, false)
    end

    current_ln = parent_ln
  end
end

---
-- Runs a full consistency pass on a task and its relatives after a change.
-- @param lines (table): The full table of buffer lines.
-- @param ln (number): The 1-based line number of the task that was changed.
--
local function _run_consistency_pass(lines, ln)
  local line = lines[ln]
  local bound = get_task_content_start_col(line)
  if bound then
    local is_done = is_marked_done(line)
    -- Ensure children match the new state of the parent.
    toggle_children(lines, ln, is_done)
    -- Ensure parents are updated based on the state of their children.
    validate_parent_tasks(lines, ln)
  end
end

---
-- Takes a simple list item line and returns a new line with an incomplete task marker.
-- @param line (string): The simple list item line.
-- @return (string): The new task line.
--
local function _action_create_task(line)
  local text_start_col = get_list_marker_info(line)
  if not text_start_col then
    return line
  end
  local prefix = line:sub(1, text_start_col - 1)
  local suffix = line:sub(text_start_col)
  return prefix .. "[ ] " .. suffix
end

---
-- Takes an incomplete task line and returns a new line with a completed task marker.
-- @param line (string): The incomplete task line.
-- @return (string): The completed task line.
--
local function _action_complete_task(line)
  return line:gsub("%[ %]", "[x]", 1)
end

---
-- Takes a completed task line and returns a new line with an incomplete task marker.
-- @param line (string): The completed task line.
-- @return (string): The incomplete task line.
--
local function _action_uncomplete_task(line)
  return line:gsub("%[x%]", "[ ]", 1)
end

---
-- Handles toggling a single task. Operates on the provided `lines` table.
-- @param lines (table): The buffer lines, to be modified in-place.
--
local function _toggle_single_line(lines)
  local original_cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_ln = original_cursor[1]
  local line = lines[cursor_ln]

  local bound = get_task_content_start_col(line)
  if bound == nil then
    if get_list_marker_info(line) == nil then
      vim.notify("Not a valid gtd task or list item.", vim.log.levels.WARN, { title = "neowiki" })
      return
    end
    lines[cursor_ln] = _action_create_task(line)
  else
    local is_done = is_marked_done(line)
    if is_done == nil then
      vim.notify("Could not determine task state.", vim.log.levels.WARN, { title = "neowiki" })
      return
    end
    lines[cursor_ln] = is_done and _action_uncomplete_task(line) or _action_complete_task(line)
  end

  _run_consistency_pass(lines, cursor_ln)
  vim.api.nvim_win_set_cursor(0, original_cursor)
end

---
-- Handles toggling tasks in a visual selection. Operates on the provided `lines` table.
-- @param lines (table): The buffer lines, to be modified in-place.
--
local function _toggle_visual_selection(lines)
  local start_ln, end_ln = vim.fn.line("'<"), vim.fn.line("'>")
  if start_ln > end_ln then
    start_ln, end_ln = end_ln, start_ln
  end

  local STATE_INVALID, STATE_SIMPLE_LIST, STATE_NOT_DONE, STATE_DONE = 0, 1, 2, 3

  local function get_line_state(line)
    if get_list_marker_info(line) == nil then
      return STATE_INVALID
    end
    if get_task_content_start_col(line) == nil then
      return STATE_SIMPLE_LIST
    end
    return is_marked_done(line) and STATE_DONE or STATE_NOT_DONE
  end

  local initial_state = get_line_state(lines[start_ln])

  for i = start_ln, end_ln do
    if get_line_state(lines[i]) ~= initial_state then
      local msg = initial_state == STATE_INVALID
          and "Visual selection contains non-list items. Aborting."
        or "Visual selection contains tasks with mixed states. Aborting."
      vim.notify(msg, vim.log.levels.WARN, { title = "neowiki" })
      return
    end
  end

  local uniform_action
  if initial_state == STATE_SIMPLE_LIST then
    uniform_action = _action_create_task
  elseif initial_state == STATE_NOT_DONE then
    uniform_action = _action_complete_task
  elseif initial_state == STATE_DONE then
    uniform_action = _action_uncomplete_task
  else
    return -- Invalid state, do nothing.
  end

  for i = start_ln, end_ln do
    lines[i] = uniform_action(lines[i])
  end
  for i = start_ln, end_ln do
    _run_consistency_pass(lines, i)
  end
end

---
-- Main public function to toggle a task's state. Orchestrates reading from
-- and writing to the buffer to minimize API calls.
-- @param opts (table|nil): Can contain `{ visual = true }` to trigger visual mode.
--
gtd.toggle_task = function(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local original_lines_copy = vim.deepcopy(lines)

  if opts.visual then
    _toggle_visual_selection(lines)
  else
    _toggle_single_line(lines)
  end

  if not vim.deep_equal(lines, original_lines_copy) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  gtd.update_progress(lines)
end

---
-- Runs a full validation pass on all tasks in the buffer.
-- This is intended to be called from an autocommand on text change to handle
-- all cases, including adding, deleting, and moving tasks.
-- It iterates from the bottom up to ensure dependencies are resolved correctly.
--
gtd.run_full_validation = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- If no tasks exist in the file, skip the rest of the checking
  if not content:match("%[%s%]") and not content:match("%[x%]") then
    return
  end

  local original_lines_copy = vim.deepcopy(lines)

  -- Iterate from the bottom of the file to the top. This ensures that when
  -- we validate a parent, its children have already been processed in this pass.
  for ln = #lines, 1, -1 do
    if get_task_content_start_col(lines[ln]) then
      validate_parent_tasks(lines, ln)
    end
  end

  if not vim.deep_equal(lines, original_lines_copy) then
    -- Preserve cursor position across buffer updates
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, cursor)
  end
end

return gtd
