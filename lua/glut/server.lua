-- The editor's side of Glut's editor protocol (docs/editor-protocol.md in
-- Glut): MCP over HTTP on loopback, a bearer token on every request. Glut
-- connects; this answers. One request per message, JSON answers, keep-alive.
--
-- A request is judged by its head alone before anything of its body is kept:
-- without the token, or not `POST /mcp`, it is answered and the connection
-- closed. The socket's callbacks run in libuv's fast context, where most of
-- Neovim's API may not be called: every request is handed to the main loop
-- with vim.schedule, and answered from there.

local uv = vim.uv

local M = {}

--- The largest request body taken: a file's proposed text, not a disk.
local MAX_BODY = 8 * 1024 * 1024
--- The largest head of a request.
local MAX_HEAD = 16 * 1024
--- How many connections at once: Glut opens two.
local MOST_CONNECTIONS = 16
--- How long a connection may say nothing before it is closed, in milliseconds.
local IDLE = 60 * 1000

--- Compares two strings in time that does not depend on where they differ.
local function same(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
  end
  return diff == 0
end

local reasons = {
  [200] = "OK",
  [202] = "Accepted",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [413] = "Payload Too Large",
  [503] = "Service Unavailable",
}

local function reply(client, status, body)
  body = body or ""
  local head = ("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n"):format(
    status,
    reasons[status] or "",
    #body
  )
  if not client:is_closing() then
    client:write(head .. body)
  end
end

--- A request's head, or why it is refused: the method and path, its headers by
--- lower-case name, its body's length — a plain decimal number, given once, no
--- other encoding.
local function parse_head(head)
  local method, path = head:match("^(%u+) (%S+) HTTP/1%.%d")
  if not method then
    return nil, 400
  end
  local headers, lengths = {}, 0
  for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
    name = name:lower()
    if name == "content-length" then
      lengths = lengths + 1
    end
    headers[name] = value
  end
  if headers["transfer-encoding"] or lengths > 1 then
    return nil, 400
  end
  local length = 0
  if lengths == 1 then
    local digits = headers["content-length"]:match("^%s*(%d+)%s*$")
    if not digits or #digits > 9 then
      return nil, 400
    end
    length = tonumber(digits)
  end
  if length > MAX_BODY then
    return nil, 413
  end
  return { method = method, path = path, headers = headers, length = length }
end

--- Serves `handle(message, respond, connection)` for every JSON-RPC message
--- with the right token; `respond(result | nil, error | nil)` may be called
--- later. `closed(connection)` hears when a connection ends. Returns the port,
--- and a function that stops the server.
function M.start(token, handle, closed)
  local server = uv.new_tcp()
  assert(server:bind("127.0.0.1", 0))
  local clients, count, next_id = {}, 0, 0
  server:listen(64, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    if not server:accept(client) then
      return client:close()
    end
    if count >= MOST_CONNECTIONS then
      reply(client, 503)
      return client:close()
    end
    next_id = next_id + 1
    local connection = next_id
    count = count + 1
    clients[client] = true
    local chunks, size = {}, 0
    local request -- the head of the request whose body is still coming
    local timer = uv.new_timer()
    local function close()
      if clients[client] then
        clients[client] = nil
        count = count - 1
        if closed then
          vim.schedule(function()
            closed(connection)
          end)
        end
      end
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      if not client:is_closing() then
        client:close()
      end
    end
    local function idle()
      timer:stop()
      timer:start(IDLE, 0, close)
    end
    idle()
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        return close()
      end
      idle()
      table.insert(chunks, chunk)
      size = size + #chunk
      while true do
        local buffer = table.concat(chunks)
        chunks = { buffer }
        if not request then
          local head_end = buffer:find("\r\n\r\n", 1, true)
          if not head_end or head_end > MAX_HEAD then
            if (head_end or #buffer) > MAX_HEAD then
              reply(client, 413)
              close()
            end
            return
          end
          local head, status = parse_head(buffer:sub(1, head_end - 1))
          if not head then
            reply(client, status)
            return close()
          end
          -- The token and the place first, by the head alone: nothing of a stranger's body is kept.
          if not same(head.headers["authorization"], "Bearer " .. token) then
            reply(client, 401)
            return close()
          end
          if head.method ~= "POST" or head.path ~= "/mcp" then
            reply(client, 404)
            return close()
          end
          request = head
          buffer = buffer:sub(head_end + 4)
          chunks, size = { buffer }, #buffer
        end
        if size < request.length then
          return
        end
        local body = buffer:sub(1, request.length)
        local rest = buffer:sub(request.length + 1)
        chunks, size = { rest }, #rest
        request = nil
        vim.schedule(function()
          local ok, message = pcall(vim.json.decode, body)
          if not ok or type(message) ~= "table" then
            return reply(client, 400)
          end
          if message.id == nil then
            -- A notification: nothing to answer but that it came.
            pcall(handle, message, function() end, connection)
            return reply(client, 202)
          end
          local answered = false
          local function respond(result, failure)
            if answered then
              return
            end
            answered = true
            local out = { jsonrpc = "2.0", id = message.id }
            if failure then
              out.error = { code = -32603, message = failure }
            else
              out.result = result or vim.empty_dict()
            end
            local encoded, text = pcall(vim.json.encode, out)
            if not encoded then
              text = vim.json.encode({
                jsonrpc = "2.0",
                id = message.id,
                error = { code = -32603, message = "the answer could not be written" },
              })
            end
            reply(client, 200, text)
          end
          local called, why = pcall(handle, message, respond, connection)
          if not called then
            respond(nil, tostring(why))
          end
        end)
        if size == 0 then
          return
        end
      end
    end)
  end)
  local port = server:getsockname().port
  local function stop()
    for client in pairs(clients) do
      if not client:is_closing() then
        client:close()
      end
    end
    if not server:is_closing() then
      server:close()
    end
  end
  return port, stop
end

M._same = same
M._parse_head = parse_head

return M
