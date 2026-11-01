-- Glut's question about an edit as Neovim's own diff: the file as it is on the
-- left, Glut's change on the right, in a tab of their own. :GlutDiffAccept or
-- :GlutDiffDeny answers it; closing the tab answers nothing ("closed"). Accepting
-- writes nothing: Glut writes the file once its gate allows it. The right side
-- may be changed first: accepting then hands Glut that text, which it writes
-- instead and tells its model about. The tab opens
-- behind the one the owner is in — a diff never takes the focus, so no key meant
-- for something else lands in it — and the owner is told it is there.

local M = {}

--- The diffs waiting for the owner, by id: their tab and how to answer Glut.
local open = {}

local function scratch(name, text, filetype, editable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, name)
  local lines = vim.split(text or "", "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = editable or false
  vim.bo[buf].modified = false
  -- Highlighting alone: a filetype would run the owner's ftplugins and language servers on Glut's text.
  vim.bo[buf].syntax = filetype or ""
  return buf
end

--- The right side's text, where the owner changed it; `nil` where it is still Glut's.
local function owners_text(diff)
  if not vim.api.nvim_buf_is_valid(diff.right) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(diff.right, 0, -1, false)
  local body = table.concat(lines, "\n")
  -- The buffer holds lines: a file of text ends with a line break, as Glut's did or as a new one should — an emptied
  -- buffer is an empty file.
  local empty = #lines == 1 and lines[1] == ""
  if not empty and (diff.new_text:sub(-1) == "\n" or diff.new_text == "") then
    body = body .. "\n"
  end
  if empty then
    body = ""
  end
  if body ~= diff.new_text then
    return body
  end
end

local function settle(id, outcome)
  local diff = open[id]
  if not diff then
    return
  end
  open[id] = nil
  local answer = { outcome = outcome }
  if outcome == "accepted" then
    answer.text = owners_text(diff)
  end
  pcall(diff.respond, { content = { { type = "text", text = vim.json.encode(answer) } } })
  if vim.api.nvim_tabpage_is_valid(diff.tab) and #vim.api.nvim_list_tabpages() > 1 then
    local number = vim.api.nvim_tabpage_get_number(diff.tab)
    pcall(vim.cmd, "tabclose " .. number)
  end
end

--- Shows the diff `id` and answers through `respond` once the owner decided; `connection` is the one that asked,
--- whose end closes it.
function M.open(args, respond, connection)
  local id = tostring(args.id or "")
  if id == "" or type(args.path) ~= "string" or type(args.newText) ~= "string" then
    return respond(nil, "openDiff needs id, path and newText")
  end
  if open[id] then
    settle(id, "closed")
  end
  local filetype = vim.filetype.match({ filename = args.path }) or ""
  local short = vim.fn.fnamemodify(args.path, ":~:."):gsub("[%c]", " ")
  local old = type(args.oldText) == "string" and args.oldText or ""
  local before_tab, before_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode
  vim.cmd("noautocmd tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local left = scratch("glut://" .. id .. "/before/" .. short, old, filetype)
  vim.api.nvim_win_set_buf(0, left)
  vim.cmd("diffthis")
  vim.cmd("noautocmd vsplit")
  -- A rename's files take no text of the owner's: it replaces the old name or nothing.
  local editable = args.editable ~= false
  local right = scratch("glut://" .. id .. "/glut/" .. short, args.newText, filetype, editable)
  vim.api.nvim_win_set_buf(0, right)
  vim.cmd("diffthis")
  local title = (type(args.title) == "string" and args.title ~= "") and args.title:gsub("[%c]", " ") or short
  local hint = editable and "  ·  change this side if you like" or ""
  vim.wo.winbar = ("Glut: %s%s  ·  :GlutDiffAccept  ·  :GlutDiffDeny"):format(title:gsub("%%", "%%%%"), hint)
  -- Back where the owner was, as they were.
  vim.cmd("noautocmd tabnext " .. vim.api.nvim_tabpage_get_number(before_tab))
  if vim.api.nvim_win_is_valid(before_win) then
    vim.api.nvim_set_current_win(before_win)
  end
  if mode:sub(1, 1) == "t" then
    vim.cmd("startinsert")
  end
  vim.notify(("glut: Glut asks about a change of %s — in tab %d"):format(short, vim.api.nvim_tabpage_get_number(tab)))
  local diff = {
    tab = tab,
    buffers = { left, right },
    right = right,
    new_text = args.newText,
    respond = respond,
    connection = connection,
  }
  open[id] = diff
  -- A diff whose tab went, or whose buffers did, was closed without an answer — this diff, not one that took its id.
  for _, buf in ipairs({ left, right }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(function()
          if open[id] == diff then
            settle(id, "closed")
          end
        end)
      end,
    })
  end
end

--- Closes the diffs connection `connection` asked for: it ended, nobody waits for their answer.
function M.ended(connection)
  for id, diff in pairs(open) do
    if diff.connection == connection then
      settle(id, "closed")
    end
  end
end

--- The diff shown in the current tab, if any.
local function current()
  local tab = vim.api.nvim_get_current_tabpage()
  for id, diff in pairs(open) do
    if diff.tab == tab then
      return id
    end
  end
end

function M.accept()
  local id = current()
  if id then
    settle(id, "accepted")
  else
    vim.notify("glut: no diff of Glut's in this tab", vim.log.levels.WARN)
  end
end

function M.deny()
  local id = current()
  if id then
    settle(id, "rejected")
  else
    vim.notify("glut: no diff of Glut's in this tab", vim.log.levels.WARN)
  end
end

--- Closes the diff `id`: Glut's own card answered first.
function M.close(id)
  local had = open[tostring(id)] ~= nil
  settle(tostring(id), "closed")
  return had
end

--- Closes every diff: Neovim leaves, or Glut went.
function M.close_all()
  for id in pairs(open) do
    settle(id, "closed")
  end
end

return M
