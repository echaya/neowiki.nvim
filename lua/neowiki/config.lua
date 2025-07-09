--- lua/neowiki/config.lua
---@class neowiki.Config
---@field public wiki_dirs table|nil Defines the wiki directories. Can be a single table or a list of tables.
---@field public index_file string The filename for the index file of a wiki.
---@field public keymaps table Defines the keymappings for various modes.
---@field public gtd table Defines settings for GTD list functionality.
local config = {
  -- A list of tables, where each table defines a wiki.
  -- Both absolute and tilde-expanded paths are supported.
  -- If this is nil, the plugin defaults to `~/wiki`.
  -- Example:
  -- wiki_dirs = {
  --   { name = "Work", path = "~/Documents/work-wiki" },
  --   { name = "Personal", path = "personal-wiki" },
  -- }
  wiki_dirs = nil,

  -- The filename for a wiki's index page (e.g., "index.md").
  -- The file extension is used as the default for new notes.
  index_file = "index.md",

  -- Automatically discover and register nested wiki roots.
  -- A nested root is a sub-directory within your wiki that contains its own index file.
  -- Enabling this is useful for navigating large wiki with nested structures, but may add a minor delay on startup
  -- Note: The search is faster if `rg`, `fd`, or `git` are installed.
  discover_nested_roots = false,

  -- Defines the keymaps used by neowiki.
  -- Setting a keymap to `false` or an empty string will disable it.
  keymaps = {
    -- In Normal mode, follows the link under the cursor.
    -- In Visual mode, creates a link from the selection.
    action_link = "<CR>",
    action_link_vsplit = "<S-CR>",
    action_link_split = "<C-CR>",

    -- Jumps to the next link in the buffer.
    next_link = "<Tab>",
    -- Jumps to the previous link in the buffer.
    prev_link = "<S-Tab>",
    -- Navigate back and forward in Browse history
    navigate_back = "[[",
    navigate_forward = "]]",
    -- Jumps to the index page of the current wiki.
    jump_to_index = "<Backspace>",

    -- Deletes the current wiki page.
    delete_page = "<leader>wd",
    -- Removes all links in the current file that point to non-existent pages.
    cleanup_links = "<leader>wc",
    -- Opens a selector to find and insert a link to another wiki page.
    insert_link = "<leader>wi",
    -- Keymap to rename the current wiki page.
    rename_page = "<leader>wr",

    -- Toggles the status of a gtd item.
    -- Works on the current line in Normal mode and on the selection in Visual mode.
    toggle_task = "<leader>wt",

    -- Keymap to close the floating wiki.
    close_float = "q",
  },

  -- Configuration for the GTD functionality.
  gtd = {
    -- Set to false to disable the progress percentage virtual text.
    show_gtd_progress = true,
    -- The highlight group to use for the progress virtual text.
    gtd_progress_hl_group = "Comment",
  },

  -- Configuration for opening wiki in floating window.
  floating_wiki = {
    -- Config for nvim_open_win(). Defines the window's structure,
    -- position, and border. These are the default values.
    open = {
      relative = "editor",
      width = 0.9,
      height = 0.9,
      border = "rounded",
    },

    -- Options for nvim_win_set_option(). Defines the behavior
    -- within the window after it's created. e.g., winblend = 0 to
    -- override the default winblend for floating window to 0 opacity
    -- Left empty by default.
    style = {},
  },
}

return config

