-- glut.nvim: Glut beside Neovim. The plugin listens on loopback for Glut
-- (docs/editor-protocol.md in Glut), tells it the file, the cursor and the
-- selection you work on, hands it your buffers as Neovim holds them, and shows
-- its questions about edits as Neovim's own diffs. Glut itself runs in a
-- terminal split (:Glut) or anywhere else in this folder.

local M = {}

M.version = "0.1.0"

local defaults = {
  --- The program to start in the split.
  cmd = { "glut" },
  --- The split: its side and its share of the width.
  split = { side = "right", width = 0.40 },
}

local state = { port = nil, stop = nil, lockfile = nil, job = nil, buf = nil, win = nil }

M.options = vim.deepcopy(defaults)

--- The folders this editor works in: the current one, as Neovim's cwd says.
local function folders()
  return { vim.fn.getcwd() }
end

--- Starts listening for Glut, once.
function M.listen()
  if state.port then
    return state.port
  end
  local lockfile = require("glut.lockfile")
  local token = lockfile.token()
  local tools = require("glut.tools")
  lockfile.sweep()
  local port, stop = require("glut.server").start(token, function(message, respond, connection)
    tools.handle(message, respond, M.version, connection)
  end, function(connection)
    require("glut.diff").ended(connection)
  end)
  state.port, state.stop, state.token = port, stop, token
  state.lockfile = lockfile.write(port, token, folders())
  return port
end

--- Stops listening and takes the file away.
function M.stop()
  require("glut.diff").close_all()
  if state.stop then
    state.stop()
  end
  require("glut.lockfile").remove(state.lockfile)
  state.port, state.stop, state.lockfile, state.token = nil, nil, nil, nil
end

--- The terminal Glut runs in, if it still does.
local function running()
  return state.job and vim.fn.jobwait({ state.job }, 0)[1] == -1
end

--- Opens Glut in a split, or shows and hides the one there is.
function M.toggle()
  local port = M.listen()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_hide(state.win)
    state.win = nil
    return
  end
  local width = math.floor(vim.o.columns * M.options.split.width)
  local side = M.options.split.side == "left" and "topleft" or "botright"
  vim.cmd(("%s vertical %dsplit"):format(side, width))
  state.win = vim.api.nvim_get_current_win()
  if running() and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_win_set_buf(state.win, state.buf)
  else
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.win, state.buf)
    state.job = vim.fn.jobstart(M.options.cmd, {
      term = true,
      env = { GLUT_IDE_PORT = tostring(port) },
      on_exit = function()
        state.job = nil
      end,
    })
  end
  vim.cmd("startinsert")
end

--- Puts `text` into Glut's input, unsent, and goes there — as a paste, never as keys: a key could answer a question
--- of Glut's that stands open.
local function type_into_glut(text, tries)
  tries = tries or 0
  if not running() then
    if tries >= 5 then
      return vim.notify("glut: Glut did not start", vim.log.levels.WARN)
    end
    if tries == 0 then
      M.toggle()
    end
    -- Glut needs a moment to draw its input; what is pasted before it would be lost.
    vim.defer_fn(function()
      type_into_glut(text, tries + 1)
    end, 800)
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.toggle()
  end
  vim.fn.chansend(state.job, "\27[200~" .. text .. "\27[201~")
  vim.api.nvim_set_current_win(state.win)
  vim.cmd("startinsert")
end

--- The current file as Glut names it — relative below its folder — or `nil` for a name a reference cannot carry
--- (a space, a control character: it would end the reference or act as a key).
local function relative(buf)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  if name:find("[%c%s]") then
    vim.notify("glut: this file's name cannot go into a reference", vim.log.levels.WARN)
    return nil
  end
  return name
end

--- :GlutSend — the lines of a range as a reference in Glut's input.
function M.send(first, last)
  local buf = vim.api.nvim_get_current_buf()
  if not require("glut.context").is_file(buf) then
    return vim.notify("glut: not a file", vim.log.levels.WARN)
  end
  local name = relative(buf)
  if not name then
    return
  end
  local reference = first == last and ("@%s#L%d "):format(name, first) or ("@%s#L%d-%d "):format(name, first, last)
  type_into_glut(reference)
end

--- :GlutAdd — the current file as a reference in Glut's input.
function M.add()
  local buf = vim.api.nvim_get_current_buf()
  if not require("glut.context").is_file(buf) then
    return vim.notify("glut: not a file", vim.log.levels.WARN)
  end
  local name = relative(buf)
  if name then
    type_into_glut(("@%s "):format(name))
  end
end

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  local group = vim.api.nvim_create_augroup("glut", { clear = true })
  require("glut.context").setup(group)
  M.listen()
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.stop })
  -- The folder Glut finds this editor by follows Neovim's: the same port and token, the file written anew.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      if state.port then
        state.lockfile = require("glut.lockfile").write(state.port, state.token, folders())
      end
    end,
  })
end

M._state = state

return M
