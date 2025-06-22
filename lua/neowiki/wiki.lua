local config = require("neowiki.config")
local gtd = require("neowiki.gtd")
local util = require("neowiki.util")
local state = require("neowiki.state")
local M = {}

---
-- Helper function to detect if the current window is a float.
-- @return boolean True if the window is a float, false otherwise.
--
local function is_float()
  local win_id = vim.api.nvim_get_current_win()
  local conf = vim.api.nvim_win_get_config(win_id)
  return conf.relative and conf.relative ~= ""
end

---
-- Creates buffer-local keymaps for the current wiki file.
-- These keymaps are defined in the user's configuration.
-- @param buffer_number (number): The buffer number to attach the keymaps to.
--
local create_buffer_keymaps = function(buffer_number)
  -- Make the gtd toggle function repeatable for normal mode.
  util.make_repeatable("n", "<Plug>(neowikiToggleTask)", function()
    require("neowiki.gtd").toggle_task()
  end)

  local link_pattern = [[\(\[.\{-}\](.\{-})\)\|\(\[\[.\{-}\]\]\)]]

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
        rhs = (function()
          return string.format(":let @/=%s<CR>nl:noh<CR>", vim.fn.string(link_pattern))
        end)(),
        desc = "Jump to Next Link",
      },
    },
    prev_link = {
      n = {
        rhs = (function()
          return string.format(":let @/=%s<CR>NNl:noh<CR>", vim.fn.string(link_pattern))
        end)(),
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
  }

  -- If we are in a floating window, override split actions to show a notification.
  if is_float() then
    local function notify_disabled()
      vim.notify(
        "action_link_(v)split actions are disabled in a floating window.",
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
-- Finds the most specific wiki root that contains the given buffer path.
-- @param buf_path (string) The absolute path of the buffer to check.
-- @return (string|nil, string|nil) Returns two paths: the primary 'wiki_root' for navigation
--   (e.g., jumping to index) and the 'active_wiki_path' which is the most specific root
--   containing the buffer, used for creating new files.
--
local function find_wiki_for_buffer(buf_path)
  local current_file_path = vim.fn.fnamemodify(buf_path, ":p")
  local normalized_current_path = util.normalize_path_for_comparison(current_file_path)
  local current_filename = vim.fn.fnamemodify(buf_path, ":t"):lower()

  -- Find all wiki roots that contain the current file.
  local matching_wikis = {}
  for _, wiki_info in ipairs(state.processed_wiki_paths) do
    local dir_to_check = wiki_info.normalized
    if not dir_to_check:find("/$") then
      dir_to_check = dir_to_check .. "/"
    end

    if normalized_current_path:find(dir_to_check, 1, true) == 1 then
      table.insert(matching_wikis, wiki_info)
    end
  end

  if #matching_wikis == 0 then
    return nil, nil -- No matching wiki found
  end

  -- The list is pre-sorted by path length, so the first match is the most specific.
  local most_specific_match = matching_wikis[1]
  local wiki_root
  local active_wiki_path = most_specific_match.resolved

  -- If we are in an index file of a nested wiki, the effective root for jumping
  -- to index should be the parent wiki's root.
  if current_filename == config.index_file:lower() and #matching_wikis >= 2 then
    wiki_root = matching_wikis[2].resolved
  else
    -- Otherwise, the most specific path is the root.
    wiki_root = most_specific_match.resolved
  end

  return wiki_root, active_wiki_path
end

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

  local wiki_root, active_wiki_path = find_wiki_for_buffer(buf_path)
  if wiki_root and active_wiki_path then
    vim.b[0].wiki_root = wiki_root
    vim.b[0].active_wiki_path = active_wiki_path
    create_buffer_keymaps(0)
    gtd.update_progress()
  end
end

---
-- Opens a buffer in a styled floating window.
-- @param buffer_number (number): The buffer number to open.
--
local function _open_file_in_float(buffer_number)
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
-- Opens a file at a given path. If the file is already open in a window,
-- it jumps to that window. Otherwise, it opens the file in the current window
-- or via a specified command (e.g., 'vsplit').
-- @param full_path (string): The absolute path to the file.
-- @param open_cmd (string|nil): Optional vim command to open the file (e.g., "vsplit", "tabnew", "float").
--
M._open_file = function(full_path, open_cmd)
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
-- Finds a markdown link under the cursor and opens the target file.
-- @param open_cmd (string|nil): Optional command for opening the file (e.g., 'vsplit').
--
M.follow_link = function(open_cmd)
  local active_wiki_path = vim.b[vim.api.nvim_get_current_buf()].active_wiki_path
  if not active_wiki_path then
    vim.notify("no active wiki path is set")
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.fn.getline(cursor[1])
  local filename = util.process_link(cursor, line)

  if filename and filename:len() > 1 then
    if filename:sub(1, 2) == "./" then
      filename = filename:sub(2, -1)
    end
    local full_path = vim.fs.joinpath(active_wiki_path, filename)
    -- reuse the current floating window to open the new link.
    if is_float() and not open_cmd then
      local bn_to_open = vim.fn.bufnr(full_path, true)
      vim.api.nvim_win_set_buf(0, bn_to_open)
    else
      M._open_file(full_path, open_cmd)
    end
  else
    vim.notify("No link under cursor.", vim.log.levels.WARN, { title = "neowiki" })
  end
end

---
-- Opens the config.index_file of a selected or specified wiki.
-- @param name (string|nil): The name of the wiki to open. If nil, prompts the user.
-- @param open_cmd (string|nil): Optional command for opening the file.
--
local open_wiki_index = function(name, open_cmd)
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
    M._open_file(wiki_index_path, open_cmd)
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
      util.prompt_wiki_dir(config, open_index_from_path)
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
-- Public function to open a wiki's index page in the current window.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
M.open_wiki = function(name)
  open_wiki_index(name)
end

---
-- Public function to open a wiki's index page in a new tab.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
M.open_wiki_new_tab = function(name)
  open_wiki_index(name, "tabnew")
end

---
-- Public function to open a wiki's index page in a floating window.
-- @param name (string|nil): The name of the wiki to open. Prompts if nil and multiple wikis exist.
--
M.open_wiki_floating = function(name)
  open_wiki_index(name, "float")
end

---
-- Adds a new wiki root path to the processed list at runtime.
-- This is triggered when a new nested wiki config.index_file is created.
-- @param path (string) The absolute path to the new wiki root directory.
--
local add_wiki_root = function(path)
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
-- Creates a new wiki page from the visual selection, replacing the selection with a link.
-- Then opens the new page. If the new page is config.index_file, its parent directory
-- is registered as a new wiki root.
-- @param open_cmd (string|nil): Optional command for opening the new file.
--
M.create_or_open_wiki_file = function(open_cmd)
  local selection_start = vim.fn.getpos("'<")
  local selection_end = vim.fn.getpos("'>")
  local line = vim.fn.getline(selection_start[2], selection_end[2])
  local name = line[1]:sub(selection_start[3], selection_end[3])

  local filename = name:gsub(" ", "_"):gsub("[\\?%%*:|'\"<>]", "") .. state.markdown_extension
  local filename_link = "[" .. name .. "](" .. "./" .. filename .. ")"
  local newline = line[1]:sub(0, selection_start[3] - 1)
    .. filename_link
    .. line[1]:sub(selection_end[3] + 1, string.len(line[1]))
  vim.api.nvim_set_current_line(newline)

  local active_wiki_path = vim.b[vim.api.nvim_get_current_buf()].active_wiki_path
  if not active_wiki_path then
    vim.notify("no active wiki path is set")
    return
  end
  local full_path = vim.fs.joinpath(active_wiki_path, filename)
  local dir_path = vim.fn.fnamemodify(full_path, ":h")

  if vim.fn.fnamemodify(filename, ":t") == config.index_file then
    add_wiki_root(dir_path)
  end

  util.ensure_path_exists(dir_path)
  if vim.fn.filereadable(full_path) == 0 then
    local file = io.open(full_path, "w")
    if file then
      file:close()
    end
  end
  M._open_file(full_path, open_cmd)
end

---
-- Jumps to the config.index_file of the wiki that the current buffer belongs to.
--
M.jump_to_index = function()
  local root = vim.b[0].wiki_root
  if root and root ~= "" then
    local index_path = vim.fs.joinpath(root, config.index_file)
    M._open_file(index_path)
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
M.delete_wiki = function()
  local root = vim.b[0].wiki_root
  if not root or root == "" then
    vim.notify("Not a wiki file.", vim.log.levels.WARN, { title = "neowiki" })
    return
  end

  local file_path = vim.api.nvim_buf_get_name(0)
  local file_name = vim.fn.fnamemodify(file_path, ":t")

  -- Prevent deletion of the main config.index_file.
  local normalized_root_index_path =
    util.normalize_path_for_comparison(vim.fs.joinpath(root, config.index_file))
  local normalized_file_path =
    util.normalize_path_for_comparison(vim.fn.fnamemodify(file_path, ":p"))
  if normalized_root_index_path == normalized_file_path then
    vim.notify(
      "Cannot delete the root config.index_file.",
      vim.log.levels.ERROR,
      { title = "neowiki" }
    )
    return
  end

  local choice = vim.fn.confirm('Permanently delete "' .. file_name .. '"?', "&Yes\n&No")
  if choice == 1 then
    local ok, err = pcall(os.remove, file_path)

    if ok then
      vim.notify('Deleted "' .. file_name .. '"', vim.log.levels.INFO, { title = "neowiki" })
      vim.cmd("bdelete! " .. vim.fn.bufnr("%"))
      M.jump_to_index()

      -- Schedule broken link cleanup to run after jumping to the index.
      vim.schedule(function()
        M.cleanup_broken_links()
      end)
    else
      vim.notify("Error deleting file: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
    end
  else
    vim.notify("Delete operation canceled.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

---
-- Scans the current buffer and removes any lines that contain broken markdown links
-- (i.e., links pointing to non-existent files).
--
M.cleanup_broken_links = function()
  local choice = vim.fn.confirm("Clean up all broken links from this page?", "&Yes\n&No")
  if choice ~= 1 then
    vim.notify("Link cleanup skipped.", vim.log.levels.INFO, { title = "neowiki" })
    return
  end

  local current_buf_path = vim.api.nvim_buf_get_name(0)
  local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
  local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  local lines_to_keep = {}
  local deleted_lines_info = {}

  for i, line in ipairs(all_lines) do
    local has_broken_link = false
    local link_targets = util.find_all_link_targets(line)

    for _, target in ipairs(link_targets) do
      local full_target_path = vim.fn.fnamemodify(vim.fs.joinpath(current_dir, target), ":p")
      -- A link is broken if the target file isn't readable.
      if vim.fn.filereadable(full_target_path) == 0 then
        has_broken_link = true
        break
      end
    end

    if has_broken_link then
      table.insert(deleted_lines_info, "Line " .. i .. ": " .. line)
    else
      table.insert(lines_to_keep, line)
    end
  end

  if #deleted_lines_info > 0 then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines_to_keep)
    local message = "Link cleanup complete.\nRemoved "
      .. #deleted_lines_info
      .. " line(s) with broken links:\n"
      .. table.concat(deleted_lines_info, "\n")
    vim.notify(message, vim.log.levels.INFO, {
      title = "neowiki",
      on_open = function(win)
        local width = vim.api.nvim_win_get_width(win)
        local height = #deleted_lines_info + 3
        vim.api.nvim_win_set_config(win, { height = height, width = math.min(width, 100) })
      end,
    })
  else
    vim.notify("No broken links were found.", vim.log.levels.INFO, { title = "neowiki" })
  end
end

return M
