-- When kwikset_zigbee3_lock owes the lock a PIN write for a saved user. The lock
-- rejects an occupied slot being re-written with its own PIN, so the write goes
-- out only when the code or the active state changed. An inactive user read as
-- having no previous state, so every edit of one sent its PIN clear again.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_user_edit_pin_write.lua
--
-- A driver.lua cannot be loaded far enough to reach its locals, so upsertUser is
-- cut out of the source and compiled with its collaborators supplied here.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

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

local upsertSrc = src and src:match("\n(local function upsertUser%s*%b()\n.-\nend)\n")
T.check("upsertUser was cut out", upsertSrc ~= nil, "no match")

local chunk, err = loadstring((upsertSrc or "") .. "\nreturn upsertUser", "upsertUser")
T.check("the cut function compiles", chunk ~= nil, err)

--- Save a user through the cut upsertUser.
--- @param users table The stored users before the save, by id.
--- @param tParams table The proxy's ADD_USER or EDIT_USER params.
--- @return table env The environment, carrying the owed keys and the PIN writes.
local function save(users, tParams)
  local env = {
    log = require("lib.logging"),
    state = { supportsUserCodes = true, limits = { maxUsers = 30, minPin = 4, maxPin = 8 }, users = users },
    owed = {},
    pinWrites = {},
    notifyLockChanged = function() end,
    captureSchedule = function() end,
    saveUsers = function() end,
    writeUserSchedule = function() end,
    notify = function() end,
    userFields = function() end,
  }
  env.registerPending = function(key)
    env.owed[key] = true
  end
  env.writeUserPin = function(id, code)
    env.pinWrites[#env.pinWrites + 1] = { id = id, code = code }
  end
  setfenv(chunk, setmetatable(env, { __index = _G }))
  chunk()(tParams, users[tonumber(tParams.USER_ID)] ~= nil)
  return env
end

T.section("an edit that changes neither the code nor the active state owes no PIN write")
local env = save(
  { [3] = { name = "Guest", code = "1234", active = false } },
  { USER_ID = "3", USER_NAME = "Cleaner", PASSCODE = "1234", IS_ACTIVE = "False" }
)
T.eq("an inactive user renamed", env.pinWrites, {})
T.eq("its PIN is not owed", env.owed["pin:3"], nil)
T.eq("its schedule still is", env.owed["sched:3"], true)
env = save(
  { [3] = { name = "Guest", code = "1234", active = true } },
  { USER_ID = "3", USER_NAME = "Cleaner", PASSCODE = "1234", IS_ACTIVE = "True" }
)
T.eq("an active user renamed", env.pinWrites, {})

T.section("a changed active state or code owes one")
env = save(
  { [3] = { name = "Guest", code = "1234", active = true } },
  { USER_ID = "3", USER_NAME = "Guest", PASSCODE = "1234", IS_ACTIVE = "False" }
)
T.eq("a user made inactive has its PIN cleared", env.pinWrites, { { id = 3 } })
T.eq("and the clear is owed", env.owed["pin:3"], true)
env = save(
  { [3] = { name = "Guest", code = "1234", active = false } },
  { USER_ID = "3", USER_NAME = "Guest", PASSCODE = "1234", IS_ACTIVE = "True" }
)
T.eq("a user made active has its PIN set", env.pinWrites, { { id = 3, code = "1234" } })
env = save(
  { [3] = { name = "Guest", code = "1234", active = true } },
  { USER_ID = "3", USER_NAME = "Guest", PASSCODE = "5678", IS_ACTIVE = "True" }
)
T.eq("an active user given a new code has it set", env.pinWrites, { { id = 3, code = "5678" } })

T.section("a new user owes one")
env = save({}, { USER_ID = "3", USER_NAME = "Guest", PASSCODE = "1234", IS_ACTIVE = "True" })
T.eq("added active, its PIN is set", env.pinWrites, { { id = 3, code = "1234" } })
env = save({}, { USER_ID = "3", USER_NAME = "Guest", IS_ACTIVE = "False" })
T.eq("added inactive, its slot is cleared", env.pinWrites, { { id = 3 } })

T.finish()
