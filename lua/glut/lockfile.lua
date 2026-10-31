-- The file Glut finds this editor by: ~/.glut/ide/<port>.json with the port,
-- the folders and a fresh token — the folder 0700, the file 0600, written
-- under another name and renamed into place, removed when Neovim leaves. A
-- file an editor left behind when it ended without leaving is swept at start.

local uv = vim.uv

local M = {}

--- The folder the editors leave their files in.
function M.dir()
  return vim.fs.joinpath(uv.os_homedir(), ".glut", "ide")
end

--- A token from the system's random source: 16 bytes as 32 hex characters.
function M.token()
  local bytes = assert(uv.random(16))
  return (bytes:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

--- Removes the files of editors whose process is gone.
function M.sweep()
  local dir = M.dir()
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("^%d+%.json$") then
      local path = vim.fs.joinpath(dir, name)
      local ok, info = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      end)
      local pid = ok and type(info) == "table" and tonumber(info.pid)
      if not pid or not pcall(uv.kill, pid, 0) or uv.kill(pid, 0) ~= 0 then
        uv.fs_unlink(path)
      end
    end
  end
end

--- Writes the file for `port`; returns its path.
function M.write(port, token, folders)
  local dir = M.dir()
  vim.fn.mkdir(dir, "p", tonumber("700", 8))
  -- An existing folder keeps its mode: closed to everyone else, or Glut does not read it.
  uv.fs_chmod(dir, tonumber("700", 8))
  local path = vim.fs.joinpath(dir, port .. ".json")
  local temporary = path .. ".tmp"
  local text = vim.json.encode({
    version = 1,
    port = port,
    pid = uv.os_getpid(),
    ideName = "Neovim",
    workspaceFolders = folders,
    authToken = token,
  })
  uv.fs_unlink(temporary)
  local fd = assert(uv.fs_open(temporary, "wx", tonumber("600", 8)))
  local written = uv.fs_write(fd, text)
  uv.fs_close(fd)
  if written ~= #text then
    uv.fs_unlink(temporary)
    error("glut: the file for Glut could not be written")
  end
  uv.fs_chmod(temporary, tonumber("600", 8))
  assert(uv.fs_rename(temporary, path))
  return path
end

function M.remove(path)
  if path then
    uv.fs_unlink(path)
  end
end

return M
