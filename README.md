# glut.nvim

Glut beside Neovim. Glut — a terminal coding agent with its own sandbox, gate and sessions — runs in a split (or in any
terminal in the same folder), and this plugin tells it what you work on:

- **The file, the cursor and the selection** go with each of your messages to Glut (it shows "⧉ 12 lines of
  src/main.rs" under them), as long as none of Glut's read rules holds the file back.
- **Your buffers as Neovim holds them**: Glut reads a loaded buffer, unsaved changes too. It never changes a buffer
  with unsaved changes — save it first.
- **Glut's questions about edits as Neovim diffs**: where Glut's gate asks before an edit, the change opens in a tab of
  its own, the file on the left, Glut's change on the right. `:GlutDiffAccept` or `:GlutDiffDeny` answers; Glut's own
  card in its terminal answers too, and the first answer counts. Accepting writes nothing here: Glut writes the file
  once its gate allows it, and Neovim reads it again.
- **What is open and what your language servers say**, for Glut's model to ask.

The protocol is Glut's own, in Glut's repository: `docs/editor-protocol.md`.

## Requirements

- Neovim 0.11 or later
- `glut` on the `PATH`

## Install (lazy.nvim)

```lua
{
  "NamorX68/glut.nvim",
  config = function()
    require("glut").setup()
  end,
}
```

`setup()` starts listening at once (on 127.0.0.1 only, behind a fresh random token in `~/.glut/ide/<port>.json`,
readable by you alone), so a Glut started in another terminal in the same folder finds Neovim too.

## Commands

The plugin maps no keys; map the commands the way you like.

| Command | What it does |
|---|---|
| `:Glut` | Glut in a split on the right (40 %): opens it, or shows and hides the one there is |
| `:GlutSend` | the selected lines as `@path#L10-22` in Glut's input — write your question and send it |
| `:GlutAdd` | the current file as `@path` in Glut's input |
| `:GlutDiffAccept` | accept Glut's change shown in this tab |
| `:GlutDiffDeny` | refuse it |

For example:

```lua
vim.keymap.set("n", "<leader>Gc", "<cmd>Glut<cr>", { desc = "Glut" })
vim.keymap.set("v", "<leader>Gs", ":GlutSend<cr>", { desc = "Send selection to Glut" })
vim.keymap.set("n", "<leader>Gb", "<cmd>GlutAdd<cr>", { desc = "Add file to Glut" })
vim.keymap.set("n", "<leader>Ga", "<cmd>GlutDiffAccept<cr>", { desc = "Accept Glut's change" })
vim.keymap.set("n", "<leader>Gd", "<cmd>GlutDiffDeny<cr>", { desc = "Refuse Glut's change" })
```

## Options

```lua
require("glut").setup({
  cmd = { "glut" },                         -- what :Glut starts
  split = { side = "right", width = 0.40 }, -- where and how wide
})
```

In Glut, `/ide` shows the connection, `/ide off` lets it go for the session, `/ide on` connects again.
`:checkhealth glut` says whether Neovim is listening.

## Tests

```sh
HOME=$(mktemp -d) nvim --headless -u NONE -l tests/run.lua
```

## License

MIT OR Apache-2.0, as Glut.
