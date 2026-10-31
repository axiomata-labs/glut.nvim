-- :checkhealth glut
local M = {}

function M.check()
  vim.health.start("glut.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11 or later is needed")
  end
  if vim.fn.executable("glut") == 1 then
    vim.health.ok("`glut` is on the PATH")
  else
    vim.health.warn("`glut` is not on the PATH: :Glut cannot start it (Glut started elsewhere still connects)")
  end
  local state = require("glut")._state
  if state.port then
    vim.health.ok(("listening for Glut on 127.0.0.1:%d, %s"):format(state.port, state.lockfile))
  else
    vim.health.warn("not listening: call require('glut').setup()")
  end
end

return M
