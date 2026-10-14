-- What kwikset_zigbee3_lock reads back for one-touch locking after a reload.
-- Saved as off, it loaded as never configured, which the proxy is told is on
-- and an owed write sends to the lock as on.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_one_touch_reload.lua
--
-- A driver.lua cannot be loaded far enough to reach its locals, so loadState is
-- cut out of the source and compiled with its state and persist supplied here.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local Persist = getmetatable(require("lib.persist"))

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local src = readFile(root .. "/drivers/kwikset_zigbee3_lock/driver.lua")
T.check("the kwikset_zigbee3_lock source was read", src ~= nil, "missing")

local loadStateSrc = src and src:match("\n(local function loadState%s*%b()\n.-\nend)\n")
T.check("loadState was cut out", loadStateSrc ~= nil, "no match")

local chunk, err = loadstring((loadStateSrc or "") .. "\nreturn loadState", "loadState")
T.check("the cut function compiles", chunk ~= nil, err)

--- Run the cut loadState against a persist.
--- @param persist table What the driver reads its saved state from.
--- @return table state The state loadState filled in.
local function loadState(persist)
  local env = setmetatable({ log = require("lib.logging"), persist = persist, state = {} }, { __index = _G })
  setfenv(chunk, env)
  chunk()()
  return env.state
end

-- lib/persist over the shim's storage. A fresh instance has an empty cache, so
-- get() reads storage as it does after a reload.
local function reloaded(stored)
  local writer = Persist:new()
  writer:delete("oneTouchLocking")
  for key, value in pairs(stored) do
    writer:set(key, value)
  end
  return Persist:new()
end

-- lib/persist hands back a shared empty table for a key that is not stored when
-- no default is given. This one hands back nil, and has to load the same.
local function nilForMissing(stored)
  return {
    get = function(_, key, default)
      if stored[key] == nil then
        return default
      end
      return stored[key]
    end,
  }
end

for _, case in ipairs({
  { name = "lib/persist", persist = reloaded },
  { name = "a persist that returns nil for a missing key", persist = nilForMissing },
}) do
  T.section("one-touch locking loads as it was saved, from " .. case.name)
  T.eq("off stays off", loadState(case.persist({ oneTouchLocking = false })).oneTouchLocking, false)
  T.eq("on stays on", loadState(case.persist({ oneTouchLocking = true })).oneTouchLocking, true)
  T.eq("never saved stays never configured", loadState(case.persist({})).oneTouchLocking, nil)
end

T.finish()
