
--[[ DEFOLD uses the Lua socket module
local socket = nil
xpcall(function()
    socket = _G.socket or require('socket.core')
end, function()
    -- cocos2dx-lua 里的兼容写法
    socket = cc.exports.socket
end)
--]]
local json = require('poco.lua.support.dkjson')  -- 一定要用这个模块不然字符串发送有问题

-- Length header: int32 little endian (same bytes as struct 'i').
local function pack_len(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function unpack_len(s, pos)
    local a, b, c, d = string.byte(s, pos, pos + 3)
    local n = a + b * 256 + c * 65536 + d * 16777216
    if n >= 2147483648 then n = n - 4294967296 end
    return n
end

-- client handler
local ClientConnection = {}
ClientConnection.__index = ClientConnection

ClientConnection.DEBUG = false
ClientConnection.sock = nil
ClientConnection.buf = ''
ClientConnection.sendbuf = ''

-- Largest request accepted (bytes of JSON). A bigger length header closes the
-- connection instead of buffering without bound.
ClientConnection.MAX_MESSAGE = 4 * 1024 * 1024

function ClientConnection:new(sock, debug, max_message)
    if debug == nil then
        debug = false
    end

    local c = {}
    setmetatable(c, ClientConnection)
    c.DEBUG = debug
    c.sock = sock
    c.buf = ''
    c.sendbuf = ''
    c.sendpos = 1
    c.max_message = max_message or ClientConnection.MAX_MESSAGE
    c.peer = tostring(sock:getpeername())
    c.sock:setoption("tcp-nodelay", true)
    c.sock:setoption('keepalive', true)
    c.sock:settimeout(0.0)
    return c
end

-- Split the buffer into length-prefixed messages (int32 little endian + JSON).
-- Returns the decoded requests, or nil + error when the stream is unusable.
function ClientConnection:input(data)
    self.buf = self.buf .. data
    local ret = {}
    local pos = 1
    local n = #self.buf
    while n - pos + 1 >= 4 do
        local len = unpack_len(self.buf, pos)
        if len < 0 or len > self.max_message then
            return nil, string.format('bad message length %d (max %d)', len, self.max_message)
        end
        if n - pos + 1 < len + 4 then
            break
        end
        local content = string.sub(self.buf, pos + 4, pos + 3 + len)
        pos = pos + 4 + len
        if self.DEBUG then
            print(content)
        end
        local req, _, err = json.decode(content)
        if type(req) == 'table' then
            ret[#ret + 1] = req
        else
            -- answered as a JSON-RPC parse error, the connection stays open
            self:send({ jsonrpc = '2.0', id = json.null, error = { code = -32700, message = 'parse error: ' .. tostring(err) } })
        end
    end
    self.buf = string.sub(self.buf, pos)
    return ret
end

-- Returns '' when the client is gone, a list of requests, or nil.
function ClientConnection:receive()
    local chunk, status, partial = self.sock:receive(65535)
    local data = chunk or partial
    if self.DEBUG then
        print('client recv', data)
    end
    if (data == nil or data == '') and status ~= 'timeout' then
        self:close()
        return ''
    end
    if data == nil or data == '' then
        return nil
    end
    local reqs, err = self:input(data)
    if not reqs then
        print('[poco] ' .. self.peer .. ': ' .. err .. ', closing')
        self:close()
        return ''
    end
    if #reqs > 0 then
        for _, req in ipairs(reqs) do
            req.client = self
        end
        return reqs
    end
end

function ClientConnection:send(data)
    local data = json.encode(data)
    local sdata = pack_len(#data) .. data
    if self.DEBUG then
        print(sdata)
    end
    self.sendbuf = self.sendbuf .. sdata
end

-- Non-blocking: writes what the socket takes now, keeps the rest.
function ClientConnection:drainOutputBuffer()
    if self.closed then return end
    while self.sendpos <= #self.sendbuf do
        local sent, errmsg, partial = self.sock:send(self.sendbuf, self.sendpos)
        local last = sent or partial
        if last and last >= self.sendpos then
            self.sendpos = last + 1
        end
        if errmsg ~= nil then
            if errmsg == 'closed' then
                self:close()
            end
            break
        end
    end
    if self.sendpos > #self.sendbuf then
        self.sendbuf = ''
        self.sendpos = 1
    end
end

function ClientConnection:close()
    if self.closed then return end
    self.closed = true
    self.sock:shutdown('both')
    self.sock:close()
    self.buf = ''
    self.sendbuf = ''
    self.sendpos = 1
    print('[poco] client disconnect ' .. self.peer)
end

function ClientConnection:getAddress()
    return self.peer
end

return ClientConnection
