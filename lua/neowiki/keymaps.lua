-- lua/neowiki/keymap.lua
local util = require("neowiki.util")
local config = require("neowiki.config")

local M = {}

---
-- Wraps a function in a keymap that can be repeated with the `.` operator.
-- It leverages the `repeat.vim` plugin functionality.
-- @param mode (string|table): The keymap mode (e.g., "n", "v").
-- @param lhs (string): The left-hand side of the mapping (must start with `<Plug>`).
-- @param rhs (function): The function to execute.
-- @return (string): The `lhs` of the mapping.
--
local make_repeatable = function(mode, lhs, rhs)
  vim.validate({
    mode = { mode, { "string", "table" } },
    rhs = { rhs, "function" },
    lhs = { lhs, "string" },
  })
  if not vim.startswith(lhs, "<Plug>") then
    error("`lhs` should start with `<Plug>`, given: " .. lhs)
  end
  vim.keymap.set(mode, lhs, function()
    rhs()
    -- Make the action repeatable with '.'
    pcall(vim.fn["repeat#set"], vim.api.nvim_replace_termcodes(lhs, true, true, true))
  end)
  return lhs
end

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
    vim.notify("No more links found in this direction", vim.log.levels.INFO, { title = "neowiki" })
  else
    -- Clear search highlighting after a successful jump.
    vim.cmd("noh")
  end
end

---
-- Creates buffer-local keymaps for the current wiki file.
-- These keymaps are defined in the user's configuration.
-- @param buffer_number (number): The buffer number to attach the keymaps to.
--
M.create_buffer_keymaps = function(buffer_number)
  -- Make the gtd toggle function repeatable for normal mode.
  make_repeatable("n", "<Plug>(neowikiToggleTask)", function()
    require("neowiki.features.gtd").toggle_task()
  end)

  -- Defines the behavior of logical actions across different modes.
  local logical_actions = {
    action_link = {
      n = { rhs = require("neowiki.api").follow_link, desc = "Follow Wiki Link" },
      v = {
        rhs = ":'<,'>lua require('neowiki.api').create_or_open_wiki_file()<CR>",
        desc = "Create Link from Selection",
      },
    },
    action_link_vsplit = {
      n = {
        rhs = function()
          require("neowiki.api").follow_link("vsplit")
        end,
        desc = "Follow Wiki Link (VSplit)",
      },
      v = {
        rhs = ":'<,'>lua require('neowiki.api').create_or_open_wiki_file('vsplit')<CR>",
        desc = "Create Link from Selection (VSplit)",
      },
    },
    action_link_split = {
      n = {
        rhs = function()
          require("neowiki.api").follow_link("split")
        end,
        desc = "Follow Wiki Link (Split)",
      },
      v = {
        rhs = ":'<,'>lua require('neowiki.api').create_or_open_wiki_file('split')<CR>",
        desc = "Create Link from Selection (Split)",
      },
    },
    toggle_task = {
      n = { rhs = "<Plug>(neowikiToggleTask)", desc = "Toggle Task Status", remap = true },
      v = {
        rhs = ":'<,'>lua require('neowiki.features.gtd').toggle_task({ visual = true })<CR>",
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
      n = { rhs = require("neowiki.api").jump_to_index, desc = "Jump to Index" },
    },
    delete_page = {
      n = { rhs = require("neowiki.api").delete_wiki_page, desc = "Delete Wiki Page" },
    },
    cleanup_links = {
      n = { rhs = require("neowiki.api").cleanup_broken_links, desc = "Clean Broken Links" },
    },
    insert_link = {
      n = { rhs = require("neowiki.api").insert_wiki_link, desc = "Insert link to a page" },
    },
    rename_page = {
      n = { rhs = require("neowiki.api").rename_wiki_page, desc = "Rename current page" },
    },
    navigate_back = {
      n = { rhs = require("neowiki.api").navigate_back, desc = "Navigate Back" },
    },
    navigate_forward = {
      n = { rhs = require("neowiki.api").navigate_forward, desc = "Navigate Forward" },
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

return M
