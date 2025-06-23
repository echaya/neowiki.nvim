local config = require("neowiki.config")
local gtd = {}

-- Namespace for the progress virtual text.
local progress_ns = vim.api.nvim_create_namespace("neowiki_gtd_progress")

-- Cache to hold the GTD tree structure for each buffer.
-- Key: bufnr, Value: { tree = {...}, nodes = {...} }
local gtd_cache = {}

---
-- Parses a line to determine its list and task properties.
-- @param line (string) The line content.
-- @return (table|nil) A table with parsed info, or nil if not a list item.
--
local function _parse_line(line)
  -- First, try to match the line as a full task item. This is the most specific pattern.
  local task_prefix = line:match("^(%s*[%*%-+]%s*%[.%]%s+)") -- Unordered task
  if not task_prefix then
    task_prefix = line:match("^(%s*%d+[.%)%)]%s*%[.%]%s+)") -- Ordered task
  end

  if task_prefix then
    -- It's definitely a task.
    local indent_str = task_prefix:match("^(%s*)")
    return {
      is_task = true,
      is_done = task_prefix:find("%[x%]") ~= nil,
      level = #indent_str,
      content_col = #task_prefix + 1,
    }
  end

  -- If it's not a task, check if it's a simple list item we can convert.
  local list_prefix = line:match("^(%s*[%*%-+]%s+)") -- Unordered list
  if not list_prefix then
    list_prefix = line:match("^(%s*%d+[.%)%)]%s+)") -- Ordered list
  end

  if list_prefix then
    -- It's a simple list item.
    local indent_str = list_prefix:match("^(%s*)")
    return {
      is_task = false,
      is_done = nil,
      level = #indent_str,
      content_col = #list_prefix + 1,
    }
  end

  -- If neither pattern matched, it's not a list item at all.
  return nil
end

---
-- Builds a tree structure representing the GTD tasks in the buffer.
-- @param bufnr (number) The buffer number to process.
--
local function _build_gtd_tree(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local nodes_by_lnum = {}
  local root_nodes = {}
  local last_nodes_by_level = {} -- Helps find the parent efficiently

  -- Pass 1: Create a node for each list item
  for i, line in ipairs(lines) do
    local parsed_info = _parse_line(line)
    if parsed_info then
      local node = {
        lnum = i,
        line_content = line,
        level = parsed_info.level,
        content_col = parsed_info.content_col,
        is_task = parsed_info.is_task,
        is_done = parsed_info.is_done,
        parent = nil,
        children = {},
      }
      nodes_by_lnum[i] = node
    end
  end

  -- Pass 2: Link nodes into a hierarchy
  for i = 1, #lines do
    local node = nodes_by_lnum[i]
    if node then
      last_nodes_by_level[node.level] = node
      if node.level > 0 then
        -- Find the nearest parent at a lower indentation level
        for level = node.level - 1, 0, -1 do
          if last_nodes_by_level[level] then
            node.parent = last_nodes_by_level[level]
            table.insert(node.parent.children, node)
            break
          end
        end
      end

      -- If no parent was found, it's a root node
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

---
-- Recursively calculates the completion progress for a given node.
-- @param node (table) The node to calculate progress for.
-- @return (number, boolean) Progress (0.0-1.0) and whether the node has children.
--
local function _calculate_progress_from_node(node)
  if #node.children == 0 then
    return (node.is_task and node.is_done) and 1.0 or 0.0, false
  end

  local children_progress_total = 0
  local task_children_count = 0

  for _, child in ipairs(node.children) do
    if child.is_task then
      task_children_count = task_children_count + 1
      local child_progress, _ = _calculate_progress_from_node(child)
      children_progress_total = children_progress_total + child_progress
    end
  end

  if task_children_count == 0 then
    return (node.is_task and node.is_done) and 1.0 or 0.0, true
  end

  return children_progress_total / task_children_count, true
end

---
-- Checks if all of a node's direct task-children are in a 'done' state.
-- @param node (table) The parent node to check.
-- @return (boolean)
--
local function _are_all_task_children_done(node)
  if #node.children == 0 then
    return false
  end
  local has_task_children = false
  for _, child in ipairs(node.children) do
    if child.is_task then
      has_task_children = true
      if not child.is_done then
        return false
      end
    end
  end
  return has_task_children
end

---
-- Validates the entire tree, ensuring parent task states match their children.
-- @param bufnr (number) The buffer to validate.
-- @return (boolean) Returns true if any changes were made to the buffer.
--
local function _apply_tree_validation(bufnr)
  local cache = gtd_cache[bufnr]
  if not cache or not cache.nodes then
    return false
  end

  local lines_to_change = {}

  for lnum = vim.api.nvim_buf_line_count(bufnr), 1, -1 do
    local node = cache.nodes[lnum]
    if node and node.is_task then
      local should_be_done
      if #node.children > 0 then
        should_be_done = _are_all_task_children_done(node)
      else
        should_be_done = node.is_done
      end

      if node.is_done ~= should_be_done then
        local line = node.line_content
        if should_be_done then
          lines_to_change[lnum] = line:gsub("%[ %]", "[x]", 1)
        else
          lines_to_change[lnum] = line:gsub("%[x%]", "[ ]", 1)
        end
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

--------------------------------------------------------------------------------
-- Public API and Buffer Operations
--------------------------------------------------------------------------------

---
-- Updates the virtual text for GTD progress based on the cached tree.
-- @param bufnr (number) The buffer to update.
--
gtd.update_progress = function(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, progress_ns, 0, -1)

  if not config.gtd or not config.gtd.show_gtd_progress or not gtd_cache[bufnr] then
    return
  end

  for lnum, node in pairs(gtd_cache[bufnr].nodes) do
    if node.is_task then
      local progress, has_children = _calculate_progress_from_node(node)
      if has_children and progress < 1.0 then
        local display_text = string.format(" [ %.0f%% ]", progress * 100)
        vim.api.nvim_buf_set_extmark(bufnr, progress_ns, lnum - 1, -1, {
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
  local cache = gtd_cache[bufnr]
  if not cache then
    return
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
    if is_done then
      return line:gsub("%[ %]", "[x]", 1)
    else
      return line:gsub("%[x%]", "[ ]", 1)
    end
  end

  local function are_all_children_done(node)
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

  local function process_node(lnum)
    local node = cache.nodes[lnum]
    if not node then
      return
    end

    if not node.is_task then
      local new_state_is_done = are_all_children_done(node)
      local current_line = get_future_line(lnum)
      local prefix = current_line:sub(1, node.content_col - 1)
      local suffix = current_line:sub(node.content_col)
      local marker = new_state_is_done and "[x] " or "[ ] "
      lines_to_change[lnum] = prefix .. marker .. suffix
    else
      local new_state_is_done = not node.is_done
      lines_to_change[lnum] = get_line_for_state(node, new_state_is_done)
      cascade_down(node, new_state_is_done)
    end
  end

  if opts.visual then
    local start_ln, end_ln = vim.fn.line("'<"), vim.fn.line("'>")
    for i = start_ln, end_ln do
      process_node(i)
    end
  else
    process_node(vim.api.nvim_win_get_cursor(0)[1])
  end

  if not vim.tbl_isempty(lines_to_change) then
    local original_cursor = vim.api.nvim_win_get_cursor(0)
    for lnum, line in pairs(lines_to_change) do
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line })
    end
    vim.api.nvim_win_set_cursor(0, original_cursor)
  end
end

---
-- Attaches GTD functionality to a buffer.
-- @param bufnr (number) The buffer number to attach to.
--
gtd.attach_to_buffer = function(bufnr)
  local function run_update_pipeline(b)
    _build_gtd_tree(b)
    local changes_made = _apply_tree_validation(b)
    if changes_made then
      _build_gtd_tree(b)
    end
    gtd.update_progress(b)
  end

  run_update_pipeline(bufnr)

  local attached, err = pcall(vim.api.nvim_buf_attach, bufnr, false, {
    on_lines = function(_, b, _, _, _, _)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(b) then
          run_update_pipeline(b)
        end
      end, 200)
    end,
    on_detach = function(_, b)
      gtd_cache[b] = nil
    end,
  })

  if not attached then
    vim.notify("neowiki: Failed to attach GTD handler to buffer. " .. tostring(err), vim.log.levels.WARN)
  end
end

return gtd
