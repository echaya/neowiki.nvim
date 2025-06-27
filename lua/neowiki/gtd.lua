local config = require("neowiki.config")
local gtd = {}

-- Namespace for the progress virtual text.
local progress_ns = vim.api.nvim_create_namespace("neowiki_gtd_progress")

-- A module-level cache to hold the GTD tree structure for each buffer.
-- The key is the buffer number, and the value is the cached tree data.
local gtd_cache = {}

---
-- Parses a single line to determine its list and task properties.
-- @param line (string) The line content to parse.
-- @return (table|nil) A table with parsed info (`is_task`, `is_done`, `level`,
--   `content_col`), or nil if the line is not a list item.
--
local function _parse_line(line)
  -- Handles unordered lists like `* `, `- `, `+ `
  local task_prefix = line:match("^(%s*[%*%-+]%s*%[.%]%s+)")
  if not task_prefix then
    -- Handles ordered lists like `1. `, `2) `
    task_prefix = line:match("^(%s*%d+[.%)%)]%s*%[.%]%s+)")
  end

  if task_prefix then
    local indent_str = task_prefix:match("^(%s*)")
    return {
      is_task = true,
      is_done = task_prefix:find("%[x%]") ~= nil,
      level = #indent_str,
      content_col = #task_prefix + 1,
    }
  end

  -- Match list items that are not tasks.
  local list_prefix = line:match("^(%s*[%*%-+]%s+)")
  if not list_prefix then
    list_prefix = line:match("^(%s*%d+[.%)%)]%s+)")
  end

  if list_prefix then
    local indent_str = list_prefix:match("^(%s*)")
    return {
      is_task = false,
      is_done = nil,
      level = #indent_str,
      content_col = #list_prefix + 1,
    }
  end

  return nil
end

---
-- Builds a tree structure representing the GTD tasks in the buffer.
-- It runs in two passes:
-- 1. Create a node for every list item in the file.
-- 2. Link the nodes into a parent-child hierarchy based on indentation.
-- @param bufnr (number) The buffer number to process.
--
local function _build_gtd_tree(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local nodes_by_lnum = {}
  local root_nodes = {}
  local last_nodes_by_level = {} -- Tracks the most recent node at each indent level.

  -- Pass 1: Create a node for each list item.
  for i, line in ipairs(lines) do
    local parsed_info = _parse_line(line)
    if parsed_info then
      nodes_by_lnum[i] = {
        lnum = i,
        line_content = line,
        level = parsed_info.level,
        content_col = parsed_info.content_col,
        is_task = parsed_info.is_task,
        is_done = parsed_info.is_done,
        parent = nil,
        children = {},
      }
    end
  end

  -- Pass 2: Link nodes into a hierarchy.
  for i = 1, #lines do
    local node = nodes_by_lnum[i]
    if node then
      -- Set the current node as the last seen for its level.
      last_nodes_by_level[node.level] = node

      -- Clear deeper indentation levels to prevent a new branch from being
      -- incorrectly attached to an old, unrelated one.
      for level = node.level + 1, #last_nodes_by_level do
        if last_nodes_by_level[level] then
          last_nodes_by_level[level] = nil
        end
      end

      -- Find the nearest parent at a strictly lower indentation level.
      if node.level > 0 then
        for level = node.level - 1, 0, -1 do
          if last_nodes_by_level[level] then
            node.parent = last_nodes_by_level[level]
            table.insert(node.parent.children, node)
            break
          end
        end
      end

      if not node.parent then
        table.insert(root_nodes, node)
      end
    end
  end

  gtd_cache[bufnr] = {
    tree = root_nodes,
    nodes = nodes_by_lnum,
  }
end

-- Forward declaration is needed because _get_child_task_stats and
-- _calculate_progress_from_node call each other (mutual recursion).
local _calculate_progress_from_node

---
-- Gathers completion statistics for a node's direct children.
-- @param node (table) The parent node whose children will be analyzed.
-- @return (table) A table with stats: `{ progress_total, task_count, all_done }`.
--
local function _get_child_task_stats(node)
  local stats = { progress_total = 0, task_count = 0, all_done = true }
  for _, child in ipairs(node.children) do
    if child.is_task then
      stats.task_count = stats.task_count + 1
      local child_progress, _ = _calculate_progress_from_node(child)
      stats.progress_total = stats.progress_total + child_progress
      if not child.is_done then
        stats.all_done = false
      end
    end
  end

  return stats
end

---
-- Recursively calculates the completion percentage for a given node.
-- Acts as a wrapper around the more generic `_get_child_task_stats`.
-- @param node (table) The node to calculate progress for.
-- @return (number, boolean) Progress (0.0-1.0) and whether it has task children.
--
_calculate_progress_from_node = function(node)
  if #node.children == 0 then
    -- Leaf node: Progress is 1.0 if it's a completed task, otherwise 0.0.
    return (node.is_task and node.is_done) and 1.0 or 0.0, false
  end

  local stats = _get_child_task_stats(node)

  if stats.task_count == 0 then
    -- Parent without task child: Progress determined by its own status.
    return (node.is_task and node.is_done) and 1.0 or 0.0, false
  end

  -- Parent with task children: Progress is the average of its children's progress.
  return stats.progress_total / stats.task_count, true
end

---
-- Validates the entire tree, ensuring parent task states match their children.
-- This function is the core of the auto-correction logic.
-- @param bufnr (number) The buffer to validate.
-- @return (boolean) True if any changes were made to the buffer.
--
local function _apply_tree_validation(bufnr)
  local cache = gtd_cache[bufnr]
  if not cache or not cache.nodes then
    return false
  end

  local lines_to_change = {}

  -- Iterate backwards from the last line to the first. This is critical to
  -- ensure children are processed before their parents.
  for lnum = vim.api.nvim_buf_line_count(bufnr), 1, -1 do
    local node = cache.nodes[lnum]
    if node and node.is_task then
      local should_be_done
      local child_stats = _get_child_task_stats(node)
      -- A parent's state is only dictated by its children if it has actual task children.
      if child_stats.task_count > 0 then
        -- Rule 1: Parent with task children. Its state is derived from them.
        should_be_done = child_stats.all_done
      else
        -- Rule 2: A childless task, OR a task with only non-task children.
        -- In this case, its state is its own and should not be auto-corrected.
        should_be_done = node.is_done
      end

      if node.is_done ~= should_be_done then
        local line = node.line_content
        local new_marker = should_be_done and "[x]" or "[ ]"
        local old_marker = should_be_done and "%[ %]" or "%[x%]"
        lines_to_change[lnum] = line:gsub(old_marker, new_marker, 1)
      end
    end
  end

  if not vim.tbl_isempty(lines_to_change) then
    local original_cursor = vim.api.nvim_win_get_cursor(0)
    for lnum, line in pairs(lines_to_change) do
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line })
    end
    vim.api.nvim_win_set_cursor(0, original_cursor)
    return true
  end
  return false
end

---
-- Runs the full update pipeline: builds tree, validates, rebuilds if needed, and updates UI.
-- @param bufnr (number) The buffer number.
--
local function run_update_pipeline(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  if not (content:find("%[ ]") or content:find("%[x]")) then
    -- If no tasks are present, clean the cache and progress
    gtd_cache[bufnr] = nil
    gtd.update_progress(bufnr)
    return
  end

  _build_gtd_tree(bufnr)
  local changes_made = _apply_tree_validation(bufnr)
  -- If validation changed the buffer, the tree is now stale and must be rebuilt
  -- to ensure the UI is updated with the final, correct state.
  if changes_made then
    _build_gtd_tree(bufnr)
  end
  gtd.update_progress(bufnr)
end

---
-- Updates the virtual text for GTD progress based on the cached tree.
-- @param bufnr (number) The buffer to update.
--
gtd.update_progress = function(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)
  local cache = gtd_cache[bufnr]
  if not config.gtd or not config.gtd.show_gtd_progress or not cache then
    return
  end

  for _, node in pairs(cache.nodes) do
    if node.is_task then
      local progress, has_task_children = _calculate_progress_from_node(node)
      if has_task_children and progress < 1.0 then
        local display_text = string.format(" [ %.0f%% ]", progress * 100)
        vim.api.nvim_buf_set_extmark(bufnr, progress_ns, node.lnum - 1, -1, {
          virt_text = { { display_text, config.gtd.gtd_progress_hl_group or "Comment" } },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

-- Local state for the toggle operation, acting as a context.
local toggle_op = {
  lines_to_change = {},
  cache = nil,
}

---
-- Gets the future content of a line, considering pending changes.
-- @param lnum (number) The line number.
-- @return (string|nil) The line content.
local function _get_future_line(lnum)
  return toggle_op.lines_to_change[lnum]
    or (toggle_op.cache.nodes[lnum] and toggle_op.cache.nodes[lnum].line_content)
end

---
-- Generates the new line content for a task with a specific state.
-- @param node (table) The task node.
-- @param is_done (boolean) The desired state.
-- @return (string) The modified line content.
local function _get_line_for_state(node, is_done)
  local line = _get_future_line(node.lnum)
  if not line or not node.is_task then
    return line
  end
  local new_marker = is_done and "[x]" or "[ ]"
  local old_marker = is_done and "%[ %]" or "%[x%]"
  return line:gsub(old_marker, new_marker, 1)
end

---
-- Recursively marks a node and all its descendants with the new state.
-- @param node (table) The starting node.
-- @param new_state_is_done (boolean) The new state to apply.
local function _cascade_down(node, new_state_is_done)
  for _, child in ipairs(node.children) do
    if child.is_task then
      toggle_op.lines_to_change[child.lnum] = _get_line_for_state(child, new_state_is_done)
      _cascade_down(child, new_state_is_done)
    end
  end
end

---
-- Toggles the state of an existing task and cascades the change down to its children.
-- @param node (table) The task node to toggle.
local function _toggle_existing_task(node)
  local new_state_is_done = not node.is_done
  toggle_op.lines_to_change[node.lnum] = _get_line_for_state(node, new_state_is_done)
  _cascade_down(node, new_state_is_done)
end

---
-- Determines if a new task (converted from a list item) should be marked as done.
-- This is true if it has task children and they are all already done.
-- @param node (table) The node being converted to a task.
-- @return (boolean) True if the new task should be marked done.
local function _should_new_task_be_done(node)
  if #node.children == 0 then
    return false -- A new childless task always starts as not done.
  end
  local has_task_children = false
  for _, child in ipairs(node.children) do
    if child.is_task then
      has_task_children = true
      local child_line = _get_future_line(child.lnum)
      -- If any child task is not done, the new parent task should not be done.
      if child_line and child_line:find("%[ %]") then
        return false
      end
    end
  end
  return has_task_children -- True only if it has task children and none are incomplete.
end

---
-- Gathers all direct ancestors of a node that are plain list items (not tasks).
-- @param start_node (table) The node to start searching up from.
-- @return (table) A list of ancestor nodes.
local function _get_non_task_ancestors(start_node)
  local ancestors = {}
  local current_node = start_node
  while current_node.parent and not current_node.parent.is_task do
    table.insert(ancestors, current_node.parent)
    current_node = current_node.parent
  end
  return ancestors
end

---
-- Converts one or more list items into tasks, handling user prompts for ancestor conversion.
-- @param node (table) The primary list item to convert.
-- @param is_batch_operation (boolean) True if part of a multi-line visual selection.
local function _create_task_from_list_item(node, is_batch_operation)
  local nodes_to_create = { node }

  -- Only prompt to convert ancestors for single-line, interactive operations.
  if not is_batch_operation then
    local non_task_ancestors = _get_non_task_ancestors(node)
    if #non_task_ancestors > 0 then
      local prompt =
        string.format("Convert %d parent item(s) to tasks as well?", #non_task_ancestors)
      local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2, "Question")
      if choice == 1 then
        for _, ancestor in ipairs(non_task_ancestors) do
          table.insert(nodes_to_create, ancestor)
        end
      end
    end
  end

  -- Process each node for creation. The list is naturally bottom-up, which is
  -- required for `_should_new_task_be_done` to work correctly at each level.
  for _, node_to_create in ipairs(nodes_to_create) do
    local new_state_is_done = _should_new_task_be_done(node_to_create)
    local current_line = _get_future_line(node_to_create.lnum)
    local prefix = current_line:sub(1, node_to_create.content_col - 1)
    local suffix = current_line:sub(node_to_create.content_col)
    local marker = new_state_is_done and "[x] " or "[ ] "
    toggle_op.lines_to_change[node_to_create.lnum] = prefix .. marker .. suffix
  end
end

---
-- Main handler for toggling a single line, dispatching to create or toggle.
-- @param lnum (number) The line number to process.
-- @param is_batch (boolean) True if part of a multi-line operation.
local function _process_lnum(lnum, is_batch)
  local node = toggle_op.cache.nodes[lnum]
  if not node then
    return
  end

  if not node.is_task then
    _create_task_from_list_item(node, is_batch)
  else
    _toggle_existing_task(node)
  end
end

---
-- Handles toggling tasks for a visual selection, including validation.
-- @param start_ln (number) The starting line number of the selection.
-- @param end_ln (number) The ending line number of the selection.
local function _process_visual_selection(start_ln, end_ln)
  local function get_node_state(node)
    if not node then
      return "INVALID"
    end
    if not node.is_task then
      return "LIST_ITEM"
    end
    return node.is_done and "COMPLETE" or "NOT_COMPLETE"
  end

  -- 1. Validation Pass: Ensure all items in selection have a consistent state.
  local first_node_state = nil
  for i = start_ln, end_ln do
    local node = toggle_op.cache.nodes[i]
    local current_state = get_node_state(node)
    if current_state == "INVALID" then
      vim.notify("Neowiki: Selection contains non-list items. Aborting.", vim.log.levels.WARN)
      return
    end
    if not first_node_state then
      first_node_state = current_state
    elseif first_node_state ~= current_state then
      vim.notify(
        "Neowiki: Selection contains items with mixed states. Aborting.",
        vim.log.levels.WARN
      )
      return
    end
  end

  -- 2. Action Pass: Process each line in the validated selection.
  for i = start_ln, end_ln do
    _process_lnum(i, true)
  end
end

---
-- Toggles the state of a task.
-- @param opts (table|nil) Can contain `{ visual = true }`
--
gtd.toggle_task = function(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()

  -- This ensures the function always operates on fresh data and prevents race
  -- conditions with the debounced on_lines handler.
  _build_gtd_tree(bufnr)

  toggle_op.cache = gtd_cache[bufnr]
  if not toggle_op.cache then
    return -- Guard if buffer has no list items at all
  end

  -- Reset the pending changes for this operation.
  toggle_op.lines_to_change = {}

  if opts.visual then
    local start_ln, end_ln = vim.fn.line("'<"), vim.fn.line("'>")
    _process_visual_selection(start_ln, end_ln)
  else
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    _process_lnum(lnum, false)
  end

  -- Apply accumulated changes to the buffer if any were made.
  if not vim.tbl_isempty(toggle_op.lines_to_change) then
    local original_cursor = vim.api.nvim_win_get_cursor(0)
    for lnum, line in pairs(toggle_op.lines_to_change) do
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line })
    end
    vim.api.nvim_win_set_cursor(0, original_cursor)
    -- After making changes, run the full pipeline to validate and update UI.
    run_update_pipeline(bufnr)
  end
end

---
-- Attaches GTD functionality to a buffer. This is the main entry point from init.lua.
-- @param bufnr (number) The buffer number to attach to.
--
gtd.attach_to_buffer = function(bufnr)
  -- Run the pipeline once when the buffer is first entered to establish state.
  run_update_pipeline(bufnr)

  -- Create a buffer-local autocommand group to ensure events are cleaned up
  -- automatically when the buffer is closed or reloaded.
  local group = vim.api.nvim_create_augroup("neowiki_gtd_listener_" .. bufnr, { clear = true })

  -- Listen for text changes in both Insert and Normal mode.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          run_update_pipeline(bufnr)
        end
      end, 200) -- Debounce delay in milliseconds.
    end,
    desc = "Debounced GTD update on text change",
  })

  -- Listen for when the buffer is detached (e.g., closed) to clean up the cache.
  -- This prevents memory leaks.
  vim.api.nvim_create_autocmd({ "BufUnload" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      gtd_cache[bufnr] = nil
    end,
    desc = "Clean up GTD cache on buffer detach",
  })
end
return gtd
