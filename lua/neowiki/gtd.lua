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
  -- First, try to match the line as a full task item (e.g., `* [ ] ...`).
  local task_prefix = line:match("^(%s*[%*%-+]%s*%[.%]%s+)")
  if not task_prefix then
    task_prefix = line:match("^(%s*%d+[.%)%)]%s*%[.%]%s+)") -- Handles ordered lists like `1. `
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

      -- a new branch from being incorrectly attached to an old, unrelated one.
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
  -- A parent with no task children cannot be considered "all done" by its children.
  if stats.task_count == 0 then
    stats.all_done = false
  end
  return stats
end

---
-- Recursively calculates the completion percentage for a given node.
-- Now acts as a wrapper around the more generic `_get_child_task_stats`.
-- @param node (table) The node to calculate progress for.
-- @return (number, boolean) Progress (0.0-1.0) and whether the node has children.
--
_calculate_progress_from_node = function(node)
  if #node.children == 0 then
    -- Leaf node: Progress is 1.0 if it's a completed task, otherwise 0.0.
    return (node.is_task and node.is_done) and 1.0 or 0.0, false
  end

  local stats = _get_child_task_stats(node)

  if stats.task_count == 0 then
    -- Parent with no task children: Progress is determined by its own status.
    return (node.is_task and node.is_done) and 1.0 or 0.0, true
  end

  return stats.progress_total / stats.task_count, true
end

---
-- Checks if all of a node's direct task-children are in a 'done' state.
-- Now acts as a simple wrapper around `_get_child_task_stats`.
-- @param node (table) The parent node to check.
-- @return (boolean) True if all task children are complete, otherwise false.
--
local function _are_all_task_children_done(node)
  -- This function is used for tree validation and reads from the built cache.
  return _get_child_task_stats(node).all_done
end

---
-- Validates the entire tree, ensuring parent task states match their children.
-- This function is idempotent and is the core of the auto-correction logic.
-- @param bufnr (number) The buffer to validate.
-- @return (boolean) True if any changes were made to the buffer.
--
local function _apply_tree_validation(bufnr)
  local cache = gtd_cache[bufnr]
  if not cache or not cache.nodes then
    return false
  end

  local lines_to_change = {}

  -- Iterate backwards from the last line to the first.
  -- This is critical to ensure children are processed before their parents.
  for lnum = vim.api.nvim_buf_line_count(bufnr), 1, -1 do
    local node = cache.nodes[lnum]
    if node and node.is_task then
      local should_be_done
      if #node.children > 0 then
        -- Rule 1: This is a parent task. Its state is dictated by its children.
        should_be_done = _are_all_task_children_done(node)
      else
        -- Rule 2: This is a childless task. Its state is its own and must be preserved.
        should_be_done = node.is_done
      end

      if node.is_done ~= should_be_done then
        local line = node.line_content
        lines_to_change[lnum] =
          line:gsub(should_be_done and "%[ %]" or "%[x%]", should_be_done and "[x]" or "[ ]", 1)
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
-- This is the central orchestrator for all buffer changes.
-- @param b (number) The buffer number.
--
local function run_update_pipeline(b)
  -- early exit if buffer is not valid or does not contain gtd-items
  if not vim.api.nvim_buf_is_loaded(b) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local content = table.concat(lines, "\n")
  if not (content:find("%[ ]") or content:find("%[x]")) then
    gtd.update_progress(b)
    vim.notify("no task detected")
    return
  end

  _build_gtd_tree(b)
  local changes_made = _apply_tree_validation(b)
  -- If validation changed the buffer, the tree is now stale and must be rebuilt
  -- to ensure the UI is updated with the final, correct state.
  if changes_made then
    _build_gtd_tree(b)
  end
  gtd.update_progress(b)
end

---
-- Updates the virtual text for GTD progress based on the cached tree.
-- @param bufnr (number) The buffer to update.
--
gtd.update_progress = function(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)
  if not config.gtd or not config.gtd.show_gtd_progress or not gtd_cache[bufnr] then
    return
  end

  for _, node in pairs(gtd_cache[bufnr].nodes) do
    if node.is_task then
      local progress, has_children = _calculate_progress_from_node(node)
      if has_children and progress < 1.0 then
        local display_text = string.format(" [ %.0f%% ]", progress * 100)
        vim.api.nvim_buf_set_extmark(bufnr, progress_ns, node.lnum - 1, -1, {
          virt_text = { { display_text, config.gtd.gtd_progress_hl_group or "Comment" } },
          virt_text_pos = "eol",
        })
      end
    end
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

  local cache = gtd_cache[bufnr]
  if not cache then
    return
  end -- Guard if buffer has no list items at all

  -- The bootstrap logic for first-time task creation is now implicitly handled
  -- by the main logic, as the cache is guaranteed to exist and be up-to-date.
  if opts.visual and vim.tbl_isempty(cache.nodes) then
    return -- Don't operate on an empty buffer in visual mode.
  end

  local lines_to_change = {}

  local function get_future_line(lnum)
    return lines_to_change[lnum] or (cache.nodes[lnum] and cache.nodes[lnum].line_content)
  end

  local function get_line_for_state(node, is_done)
    local line = get_future_line(node.lnum)
    if not line or not node.is_task then
      return line
    end
    return line:gsub(is_done and "%[ %]" or "%[x%]", is_done and "[x]" or "[ ]", 1)
  end

  local function should_new_task_be_done(node)
    if #node.children == 0 then
      return false
    end
    local has_task_children = false
    for _, child in ipairs(node.children) do
      if child.is_task then
        has_task_children = true
        local child_line = get_future_line(child.lnum)
        if child_line and child_line:find("%[ %]") then
          return false
        end
      end
    end
    return has_task_children
  end

  local function cascade_down(node, new_state_is_done)
    for _, child in ipairs(node.children) do
      if child.is_task then
        lines_to_change[child.lnum] = get_line_for_state(child, new_state_is_done)
        cascade_down(child, new_state_is_done)
      end
    end
  end

  local function _get_non_task_ancestors(start_node)
    local ancestors = {}
    local current_node = start_node
    while current_node.parent and not current_node.parent.is_task do
      table.insert(ancestors, current_node.parent)
      current_node = current_node.parent
    end
    return ancestors
  end

  local function _toggle_existing_task(node)
    local new_state_is_done = not node.is_done
    lines_to_change[node.lnum] = get_line_for_state(node, new_state_is_done)
    cascade_down(node, new_state_is_done)
  end

  local function _create_task_from_list_item(node, is_batch_operation)
    local nodes_to_create = { node }

    -- Only check for ancestors and show the pop-up for single-item, non-batch operations.
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

    -- Process each node marked for creation. The list is naturally in a
    -- bottom-up order ([child, parent, grandparent]), which is required
    -- for `should_new_task_be_done` to work correctly at each level.
    for _, node_to_create in ipairs(nodes_to_create) do
      local new_state_is_done = should_new_task_be_done(node_to_create)
      local current_line = get_future_line(node_to_create.lnum)
      local prefix = current_line:sub(1, node_to_create.content_col - 1)
      local suffix = current_line:sub(node_to_create.content_col)
      local marker = new_state_is_done and "[x] " or "[ ] "
      lines_to_change[node_to_create.lnum] = prefix .. marker .. suffix
    end
  end

  local function process_lnum(lnum, is_batch)
    local node = cache.nodes[lnum]
    if not node then
      return
    end

    if not node.is_task then
      _create_task_from_list_item(node, is_batch)
    else
      _toggle_existing_task(node)
    end
  end

  if opts.visual then
    local start_ln, end_ln = vim.fn.line("'<"), vim.fn.line("'>")
    -- 1. Validation Pass
    local first_node_state = nil
    local function get_node_state(node)
      if not node then
        return "INVALID"
      end
      if not node.is_task then
        return "LIST_ITEM"
      end
      if node.is_done then
        return "COMPLETE"
      end
      return "NOT_COMPLETE"
    end
    for i = start_ln, end_ln do
      local node = cache.nodes[i]
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
    -- 2. Action Pass
    for i = start_ln, end_ln do
      process_lnum(i, true)
    end
  else
    process_lnum(vim.api.nvim_win_get_cursor(0)[1], false)
  end

  if not vim.tbl_isempty(lines_to_change) then
    local original_cursor = vim.api.nvim_win_get_cursor(0)
    for lnum, line in pairs(lines_to_change) do
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line })
    end
    vim.api.nvim_win_set_cursor(0, original_cursor)
    run_update_pipeline(bufnr)
  end
end

---
-- Attaches GTD functionality to a buffer. This is the main entry point from init.lua.
-- @param bufnr (number) The buffer number to attach to.
--
gtd.attach_to_buffer = function(bufnr)
  -- Run the pipeline once when the buffer is first entered.
  run_update_pipeline(bufnr)

  -- Attach to the buffer to run the pipeline on any subsequent changes.
  local attached, err = pcall(vim.api.nvim_buf_attach, bufnr, false, {
    on_lines = function(_, buffer, _, _, _, _)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buffer) then
          run_update_pipeline(buffer)
        end
      end, 200) -- Debounce to avoid excessive updates during rapid typing.
    end,
    on_detach = function(_, b)
      gtd_cache[b] = nil -- Clean up cache when the buffer is no longer active.
    end,
  })

  if not attached then
    vim.notify(
      "neowiki: Failed to attach GTD handler to buffer. " .. tostring(err),
      vim.log.levels.WARN
    )
  end
end

return gtd
