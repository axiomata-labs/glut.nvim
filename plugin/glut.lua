-- The commands; no keys — they are the owner's to map.
if vim.g.loaded_glut then
  return
end
vim.g.loaded_glut = true

vim.api.nvim_create_user_command("Glut", function()
  require("glut").toggle()
end, { desc = "Glut in a split: open, show or hide" })

vim.api.nvim_create_user_command("GlutSend", function(command)
  require("glut").send(command.line1, command.line2)
end, { range = true, desc = "The selected lines as a reference in Glut's input" })

vim.api.nvim_create_user_command("GlutAdd", function()
  require("glut").add()
end, { desc = "The current file as a reference in Glut's input" })

vim.api.nvim_create_user_command("GlutDiffAccept", function()
  require("glut.diff").accept()
end, { desc = "Accept Glut's change shown in this tab" })

vim.api.nvim_create_user_command("GlutDiffDeny", function()
  require("glut.diff").deny()
end, { desc = "Refuse Glut's change shown in this tab" })
