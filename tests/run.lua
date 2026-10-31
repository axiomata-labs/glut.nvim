-- The plugin as Glut meets it: run with
--   HOME=$(mktemp -d) nvim --headless -u NONE -l tests/run.lua
-- Each test talks to the server with curl, as Glut's MCP client would.

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
vim.cmd("runtime plugin/glut.lua")

local failed = 0
local function check(ok, what)
  if ok then
    print("ok   " .. what)
  else
    failed = failed + 1
    print("FAIL " .. what)
  end
end

local folder = vim.fn.tempname()
vim.fn.mkdir(folder, "p")
vim.cmd("cd " .. folder)
local file = folder .. "/a.lua"
vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, file)
vim.cmd("edit " .. file)

local glut = require("glut")
glut.setup()
local state = glut._state
local lock = vim.json.decode(table.concat(vim.fn.readfile(state.lockfile), "\n"))
local mode = vim.uv.fs_stat(state.lockfile).mode % 512
check(mode == tonumber("600", 8), "the file Glut finds the editor by is the owner's alone")
check(lock.port == state.port and #lock.authToken == 32 and lock.workspaceFolders[1] == vim.fn.getcwd(),
  "it names the port, a fresh token and the folder")

local function post(body, token, wait)
  local args = { "curl", "-s", "-o", "-", "-w", "\n%{http_code}", "-X", "POST",
    ("http://127.0.0.1:%d/mcp"):format(state.port), "-H", "Content-Type: application/json", "-d", vim.json.encode(body) }
  if token then
    table.insert(args, "-H")
    table.insert(args, "Authorization: Bearer " .. token)
  end
  -- Waited for with the event loop running: the server answers from Neovim's main loop.
  local result
  vim.system(args, { text = true }, function(done)
    result = done
  end)
  local job = {
    wait = function(_, limit)
      vim.wait(limit or 5000, function()
        return result ~= nil
      end, 10)
      return result or { stdout = "" }
    end,
  }
  if wait == false then
    return job
  end
  local done = job:wait(5000)
  local out, code = (done.stdout or ""):match("^(.*)\n(%d+)$")
  return tonumber(code), out
end

local function call(name, arguments)
  local code, out = post({ jsonrpc = "2.0", id = 1, method = "tools/call",
    params = { name = name, arguments = arguments or vim.empty_dict() } }, lock.authToken)
  if code ~= 200 then
    return nil
  end
  local result = vim.json.decode(out).result
  return vim.json.decode(result.content[1].text)
end

check(post({ jsonrpc = "2.0", id = 1, method = "initialize" }) == 401, "a request without the token is refused")
check(post({ jsonrpc = "2.0", id = 1, method = "initialize" }, string.rep("0", 32)) == 401,
  "a request with another token is refused")
local code, out = post({ jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18" } },
  lock.authToken)
check(code == 200 and vim.json.decode(out).result.serverInfo.name == "Neovim", "Glut's handshake is answered")
local _, listed = post({ jsonrpc = "2.0", id = 2, method = "tools/list" }, lock.authToken)
local names = vim.tbl_map(function(tool)
  return tool.name
end, vim.json.decode(listed).result.tools)
check(vim.deep_equal(names, { "openFiles", "diagnostics" }), "its model is shown two tools alone")

-- A selection made and left, as the owner does before they ask Glut.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! Vj\27")
vim.wait(200, function()
  return false
end)
local context = call("getContext")
check(context and context.activeFile.path == vim.uv.fs_realpath(file) and context.activeFile.selection ~= vim.NIL
  and context.activeFile.selection.text == "local a = 1\nlocal b = 2", "the active file and its selection are said")

vim.api.nvim_buf_set_lines(0, 2, 3, false, { "return a * b -- unsaved" })
local read = call("readBuffer", { path = file })
check(read and read.loaded and read.dirty and read.text:find("unsaved", 1, true), "a buffer is read as Neovim holds it")
local unloaded = call("readBuffer", { path = folder .. "/nowhere.lua" })
check(unloaded and unloaded.loaded == false and vim.fn.bufnr(folder .. "/nowhere.lua") == -1,
  "a path no buffer holds is not opened for Glut")

local files = call("openFiles")
check(files and #files.files == 1 and files.files[1].active and files.files[1].dirty, "the open files are listed")

-- A diff answered in Neovim.
local job = post({ jsonrpc = "2.0", id = 3, method = "tools/call", params = { name = "openDiff",
  arguments = { id = "ask-1", path = file, oldText = "local a = 1\n", newText = "local a = 10\n", title = "a.lua" } } },
  lock.authToken, false)
check(vim.wait(3000, function()
  return #vim.api.nvim_list_tabpages() == 2
end), "Glut's change shows as a diff in a tab of its own")
check(vim.api.nvim_tabpage_get_number(vim.api.nvim_get_current_tabpage()) == 1,
  "the diff does not take the focus")
vim.cmd("tabnext 2")
vim.cmd("GlutDiffAccept")
local done = job:wait(3000)
check(done.stdout:find('\\"accepted\\"', 1, true) ~= nil and #vim.api.nvim_list_tabpages() == 1,
  "accepting answers Glut and closes the tab")

local refused = post({ jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "openDiff",
  arguments = { id = "ask-2", path = file, oldText = vim.NIL, newText = "new\n", title = "new" } } },
  lock.authToken, false)
vim.wait(3000, function()
  return #vim.api.nvim_list_tabpages() == 2
end)
check(call("closeDiff", { id = "ask-2" }).closed, "Glut closes a diff its own card answered")
check(refused:wait(3000).stdout:find('\\"closed\\"', 1, true) ~= nil, "and the diff's question answers closed")

-- What a stranger on the port may send: a head no number can be read from, chunks, a body without the token.
local function raw(bytes)
  local result
  vim.system({ "curl", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", "--data-binary", "@-",
    "-H", bytes, ("http://127.0.0.1:%d/mcp"):format(state.port) }, { stdin = "{}", text = true }, function(done)
    result = done
  end)
  vim.wait(4000, function()
    return result ~= nil
  end, 10)
  return result and result.stdout
end
check(raw("Content-Length: nan") == "400", "a length that is no number is refused, and Neovim goes on")
check(raw("Transfer-Encoding: chunked") == "400", "a chunked body is refused")
local alive = call("openFiles")
check(alive ~= nil, "Neovim still answers Glut after them")
-- A buffer whose name merely contains the one asked for is not it.
vim.fn.writefile({ "SECRET=1" }, folder .. "/.env.local")
vim.cmd("badd " .. folder .. "/.env.local")
vim.fn.bufload(vim.fn.bufnr(folder .. "/.env.local"))
local env = call("readBuffer", { path = folder .. "/.env" })
check(env and env.loaded == false, "asking for .env never reads .env.local")

glut.stop()
check(vim.uv.fs_stat(lock and state.lockfile or "") == nil, "the file goes when the editor stops")

if failed > 0 then
  print(failed .. " failed")
  os.exit(1)
end
print("all passed")
os.exit(0)
