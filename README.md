[![Neovim](https://img.shields.io/badge/Built_for-Neovim-57A143?style=for-the-badge&logo=neovim)](https://neovim.io/)
[![Lua](https://img.shields.io/badge/Made_with-Lua-blueviolet.svg?style=for-the-badge)](https://www.lua.org)
[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](./LICENSE)

# neowiki.nvim

**Modern Vimwiki Successor for Instant Notes & GTD** 🚀📝

-----

## 🌟 Introduction

**neowiki.nvim** is a lightweight, first-class Neovim citizen with Lua finesse, offering a minimal, intuitive workflow out of the box for note-taking and Getting Things Done (GTD).

## 🔥 Key Features

- **Flexible Wiki Access** 🪟  
  Open wikis your way—in the current buffer, a new tab, or a distraction-free floating window for focused note-taking.

- **Effortless Linking & Navigation** 🔗  
  Create and follow markdown links with `<CR>`, split with `<S-CR>` or `<C-CR>`, and jump between links using `<Tab>`/`<S-Tab>`. Navigate page history like a browser with `[[` and `]]`, or return to `index.md` with `<BS>`.

- **Smart Task Management** ✅  
  Toggle tasks with `<leader>wt` (`[ ]` ↔ `[x]`) and track nested task progress in real-time with dynamic updates.

- **Robust Wiki Organization** 📂  
  Manage multiple wikis (e.g., work, personal) with automatic discovery of nested `index.md` files. Easily insert, rename, or delete wiki pages with automatic backlink updates.

- **Neovim-Powered Efficiency** ⚙️  
  Built for Neovim 0.10+, leveraging Lua for speed and seamless integration with Treesitter, markdown rendering, completion, pickers, and your existing setup.

## 📷 Quick Peek
![Demo GIF](https://github.com/echaya/neowiki.nvim/blob/main/assets/demo.gif)

*neowiki.nvim features in action.*


## 🛠️ Getting Started

Requires **Neovim >= 0.10**. For the best experience, install Treesitter’s `markdown` and `markdown_inline` parsers.

### Using Lazy.nvim
```lua
{
  "echaya/neowiki.nvim",
  opts = {
    wiki_dirs = {
      -- neowiki.nvim supports both absolute and tilde-expanded paths
      { name = "Work", path = "~/work/wiki" },
      { name = "Personal", path = "personal/wiki" },
    },
  },
  keys = {
    { "<leader>ww", "<cmd>lua require('neowiki').open_wiki()<cr>", desc = "Open Wiki" },
    { "<leader>wW", "<cmd>lua require('neowiki').open_wiki_floating()<cr>", desc = "Open Wiki in Floating Window" },
    { "<leader>wT", "<cmd>lua require('neowiki').open_wiki_new_tab()<cr>", desc = "Open Wiki in Tab" },
  },
}
```

### Using Mini.deps
```lua
require("mini.deps").add("echaya/neowiki.nvim")
require("neowiki").setup()
vim.keymap.set("n", "<leader>ww", require("neowiki").open_wiki, { desc = "Open Wiki" })
vim.keymap.set("n", "<leader>wW", require("neowiki").open_wiki_floating, { desc = "Open Floating Wiki" })
vim.keymap.set("n", "<leader>wT", require("neowiki").open_wiki_new_tab, { desc = "Open Wiki in Tab" })
```

### Using Vim-Plug
```vim
Plug 'echaya/neowiki.nvim'
lua require('neowiki').setup()
lua vim.keymap.set("n", "<leader>ww", require("neowiki").open_wiki, { desc = "Open Wiki" })
lua vim.keymap.set("n", "<leader>wW", require("neowiki").open_wiki_floating, { desc = "Open Floating Wiki" })
lua vim.keymap.set("n", "<leader>wT", require("neowiki").open_wiki_new_tab, { desc = "Open Wiki in Tab" })
```

## 🚀 Optional Dependencies

`neowiki.nvim` is designed to be fast by leveraging modern command-line tools. While optional, installing them is **highly recommended** for the best performance. If none are found, the plugin gracefully falls back to a native Lua search.

-   **ripgrep (`rg`)**: The primary search tool. It is **required** for the global backlink search used when renaming or deleting pages. Without `rg`, backlink updates will search a limited scope.
-   **fd**: A fast file finder, used as the second choice if `rg` is not available for listing pages.
-   **git**: If `rg` and `fd` are unavailable, `git ls-files` is used as a fallback for finding files within a git repository.

## 📝 Usage

### Quick Start
1.  **Open Wiki**: Use `<leader>ww`, `<leader>wW`, or `<leader>wT` to start.
2.  **Create Note**: Select text (e.g., “My Project”), press `<CR>` to create `[My Project](./My_Project.md)` and open it.
3.  **Manage Tasks**: Use `<leader>wt` on a task line to toggle its status. Progress (e.g., `[ 75% ]`) will be displayed for parent items.
4.  **Navigate**: Use `<Tab>`/`<S-Tab>` to jump between links, `<BS>` to return to the `index.md`, or `<leader>wr` to rename a page and update its links.
5.  **Save**: Simply `:w`.

### Example Wiki Index
```markdown
# My Epic Wiki 🎉
- [Tasks](./Tasks.md) - Where productivity meets chaos!
- [Ideas](./Ideas.md) - Brainstorming central, no judgment zone.
- Next Big Thing
    - [ ] Release neowiki setup - Halfway to glory! [ 50% ]
      - [x] Crafted README - Checkmate!
      - [x] Snap screenshots - clack-clack-clack
      - [ ] Grand release - booking concert hall, Musikverein
      - [ ] Reach 1000 stars - designing a bot to help with that
```

### Nested Wiki Example
```markdown
# Work Wiki ⚡
- [Team Notes](./team/index.md) - The squad’s brain trust.
- [Project Plan](./plan.md) - Blueprint to world domination.
```


## ⌨️ Default Keybindings
The following keymaps are buffer-local and only active in markdown files within a configured wiki directory.

| Mode   | Key           | Action               | Description                               |
| ---    | ---           | ---                  | ---                                       |
| Normal | `<CR>`        | Follow link          | Open link under cursor                    |
| Visual | `<CR>`        | Create link          | Create link from selection                |
| Normal | `<S-CR>`      | Follow link (vsplit) | Open link in vertical split               |
| Visual | `<S-CR>`      | Create link (vsplit) | Create link, open in vertical split       |
| Normal | `<C-CR>`      | Follow link (split)  | Open link in horizontal split             |
| Visual | `<C-CR>`      | Create link (split)  | Create link, open in horizontal split     |
| Normal | `<Tab>`       | Next link            | Navigate to next link                     |
| Normal | `<S-Tab>`     | Previous link        | Navigate to previous link                 |
| Normal | `[[`          | Navigate back        | Go back in browsing history               |
| Normal | `]]`          | Navigate forward     | Go forward in browsing history            |
| Normal | `<Backspace>` | Jump to index        | Open the current wiki’s `index.md`        |
| Normal | `<leader>wt`  | Toggle task          | Create or toggle task status on the line  |
| Visual | `<leader>wt`  | Toggle tasks         | Bulk create or toggle tasks in selection  |
| Normal | `<leader>wd`  | Delete page          | Delete current or linked page             |
| Normal | `<leader>wr`  | Rename page          | Rename current or linked page             |
| Normal | `<leader>wi`  | Insert link          | Find and insert a link to a wiki page     |
| Normal | `<leader>wc`  | Clean broken links   | Remove broken links from the current page |
| Normal | `q`           | Close float          | Close the floating wiki window            |
## ⚙️ Default Configuration

Below is the default configuration for **neowiki.nvim**. You don’t need to copy all settings; just override the options you want to change in your `setup()` call.

```lua
require("neowiki").setup({
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
  index_file = "index.md",

  -- Automatically discover and register nested wiki roots.
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
    -- Navigate back and forth in history.
    navigate_back = "[[",
    navigate_forward = "]]",
    -- Jumps to the index page of the current wiki.
    jump_to_index = "<Backspace>",

    -- Renames the current wiki page and updates backlinks.
    rename_page = "<leader>wr",
    -- Deletes the current wiki page and updates backlinks.
    delete_page = "<leader>wd",
    -- Inserts a link to another wiki page.
    insert_link = "<leader>wi",
    -- Removes all links in the current file that point to non-existent pages.
    cleanup_links = "<leader>wc",

    -- Toggles the status of a gtd item.
    -- Works on the current line in Normal mode and on the selection in Visual mode.
    toggle_task = "<leader>wt",

    -- Closes the floating window.
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
    -- position, and border.
    open = {
      relative = "editor",
      width = 0.9,
      height = 0.9,
      border = "rounded",
    },

    -- Options for nvim_win_set_option(). Defines the style
    -- within the window after it's created.
    style = {},
  },
})
```

## 🔌 API

The following functions are exposed for use in custom mappings or scripts.

-   `neowiki.open_wiki({name})`  
    Opens a wiki's index page. It prompts to select a wiki if multiple are defined and no `{name}` is given.

-   `neowiki.open_wiki_new_tab({name})`  
    Same as `open_wiki()`, but opens in a new tab.

-   `neowiki.open_wiki_floating({name})`  
    Same as `open_wiki()`, but opens in a floating window.

### Custom Keymap Example
```lua
-- Open a specific wiki defined in wiki_dirs without a prompt
vim.keymap.set("n", "<leader>wk", function()
  require("neowiki").open_wiki("Work")
end, { desc = "Open Work Wiki" })
```

## 🤝 Contributing

- ⭐ **Star** it today and together we can make neowiki.nvim awesome
- 🐛 **Issues**: Report bugs at [GitHub Issues](https://github.com/echaya/neowiki.nvim/issues)
- 💡 **PRs**: Features or fixes are welcome
- 📣 **Feedback**: Share ideas in [GitHub Discussions](https://github.com/echaya/neowiki.nvim/discussions)


## 🙏 Thanks

Big thanks to **kiwi.nvim** by [serenevoid](https://github.com/serenevoid/kiwi.nvim) for inspiring **neowiki.nvim**’s lean approach. Shoutout to the Neovim community for fueling this project! 📝


## 📜 License

[MIT License](./LICENSE)
