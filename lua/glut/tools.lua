-- The protocol's tools: what Glut may ask of the editor (docs/editor-protocol.md
-- in Glut). `openFiles` and `diagnostics` are listed for its model; the rest
-- Glut calls itself.

local context = require("glut.context")
local diff = require("glut.diff")

local M = {}

local function text(value)
  return { content = { { type = "text", text = vim.json.encode(value) } } }
end

local function refusal(why)
  return { isError = true, content = { { type = "text", text = why } } }
end

--- A path as the disk names it: links resolved where the file is there.
local function real(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- The loaded buffer of exactly `path`, never one made for it and never one whose name merely contains it
--- (`bufnr()` would match `.env.local` for `.env`): the editor opens no path for Glut.
local function loaded(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local wanted = real(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and context.is_file(buf)
      and real(vim.api.nvim_buf_get_name(buf)) == wanted then
      return buf
    end
  end
end

local severities = { "error", "warning", "info", "hint" }

local handlers = {
  openFiles = function(_, respond)
    local active = context.buffer()
    local files = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and context.is_file(buf) then
        local file = {
          path = vim.api.nvim_buf_get_name(buf),
          active = buf == active,
          dirty = vim.bo[buf].modified,
        }
        table.insert(files, buf == active and 1 or #files + 1, file)
      end
    end
    respond(text({ files = files }))
  end,
  diagnostics = function(args, respond)
    local buf = loaded(args.path)
    if not buf then
      return respond(text({ diagnostics = {} }))
    end
    local found = {}
    for _, item in ipairs(vim.diagnostic.get(buf)) do
      table.insert(found, {
        line = item.lnum + 1,
        character = item.col + 1,
        severity = severities[item.severity] or "info",
        message = item.message,
        source = item.source,
      })
    end
    respond(text({ path = vim.api.nvim_buf_get_name(buf), diagnostics = found }))
  end,
  getContext = function(_, respond)
    respond(text(context.get()))
  end,
  readBuffer = function(args, respond)
    local buf = loaded(args.path)
    if not buf then
      return respond(text({ loaded = false }))
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(lines, "\n")
    if vim.bo[buf].eol and #lines > 0 then
      body = body .. "\n"
    end
    respond(text({ loaded = true, path = vim.api.nvim_buf_get_name(buf), text = body, dirty = vim.bo[buf].modified }))
  end,
  openDiff = function(args, respond, connection)
    diff.open(args, respond, connection)
  end,
  closeDiff = function(args, respond)
    respond(text({ closed = diff.close(args.id) }))
  end,
  notify = function(args, respond)
    if type(args.message) == "string" then
      -- Glut's words, shown as words: no control character acts in Neovim's message area.
      -- Bytes below 32 and DEL only, never a part of a character beyond ASCII; cut by characters, not bytes.
      local message = vim.fn.strcharpart(args.message:gsub("[%z\1-\31\127]", " "), 0, 300)
      vim.notify("glut: " .. message)
    end
    respond(text({}))
  end,
  changed = function(args, respond)
    for _, path in ipairs(type(args.paths) == "table" and args.paths or {}) do
      local buf = loaded(path)
      -- A buffer with unsaved changes keeps them: Neovim asks the owner when they write it. Read again in place,
      -- never through a prompt that would stop Neovim.
      if buf and not vim.bo[buf].modified then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent! edit")
        end)
      end
    end
    respond(text({}))
  end,
}

--- What `tools/list` shows Glut's model.
local listed = {
  {
    name = "openFiles",
    description = "The files open in the owner's editor, the active first.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
  },
  {
    name = "diagnostics",
    description = "A file's diagnostics, as the editor's language servers see its buffer.",
    inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
  },
}

--- Answers one JSON-RPC message of Glut's.
function M.handle(message, respond, version, connection)
  local method = message.method
  if method == "initialize" then
    return respond({
      protocolVersion = (message.params or {}).protocolVersion or "2025-06-18",
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = "Neovim", version = version },
    })
  elseif method == "tools/list" then
    return respond({ tools = listed })
  elseif method == "tools/call" then
    local params = message.params or {}
    local handler = handlers[params.name]
    if not handler then
      return respond(refusal("no tool " .. tostring(params.name)))
    end
    local arguments = type(params.arguments) == "table" and params.arguments or {}
    return handler(arguments, respond, connection)
  elseif method == "ping" then
    return respond(vim.empty_dict())
  end
  respond(nil, "no method " .. tostring(method))
end

return M
