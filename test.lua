------------------------------------------------------------
-- test.lua
-- Demonstrates what triggers each "Action ..." line in the log
-- Made by https://github.com/MizaruWareCC
-- Original github repo: https://github.com/MizaruWareCC/Lua-Debugger
------------------------------------------------------------

local logger = require("logger").new({ log_file = 'log.txt' })

------------------------------------------------------------
-- Builtin override phase (first run)
-- This adds "==== " before any printed text
------------------------------------------------------------
logger:builtin_override("print", function(...)
    print("==== ", ...)
end)

------------------------------------------------------------
-- Code executed by logger:run
-- Every read/write/call below will trigger one or more logger hooks
------------------------------------------------------------
local test = [[
    -- (1) WRITE: new key 'x' in _ENV
    x = {1, 2, 3}

    -- (2) READ: access _ENV.x
    -- (3) WRITE: new key 'mal' in _ENV.x (function assignment)
    function x.mal(a, b, c)
        return a - b + c^2
    end

    -- (4) READ: _ENV.print
    -- (5) HOOK FUNCTION: print("Hello") — prints "==== Hello"
    print("Hello")

    -- (6) READ: _ENV.print
    -- (7) HOOK FUNCTION: print("wow!") — prints "==== wow!"
    print("wow!")

    -- (8) READ: _ENV.print
    -- (9) READ: _ENV.string
    -- (10) READ: _ENV.string.gsub
    -- (11) HOOK FUNCTION: string.gsub("Hello", "^H", "MM")
    -- (12) HOOK FUNCTION: print(result)
    print(string.gsub("Hello", "^H", "MM"))

    -- (13) READ: _ENV.x
    -- (14) READ: _ENV.x.mal
    -- (15) HOOK FUNCTION: x.mal("Hello") → causes error
    x.mal("Hello")

    -- (16) READ: _ENV.x
    -- (17) READ: _ENV.x.mal
    -- (18) HOOK FUNCTION: x.mal(5,1000,8) → result = -931
    x.mal(5, 1000, 8)
]]

------------------------------------------------------------
-- Run once with builtin override ("==== " added)
------------------------------------------------------------
logger:run(test)

------------------------------------------------------------
-- Restore builtins (return 'print' to normal)
------------------------------------------------------------
logger:builtin_restore("print")

------------------------------------------------------------
-- Custom callback phase (second run)
-- This callback runs BEFORE any hooked function.
-- If it returns false → original function is NOT called.
------------------------------------------------------------
logger:set_custom_callback(function(args, fname, tbl)
    if args[1] == "Hello" then
        -- (A) Called before executing 'print("Hello")', 'string.gsub("Hello", ...)', 'x.mal("Hello")'
        print("Not executing function " .. fname .. " with 1st argument 'Hello' from " .. tbl)
        return false -- prevents function call
    end
end)

------------------------------------------------------------
-- Run again (same code), but now custom callback blocks functions
------------------------------------------------------------
logger:run(test)
