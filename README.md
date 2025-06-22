[![Neovim](https://img.shields.io/badge/Built_for-Neovim-57A143?style=for-the-badge&logo=neovim)](https://neovim.io/)
[![Lua](https://img.shields.io/badge/Made_with-Lua-blueviolet.svg?style=for-the-badge)](https://www.lua.org)
[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](./LICENSE)

# neowiki.nvim

**Modern Vimwiki Successor for Instant Notes & GTD** 🚀📝

-----

## 🌟 Introduction

**neowiki.nvim** is a lightweight, first-class Neovim citizen with Lua finesse, offering a minimal, intuitive workflow out of the box for note-taking and GTD.


## 🔥 Key Features

* Flexible Wiki Opening 🪟  
Open wikis your way —  in the current buffer, a new tab, or a sleek floating window for distraction-free note-taking

- **Seamless Linking & Navigation** 🔗  
Create and track markdown links with `<CR>`, split with `<S-CR>` or `<C-CR>`. Navigate smoothly with `<Tab>`/`<S-Tab>` and `<BS>`

- **Smart GTD** ✅  
Toggle tasks with <leader>wt ([ ] to [x]), see nested progress updated in real-time

- **Multi-Wiki & Nested Support** 📂  
Manage multiple wikis (e.g., work, personal) and nested index.md with ease

- **Wiki Management** 🛠️  
Delete pages with <leader>wd and clean broken links with built-in tools

- **Neovim Native** ⚙️  
Harness Neovim 0.10+ with Lua speed, integrating seamlessly with Treesitter, markdown rendering, completion, pickers, and your setup out of the box

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
      -- neowiki.nvim supports both absolute and relative paths
      { name = "Work", path = "~/work/wiki" },
      { name = "Personal", path = "personal/wiki" },
    },
  },
  keys = {
    { "<leader>ww", "<cmd>lua require('neowiki').open_wiki()<cr>", desc = "Open Wiki" },
    { "<leader>wW", "<cmd>lua require('neowiki').open_wiki_floating()<cr>", desc = "Open Floating Wiki" },
    { "<leader>wT", "<cmd>lua require('neowiki').open_wiki_new_tab()<cr>", desc = "Open Wiki in Tab" },
  },
}
```

### Using Mini.deps
```lua
require("mini.deps").add("echaya/neowiki.nvim")
require("neowiki").setup()
vim.keymap.set("n", "<leader>ww", require("neowiki").open_wiki, { desc = "Open Wiki" })
vim.keymap.set( "n", "<leader>wW", require("neowiki").open_wiki_floating, { desc = "Open Floating Wiki" })
vim.keymap.set( "n", "<leader>wT", require("neowiki").open_wiki_new_tab, { desc = "Open Wiki in Tab" })
```

### Using Vim-Plug
```vim
Plug 'echaya/neowiki.nvim'
lua require('neowiki').setup()
lua vim.keymap.set("n", "<leader>ww", require("neowiki").open_wiki, { desc = "Open Wiki" })
lua vim.keymap.set( "n", "<leader>wW", require("neowiki").open_wiki_floating, { desc = "Open Floating Wiki" })
lua vim.keymap.set( "n", "<leader>wT", require("neowiki").open_wiki_new_tab, { desc = "Open Wiki in Tab" })
```

### Custom Keymap
```lua
-- open a specific wiki defined in wiki_dirs
vim.keymap.set("n", "<leader>wk", function()
  require("neowiki").open_wiki("Work")
end, { desc = "Open Work Wiki" })
```


## 📝 Usage

### Quick Start
1. **Open Wiki**: Use `<leader>ww`, `<loeader>wW` or `<leader>wT` to start.
2. **Create Note**: Select text (e.g., “My Project”), press `<CR>` to create `[My Project](./My_Project.md)` and open it.
3. **Manage Tasks**: Use `<leader>wt` to toggle tasks. Progress (e.g., `[ 75% ]`) will be displayed for nested tasks
4. **Navigate**: Use `<Tab>`/`<S-Tab>` for links, `<BS>` for the index, or `<leader>wc` to clean broken links.
5. **Save**: Simply `:w`.

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


| Mode   | Key           | Action               | Description                                 |
|--------|---------------|----------------------|---------------------------------------------|
| Normal | `<CR>`        | Follow link          | Open link under cursor                      |
| Visual | `<CR>`        | Create link          | Link selected text                          |
| Normal | `<S-CR>`      | Follow link (vsplit) | Open link in vertical split                 |
| Visual | `<S-CR>`      | Create link (vsplit) | Create link, open in vertical split         |
| Normal | `<C-CR>`      | Follow link (split)  | Open link in horizontal split               |
| Visual | `<C-CR>`      | Create link (split)  | Create link, open in horizontal split       |
| Normal | `<Tab>`       | Next link            | Navigate to next link                       |
| Normal | `<S-Tab>`     | Previous link        | Navigate to previous link                   |
| Normal | `<Backspace>` | Jump to index        | Open wiki’s `index.md`                      |
| Normal | `<leader>wd`  | Delete page          | Delete current wiki page                    |
| Normal | `<leader>wc`  | Clean broken links   | Remove broken links from page               |
| Normal | `<leader>wt`  | Toggle task          | Open and toggle task status (`[ ]` ↔ `[x]`) |
| Visual | `<leader>wt`  | Toggle tasks         | Bulk toggle tasks in selection              |


## ⚙️ Default Configuration

Below is the default configuration for **neowiki.nvim**. You don’t need to copy all settings into `setup()`. Only override the options you want to change.

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

  -- Defines the keymaps used by neowiki.
  -- Setting a keymap to `false` or an empty string will disable it.

  keymaps = {
    -- In Normal mode, follows the link under the cursor.
    -- In Visual mode, creates a link from the selection.
    action_link = "<CR>",
    action_link_vsplit = "<S-CR>",
    action_link_split = "<C-CR>",
    -- Toggles the status of a gtd item.
    -- Works on the current line in Normal mode and on the selection in Visual mode.
    toggle_task = "<leader>wt",
    -- Jumps to the next link in the buffer.
    next_link = "<Tab>",
    -- Jumps to the previous link in the buffer.
    prev_link = "<S-Tab>",
    -- Jumps to the index page of the current wiki.
    jump_to_index = "<Backspace>",
    -- Deletes the current wiki page.
    delete_page = "<leader>wd",
    -- Removes all links in the current file that point to non-existent pages.
    cleanup_links = "<leader>wc",
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
      width = 0.85,
      height = 0.85,
      border = "rounded",
    },

    -- Options for nvim_win_set_option(). Defines the style
    -- within the window after it's created.
    style = {},
  },

})
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
