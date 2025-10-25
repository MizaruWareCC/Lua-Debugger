------------------------------------------------------------
-- logger.lua
-- Made by https://github.com/MizaruWareCC
-- Original github repo: https://github.com/MizaruWareCC/Lua-Debugger
------------------------------------------------------------
local Logger = {}
Logger.__index = Logger

local Enums = {
    actions = {
        READ = 1,
        WRITE = 2,
        CALL = 3,
        HOOK_FUNCTION = 4
    }
}

-- utility: check if value is present in a list-like table
local function table_contains(tbl, value)
    if type(tbl) ~= "table" then return false end
    for _, v in pairs(tbl) do
        if v == value then
            return true
        end
    end
    return false
end

-- deep copy (handles cycles)
local function deepcopy(orig, copies) -- http://lua-users.org/wiki/CopyTable
    copies = copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
            end
            setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function actind_to_str(index)
    if index == Enums.actions.READ then return "READ"
    elseif index == Enums.actions.WRITE then return "WRITE"
    elseif index == Enums.actions.CALL then return "CALL"
    elseif index == Enums.actions.HOOK_FUNCTION then return "HOOK FUNCTION"
    else return tostring(index)
    end
end

-- params:
--  - log_file (string) optional
--  - debug (bool) default true
--  - actions (table/list of action constants) default to every action
function Logger.new(params)
    params = params or {}
    if params.debug == nil then params.debug = true end
    params.actions = params.actions or ({Enums.actions.READ, Enums.actions.WRITE, Enums.actions.CALL, Enums.actions.HOOK_FUNCTION})

    local self = setmetatable({
        params = params,
        _log_data = {}, -- array of { action, time, table, key, value, fname, arguments, ... }
        _builtin_overrides = {}, -- array of { fname = string, original = callable, changed = callable }
        _hooked_functions = {}, -- map: original_function -> wrapper_function
        _is_wrapper = {}, -- set: wrapper_function -> true
        _ENV = deepcopy(_G), -- real sandbox environment (a deep copy of globals)
        _ENV_PROXY = nil, -- proxy for _ENV; created in _prepare_env
        _table_names = setmetatable({}, { __mode = "k" }), -- weak-key registry for names
        _table_proxies = setmetatable({}, { __mode = "k" }), -- real -> proxy
        _proxy_to_real = setmetatable({}, { __mode = "k" }), -- proxy -> real
        _custom_fn = nil, -- function to be ran before executing hooked function
    }, Logger)

    -- register common names
    self._table_names[self._ENV] = "_ENV"
    self._table_names[_G] = "_G"

    return self
end

local function join_values(tbl)
    if not tbl then return "" end
    local s = ""
    for i, v in ipairs(tbl) do
        s = s .. tostring(v)
        if i < #tbl then s = s .. ", " end
    end
    return s
end

function Logger:_get_real(t)
    -- if argument is a proxy, return its real table
    return self._proxy_to_real[t] or t
end

function Logger:_get_tablename(t)
    local real = self:_get_real(t)

    if self._table_names[real] then return self._table_names[real] end
    
    return tostring(real)
end

function Logger:_format_action(entry)
    -- entry: { action, time, table, key, value, old_value, new_value, fname, arguments, result, ok, change_type, ... }
    local info
    if entry.action == Enums.actions.READ then
        info = string.format("Reading from %s with key %s, got data: %s (type: %s)",
            self:_get_tablename(entry.table), tostring(entry.key), tostring(entry.value), type(entry.value))
    elseif entry.action == Enums.actions.WRITE then
        if entry.change_type == "update" then
            info = string.format("Updating key %s in %s: old=%s -> new=%s (type: %s)",
                tostring(entry.key), self:_get_tablename(entry.table), tostring(entry.old_value),
                tostring(entry.new_value), type(entry.new_value))
        else
            info = string.format("Writing new key %s to %s: value=%s (type: %s)",
                tostring(entry.key), self:_get_tablename(entry.table), tostring(entry.value), type(entry.value))
        end
    elseif entry.action == Enums.actions.CALL then
        local args_summary = join_values(entry.arguments)
        info = string.format("Calling from %s with callable name %s and arguments [%s]",
            self:_get_tablename(entry.table), tostring(entry.fname), args_summary)
    elseif entry.action == Enums.actions.HOOK_FUNCTION then
        local args_summary = join_values(entry.arguments)
        local result_summary = join_values(entry.result)
        local status = entry.ok and "OK" or "ERR"
        info = string.format("Hooked function %s called on %s: args=[%s] -> result=[%s] (%s)",
            tostring(entry.fname), self:_get_tablename(entry.table), args_summary, result_summary, status)
    else
        info = "Unresolved action"
    end
    return string.format("Action %s at %.4fS: %s", actind_to_str(entry.action), tonumber(entry.time) or 0, info)
end

function Logger:_save_actions()
    local f = self.params.log_file
    if f then
        local file, err = io.open(f, "w")
        if not file then
            error("Couldn't open file for writing: " .. tostring(err))
        end
        local text_version = ""
        for _, data in ipairs(self._log_data) do
            text_version = text_version .. self:_format_action(data) .. "\n"
        end
        file:write(text_version)
        file:close()
        return true
    end
    return false
end

function Logger:_log_action(action, info)
    local entry = { action = action, time = os.clock() }
    if type(info) == "table" then
        for k, v in pairs(info) do entry[k] = v end
    end
    table.insert(self._log_data, entry)

    if self.params.debug then
        local ok, err = pcall(function() print(self:_format_action(entry)) end)
        if not ok then
            io.stderr:write("Logger:_format_action error: " .. tostring(err) .. "\n")
        end
    end
end

function Logger:_find_override(fname)
    for i, d in ipairs(self._builtin_overrides) do
        if d.fname == fname then
            return i
        end
    end
    return nil
end

function Logger:builtin_override(fname, callable)
    local i = self:_find_override(fname)
    local orig = self._ENV[fname] or _G[fname]
    if i then
        self._builtin_overrides[i].changed = callable
    else
        table.insert(self._builtin_overrides, { fname = fname, original = orig, changed = callable })
    end
    -- set on the real env (store real function/table)
    rawset(self._ENV, fname, callable)
end

function Logger:builtin_restore(fname)
    local i = self:_find_override(fname)
    if i then
        local orig = self._builtin_overrides[i].original
        rawset(self._ENV, fname, orig)
        table.remove(self._builtin_overrides, i)
    end
end

function Logger:_register_table_name(t, name)
    if type(t) ~= "table" then return end
    if not self._table_names[t] then
        self._table_names[t] = name or tostring(t)
    end
end

-- wrap a real table into a proxy that logs and recursively wraps child tables
function Logger:_wrap_table(real, name)
    if type(real) ~= "table" then return real end
    if self._table_proxies[real] then
        return self._table_proxies[real]
    end

    local proxy = {}
    self._table_proxies[real] = proxy
    self._proxy_to_real[proxy] = real

    -- register name
    if name then self:_register_table_name(real, name) end

    local meta = {}

    -- __index: read from real, log, wrap returned tables
    meta.__index = function(_, k)
        local v = rawget(real, k)
        if self.params.actions and table_contains(self.params.actions, Enums.actions.READ) then
            self:_log_action(Enums.actions.READ, { table = real, key = k, value = v })
        end
        if type(v) == "table" then
            return self:_wrap_table(v, (self._table_names[real] or tostring(real)) .. "." .. tostring(k))
        else
            return v
        end
    end

    -- __newindex: unwrap proxies, hook functions, register table names, log and write to real
    meta.__newindex = function(t, k, v)
        local old = rawget(real, k)
        local had_old = old ~= nil

        if self._proxy_to_real[v] then
            v = self._proxy_to_real[v]
        end

        -- function hooking
        if type(v) == "function" and table_contains(self.params.actions, Enums.actions.HOOK_FUNCTION) then
            local cached_wrapper = self._hooked_functions[v]
            if cached_wrapper then
                v = cached_wrapper
            elseif not self._is_wrapper[v] then
                local orig = v
                local key_name = tostring(k)
                local wrapper = function(...)
                    if self._custom_fn then -- run custom set callback
                        if self._custom_fn(table.pack(...), tostring(k), self:_get_tablename(t)) == false then -- false -> don't execute following function
                            return
                        end
                    end
                    local args = { ... }
                    local call_results = { pcall(orig, table.unpack(args)) }
                    local ok = table.remove(call_results, 1)
                    self:_log_action(Enums.actions.HOOK_FUNCTION, {
                        table = real,
                        fname = key_name,
                        arguments = args,
                        result = call_results,
                        ok = ok
                    })
                    if ok then
                        return table.unpack(call_results)
                    else
                        error(call_results[1])
                    end
                end
                self._hooked_functions[orig] = wrapper
                self._is_wrapper[wrapper] = true
                v = wrapper
            end
        end

        -- if assigning a table, register name and ensure it's wrapped in proxy for reads
        if type(v) == "table" then
            local parent_name = self:_get_tablename(real)
            local child_name = tostring(k)
            self:_register_table_name(v, parent_name .. "." .. child_name)
        end

        if had_old then
            self:_log_action(Enums.actions.WRITE, { table = real, key = k, old_value = old, new_value = v, change_type = "update" })
        else
            self:_log_action(Enums.actions.WRITE, { table = real, key = k, value = v, change_type = "new" })
        end

        -- finally write real value into the underlying real table
        rawset(real, k, v)
    end

    -- support pairs() iteration by forwarding to real
    meta.__pairs = function()
        return function(tbl, idx)
            local k, v = next(real, idx)
            if k == nil then return nil end
            if type(v) == "table" then
                return k, self:_wrap_table(v, (self._table_names[real] or tostring(real)) .. "." .. tostring(k))
            else
                return k, v
            end
        end, proxy, nil
    end

    -- optional __call: if the real table is callable through __fn
    meta.__call = function(_, ...)
        local f = rawget(real, "__fn")
        if type(f) == "function" then
            local args = { ... }
            if self.params.actions and table_contains(self.params.actions, Enums.actions.CALL) then
                self:_log_action(Enums.actions.CALL, { table = real, fname = tostring(real), arguments = args })
            end
            return f(table.unpack(args))
        end
        return nil
    end

    setmetatable(proxy, meta)
    return proxy
end

function Logger:_set_custom_fn(tbl, recursive, visited)
    visited = visited or {}
    if visited[tbl] then return end
    visited[tbl] = true

    for k, v in pairs(tbl) do
        if type(v) == "function" and not self._is_wrapper[v] then
            local orig = v
            local wrapper = function(...)
                if self._custom_fn then
                    if self._custom_fn(table.pack(...), tostring(k), self:_get_tablename(tbl)) == false then
                        return
                    end
                end
                local call_results = { pcall(orig, ...) }
                local ok = table.remove(call_results, 1)
                self:_log_action(Enums.actions.HOOK_FUNCTION, {
                    table = tbl,
                    fname = tostring(k),
                    arguments = { ... },
                    result = call_results,
                    ok = ok
                })
                if ok then
                    return table.unpack(call_results)
                else
                    error(call_results[1])
                end
            end
            self._hooked_functions[orig] = wrapper
            self._is_wrapper[wrapper] = true
            tbl[k] = wrapper
        elseif type(v) == "table" and recursive then
            self:_set_custom_fn(v, true, visited)
        end
    end
end


function Logger:_prepare_env()
    -- implement _custom_fn for every function in _ENV
    if table_contains(self.params.actions, Enums.actions.HOOK_FUNCTION) then
        self:_set_custom_fn(self._ENV, true)
    end
    if not self._ENV or type(self._ENV) ~= "table" then
        self._ENV = deepcopy(_G)
    end
    self._ENV_PROXY = self:_wrap_table(self._ENV, "_ENV")
end

-- set function to be called before each hooked function is ran, if it returns false won't run function.
-- 1st argument is array of arguments that were passed to function.
-- 2nd argument is function name.
-- 3rd argument is table string name function is called from
function Logger:set_custom_callback(fn)
    self._custom_fn = fn
end

function Logger:run(runnable)
    assert(type(runnable) == "string" or type(runnable) == "function")
    self:_prepare_env()

    if type(runnable) == "function" then
        if setfenv then
            setfenv(runnable, self._ENV_PROXY)
        else
            local _ENV = self._ENV_PROXY
            runnable = function(...) return runnable(...) end
        end
        local ok, err = pcall(runnable)
        if ok then
            print("DEBUGGER: finished executing code")
            self:_save_actions()
            return true
        else
            print("ERROR:", err)
            self:_save_actions()
            return false
        end
    end

    -- runnable is a string -> compile it with proxy as its environment
    if load then
        local fn, err = load(runnable, "LoggerChunk", "t", self._ENV_PROXY)
        if not fn then
            print("ERROR compiling code:", tostring(err))
            return false
        end
        local ok, res = pcall(fn)
        if ok then
            print("DEBUGGER: finished executing code")
            self:_save_actions()
            return true
        else
            print("ERROR:", res)
            self:_save_actions()
            return false
        end
    elseif loadstring then
        local fn, err = loadstring(runnable)
        if not fn then
            print("ERROR compiling code:", tostring(err))
            return false
        end
        if setfenv then
            setfenv(fn, self._ENV_PROXY)
        else
            error("loadstring present but setfenv missing; cannot set environment for chunk")
        end
        local ok, res = pcall(fn)
        if ok then
            print("DEBUGGER: finished executing code")
            self:_save_actions()
            return true
        else
            print("ERROR:", res)
            self:_save_actions()
            return false
        end
    else
        print("You don't have load or loadstring so we can't proceed")
        return false
    end
end

return Logger
