-- Where the owner works: the last window that showed a file (not Glut's own
-- terminal, which has the focus while they type to Glut), its cursor, and the
-- selection they made last in it.

local M = {}

--- The largest selection handed over, in bytes: the protocol's 16 KB.
local MOST_SELECTED = 16 * 1024

local state = { win = nil, selection = nil }

--- Whether `buf` holds a file on disk (not a terminal, a scratch or a diff of Glut's).
function M.is_file(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and not name:match("^%a+://")
end

local function visual(mode)
  return mode == "v" or mode == "V" or mode == "\22"
end

--- The Visual mode just left: characters, lines or a block.
local last_mode = nil

--- The selection just left in the current window, by its marks.
local function capture()
  local buf = vim.api.nvim_get_current_buf()
  if not M.is_file(buf) then
    return
  end
  local start = vim.api.nvim_buf_get_mark(buf, "<")
  local finish = vim.api.nvim_buf_get_mark(buf, ">")
  if start[1] == 0 or finish[1] == 0 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, start[1] - 1, finish[1], false)
  local whole = table.concat(lines, "\n")
  -- A selection of characters is those characters; of lines, the lines.
  if last_mode == "v" and #lines > 0 then
    lines[#lines] = lines[#lines]:sub(1, finish[2] + 1)
    lines[1] = lines[1]:sub(start[2] + 1)
    whole = table.concat(lines, "\n")
  end
  -- Cut on a character, never inside one.
  local text = whole
  if #text > MOST_SELECTED then
    text = vim.fn.strcharpart(text, 0, MOST_SELECTED)
    while #text > MOST_SELECTED do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
  end
  -- A selection of whole lines ends past every column: at its last line's end.
  local last = lines[#lines] or ""
  state.selection = {
    buf = buf,
    start = { line = start[1], character = start[2] + 1 },
    ["end"] = { line = finish[1], character = math.min(finish[2], #last) + 1 },
    text = text,
  }
end

function M.setup(group)
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      if M.is_file(vim.api.nvim_get_current_buf()) then
        state.win = vim.api.nvim_get_current_win()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      local old, new = vim.v.event.old_mode, vim.v.event.new_mode
      if visual(old) and not visual(new) then
        last_mode = old
        -- The marks are set once Visual mode is left.
        vim.schedule(capture)
      end
    end,
  })
  -- A move in Normal mode in the file lets the selection go: it was not what the owner works on any more.
  -- An edit of the buffer makes the selection's text stale: it goes.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function()
      if state.selection and state.selection.buf == vim.api.nvim_get_current_buf() then
        state.selection = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      local selection = state.selection
      if selection and selection.buf == vim.api.nvim_get_current_buf()
        and not visual(vim.api.nvim_get_mode().mode) then
        local line = vim.api.nvim_win_get_cursor(0)[1]
        if line < selection.start.line or line > selection["end"].line then
          state.selection = nil
        end
      end
    end,
  })
  if M.is_file(vim.api.nvim_get_current_buf()) then
    state.win = vim.api.nvim_get_current_win()
  end
end

--- The active file, its cursor and its selection, as `getContext` answers.
function M.get()
  local win = state.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return { activeFile = vim.NIL }
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.is_file(buf) then
    return { activeFile = vim.NIL }
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local selection = state.selection
  local selected = vim.NIL
  if selection and selection.buf == buf then
    selected = { start = selection.start, ["end"] = selection["end"], text = selection.text }
  end
  return {
    activeFile = {
      path = vim.api.nvim_buf_get_name(buf),
      cursor = { line = cursor[1], character = cursor[2] + 1 },
      selection = selected,
    },
  }
end

--- The buffer the owner works in, if any.
function M.buffer()
  local win = state.win
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_buf(win)
  end
end

return M
