-- When kwikset_zigbee3_lock sends its history to the lock proxy. It sent HISTORY only
-- in answer to REQUEST_HISTORY, which the proxy sends when the driver loads, so on
-- Front Porch (2026-10-17) the app's History still ended at the day before though
-- the driver had recorded the morning's operations. Each change is sent now.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_history_push.lua

local T = require("testlib")
local F = require("lock_fixtures")

--- The lock reports its LockState: 1 locked, 2 unlocked.
local function lockState(v)
  F.receive(F.DOORLOCK, false, 0x40, 0x0a, F.u16(0x0000) .. string.char(0x30, v))
end

--- The history items of a HISTORY notify, newest first, as "message/source".
local function items(xml)
  local out = {}
  for message, source in tostring(xml):gmatch("<message>(.-)</message><source>(.-)</source>") do
    out[#out + 1] = message .. "/" .. source
  end
  return out
end

--- Whether a HISTORY notify is among `told`.
local function sentHistory(told)
  for _, n in ipairs(told) do
    if n.command == "HISTORY" then
      return true
    end
  end
  return false
end

local seed = {}
for k, v in pairs(F.KEYPAD) do
  seed[k] = v
end
seed.users = { [1] = { name = "Guest", code = "2468", active = true, slot = 1 } }
seed.userIds = { first = 0, last = 29 }
F.start(seed)
OnZigbeeOnlineStatusChanged("ONLINE", "", "")
F.sent()
F.readResponse({ F.attr(0x0000, 0x30, 1) })

--------------------------------------------------------------------------------
T.section("the first reading of the lock is no history")
--------------------------------------------------------------------------------
T.falsy("no HISTORY is sent for it", sentHistory(F.told()))

--------------------------------------------------------------------------------
T.section("an operation at the lock reaches the proxy's history as it happens")
--------------------------------------------------------------------------------
lockState(2)
local told = F.told()
T.eq("a thumbturn unlock is sent at once", items(F.last(told, "HISTORY")), { "Unlocked/Manual" })
F.receive(F.DOORLOCK, true, 0x41, F.OPER_EVENT, string.char(0x00, 0x01) .. F.u16(1) .. string.rep("\0", 6))
told = F.told()
T.eq("a keypad lock is sent with its user", items(F.last(told, "HISTORY")), { "Locked/Guest", "Unlocked/Manual" })
T.eq("as stored", #(F.stored("history") or {}), 2)

--------------------------------------------------------------------------------
T.section("so does a user change the lock confirms")
--------------------------------------------------------------------------------
F.sent()
F.proxy("ADD_USER", { USER_NAME = "Cleaner", PASSCODE = "1357", IS_ACTIVE = "true" })
T.falsy("nothing is sent before the lock confirms it", sentHistory(F.told()))
for _, f in ipairs(F.sent()) do
  if f.cluster == F.DOORLOCK and f.specific then
    F.receive(F.DOORLOCK, true, f.seq, f.cmd, string.char(0))
  end
end
T.eq(
  "then it is",
  items(F.last(F.told(), "HISTORY")),
  { "Added User 2 (Cleaner)/Control4", "Locked/Guest", "Unlocked/Manual" }
)

--------------------------------------------------------------------------------
T.section("the history sent holds the Log Item Count")
--------------------------------------------------------------------------------
F.proxy("SET_NUMBER_LOG_ITEMS", { COUNT = "2" })
lockState(2)
T.eq("the newest two", items(F.last(F.told(), "HISTORY")), { "Unlocked/Manual", "Added User 2 (Cleaner)/Control4" })

T.finish()
