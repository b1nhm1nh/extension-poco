
local VERSION = require('poco.lua.POCO_SDK_VERSION')
local ClientConnection = require('poco.lua.ClientConnection')

local PocoManager = {}
PocoManager.__index = PocoManager

PocoManager.DEBUG = false
PocoManager.VERSION = VERSION

PocoManager.server_sock = nil
PocoManager.all_socks = {}
PocoManager.clients = {}

-- from unit space to screen space
local function unit_to_screen(x, y)
    local w, h = window.get_size()
    return x * w, y * h
end

PocoManager.view_proj     = vmath.matrix4()
PocoManager.gui_view_proj = vmath.matrix4()

-- rpc methods registration
local dispatcher = {
    GetSDKVersion = function() return VERSION end,
    -- onlyVisibleNode (poco default true): skip the children of disabled gui nodes.
    Dump = function(onlyVisibleNode)
        if onlyVisibleNode == nil then
            onlyVisibleNode = true
        end
        return poco_helper.dump(PocoManager.view_proj, PocoManager.gui_view_proj, onlyVisibleNode)
    end,
    Click = function(x, y)
        x, y = unit_to_screen(x, y)
        poco_helper.click(x, y)
        return {}
    end,
    LongClick = function(x, y, duration)
        x, y = unit_to_screen(x, y)
        poco_helper.long_click(x, y, duration)
        return {}
    end,
    -- RClick = function(x, y)
    --     local w, h = window.get_size()
    --     poco_helper.right_click(x * w, y * h)
    --     return {}
    -- end,
    -- DoubleClick = function(x, y)
    --     local w, h = window.get_size()
    --     poco_helper.double_click(x * w, y * h)
    --     return {}
    -- end,

    Swipe = function(x1, y1, x2, y2, duration)
        x1, y1 = unit_to_screen(x1, y1)
        x2, y2 = unit_to_screen(x2, y2)
        poco_helper.swipe(x1, y1, x2, y2, duration)
        return {}
    end,
    -- NOTE: Instead of having this extension depend on another screenshot extension
    -- we recommend users to do that themselves, and implement this function
    -- Screenshot = function(width)
    --     return ...
    -- end,
    GetScreenSize = function()
        local w, h = window.get_size()
        return {width = w, height = h}
    end,
    -- NOTE: We currently have no good way of returning a unique ID from Defold to Poco that
    -- contains the URL but also the sub component (for gui nodes)
    -- SetText = function(_instanceId, val)
    --     print("SetText", _instanceId, val)
    --     local node = Dumper:getCachedNode(_instanceId)
    --     if node ~= nil then
    --         return node:setAttr('text', val)
    --     end
    --     return false
    -- end,
    KeyEvent = function(val)
        poco_helper.keyevent(val)
        return true
    end,
    -- Runs any Lua sent by a client: only registered when init_server is called
    -- with { allow_execute = true } (see below).
    Execute = function(msg)
        local ok, pcall_result = pcall(loadstring, msg)
        if not ok then
            local errmsg = "Failed to loadstring '" .. msg .. "'. Error: " .. pcall_result
            print(errmsg)
            return errmsg
        end
        local f = pcall_result
        
        ok, pcall_result = pcall(f)
        if not ok then
            local errmsg = "Failed to run '" .. msg .. "'. Error: " .. pcall_result
            print(errmsg)
            return errmsg
        end
        local res = pcall_result

        if res ~= nil then
            return res
        end
        return ""
    end,
}

local callbacks = {
}

-- Execute is kept out of the dispatcher unless asked for.
local execute_fn = dispatcher.Execute
dispatcher.Execute = nil


-- init_server(port [, opts])
--   opts.host           address to bind, default "127.0.0.1" (reachable through
--                       `adb forward` / `iproxy`); "*" for every interface
--   opts.allow_execute  register the Execute rpc (runs any Lua), default false
--   opts.max_message    largest request in bytes, default 4 MB
-- Returns true when the server listens, or false + error.
function PocoManager:init_server(port, opts)
    if poco_helper == nil then
        print("extension-poco: The native code is missing, aborting Poco initalization")
        return false, "no native code"
    end
    if self.server_sock then
        return true
    end
    opts = opts or {}
    port = port or 15004
    local host = opts.host or "127.0.0.1"
    self.max_message = opts.max_message
    dispatcher.Execute = opts.allow_execute and execute_fn or nil

    local server_sock, err = socket.tcp()
    if not server_sock then
        print("[poco] socket.tcp failed: " .. tostring(err))
        return false, err
    end
    server_sock:setoption('reuseaddr', true)
    server_sock:setoption('keepalive', true)
    server_sock:settimeout(0.0)
    local ok, berr = server_sock:bind(host, port)
    if ok then
        ok, berr = server_sock:listen(5)
    end
    if not ok then
        server_sock:close()
        print(string.format("[poco] cannot listen on tcp://%s:%s: %s", host, port, tostring(berr)))
        return false, berr
    end
    self.all_socks = { server_sock }
    self.clients = {}
    self.server_sock = server_sock
    print(string.format('[poco] server listens on tcp://%s:%s%s', host, port,
        opts.allow_execute and " (Execute on)" or ""))
    return true
end

function PocoManager:stop_server()
    for _, c in pairs(self.clients) do
        c:close()
    end
    if self.server_sock then
        self.server_sock:close()
    end
    self.server_sock = nil
    self.all_socks = {}
    self.clients = {}
end

-- TODO: perhaps drive this automatically from the extension update loop?
function PocoManager:server_loop()
    if poco_helper == nil or self.server_sock == nil then
        return
    end

    local r = socket.select(self.all_socks, nil, 0)
    if r and #r > 0 then
        local gone = false
        for _, v in ipairs(r) do
            if v == self.server_sock then
                local client_sock, err = self.server_sock:accept()
                if client_sock then
                    print('[poco] new client accepted', client_sock:getpeername())
                    table.insert(self.all_socks, client_sock)
                    self.clients[client_sock] = ClientConnection:new(client_sock, self.DEBUG, self.max_message)
                elseif err ~= 'timeout' then
                    print('[poco] accept failed: ' .. tostring(err))
                end
            else
                local client = self.clients[v]
                if client then
                    local reqs = client:receive()
                    if reqs == '' then
                        self.clients[v] = nil
                        gone = true
                    elseif reqs ~= nil then
                        for _, req in ipairs(reqs) do
                            self:onRequest(req)
                        end
                    end
                end
            end
        end

        if gone then
            local keep = { self.server_sock }
            for _, s in ipairs(self.all_socks) do
                if self.clients[s] then keep[#keep + 1] = s end
            end
            self.all_socks = keep
        end
    end

    for _, c in pairs(self.clients) do
        c:drainOutputBuffer()
    end
end


function PocoManager:set_dispatch_fn(method, fn)
    dispatcher[method] = fn
end

function PocoManager:set_dispatch_callback_fn(method, fn)
    callbacks[method] = fn
end

function PocoManager:set_view_proj(view_proj)
    PocoManager.view_proj = view_proj
end

function PocoManager:set_gui_view_proj(gui_view_proj)
    PocoManager.gui_view_proj = gui_view_proj
end

function PocoManager:onRequest(req)
    local client = req.client
    local method = req.method
    local params = type(req.params) == 'table' and req.params or {}
    local func = dispatcher[method]
    local client_callback = callbacks[method]
    local ret = {
        id = req.id,
        jsonrpc = req.jsonrpc,
        result = nil,
        error = nil,
    }
    if func == nil then
        ret.error = {code = -32601, message = string.format('No such rpc method "%s", reqid: %s, client:%s', tostring(method), tostring(req.id), client:getAddress())}
        client:send(ret)
    else
        xpcall(function()
            local result = func((table.unpack or unpack)(params))
            if type(result) == 'function' then
                result(function(cbresult)
                    ret.result = cbresult
                    client:send(ret)
                end)
                return
            else
                if client_callback ~= nil then
                    local newresult = client_callback(result)
                    if newresult == nil then
                        local err = string.format('Client callback for rpc method "%s" returned `nil`', method)
                        print("[poco] Error: ", err)
                    else
                        result = newresult
                    end
                end
                ret.result = result
                client:send(ret)
            end
        end, function(msg)
            ret.error = {message = debug.traceback(msg)}
            client:send(ret)
        end)
    end
end

return PocoManager
