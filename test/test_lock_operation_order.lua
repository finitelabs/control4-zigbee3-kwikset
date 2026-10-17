-- Which history entry the lock's report of an operation names in kwikset_zigbee3_lock.
-- On Front Porch (2026-10-17) a thumbturn unlock at 7:25:37, a thumbturn lock at
-- 7:25:40 and a keypad unlock at 7:25:47 (the lock's event log, records 4 to 6)
-- became "Unlocked by Test, Locked Manual, Unlocked by Test": the driver gave a
-- report naming a user to the newest change of its state that arrived within 4 s,
-- so when the lock's frames came late and out of order the keypad user landed on the
-- thumbturn unlock. A report is now paired with a change by the lock's own time.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_operation_order.lua

local T = require("testlib")
local F = require("lock_fixtures")

local KEYPAD, RF, MANUAL = 0x00, 0x01, 0x02
local LOCK, UNLOCK, MANUAL_LOCK, MANUAL_UNLOCK = 0x01, 0x02, 0x0d, 0x0e
local NO_USER = 0xFFFF
local GET_LOG_RECORD = 0x04

-- The controller's clock, which the suite moves; Front Porch's morning.
local realTime = os.time
local clock = realTime({ year = 2026, month = 10, day = 17, hour = 7, min = 25, sec = 0 })
os.time = function(t) -- luacheck: ignore
  if t ~= nil then
    return realTime(t)
  end
  return clock
end

--- Controller time `t` on the lock's clock: local wall-clock seconds since 2000.
local function lockTime(t)
  local d = os.date("*t", t)
  local noon = realTime({ year = d.year, month = d.month, day = d.day, hour = 12 })
  local days = math.floor((noon - realTime({ year = 2000, month = 1, day = 1, hour = 12 })) / 86400 + 0.5)
  return days * 86400 + d.hour * 3600 + d.min * 60 + d.sec
end

--- The lock reports its LockState: 1 locked, 2 unlocked.
local function lockState(v)
  F.receive(F.DOORLOCK, false, 0x40, 0x0a, F.u16(0x0000) .. string.char(0x30, v))
end

--- The lock pushes an Operation Event Notification for an operation at controller
--- time `t`: no PIN, its LocalTime, no data.
local function operation(src, code, uid, t)
  local payload = string.char(src, code) .. F.u16(uid) .. string.char(0) .. F.u32(lockTime(t)) .. string.char(0)
  F.receive(F.DOORLOCK, true, 0x50, F.OPER_EVENT, payload)
end

--- The lock answers Get Log Record with record `id`, an operation at controller time `t`.
local function logRecord(seq, id, src, code, uid, t)
  local payload = F.u16(id) .. F.u32(lockTime(t)) .. string.char(0, src, code) .. F.u16(uid) .. string.char(0)
  F.receive(F.DOORLOCK, true, seq, GET_LOG_RECORD, payload)
end

--- The driver's wait before it asks the lock's log runs out, and the lock answers
--- with the record given (unasked too, as a late answer would come).
local function logAnswers(id, src, code, uid, t)
  if Timer.LogAttr then
    F.fire("LogAttr")
  end
  local asked = F.only(F.sent(), GET_LOG_RECORD)
  logRecord(asked[1] and asked[1].seq or 0x51, id, src, code, uid, t)
end

--- The newest `n` history entries, newest first, as "message/source".
local function history(n)
  F.proxy("REQUEST_HISTORY")
  local out = {}
  for message, source in tostring(F.last(F.told(), "HISTORY")):gmatch("<message>(.-)</message><source>(.-)</source>") do
    if #out < n then
      out[#out + 1] = message .. "/" .. source
    end
  end
  return out
end

--- The last LOCK_STATUS_CHANGED among `told`, as { source, description }.
local function lastAction(told)
  local n = F.last(told, "LOCK_STATUS_CHANGED")
  return n and { n.SOURCE, n.LAST_ACTION_DESCRIPTION }
end

--- Front Porch's lock with a Guest at id 0, online and read as locked.
local function frontPorch()
  local seed = {}
  for k, v in pairs(F.KEYPAD) do
    seed[k] = v
  end
  seed.users = { [2] = { name = "Guest", code = "2468", active = true, slot = 0 } }
  seed.userIds = { first = 0, last = 29 }
  seed.logItemCount = 10
  F.start(seed)
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  F.readResponse({ F.attr(0x0000, 0x30, 1), F.attr(0x0010, 0x21, 10) })
  F.sent()
  F.told()
end

--------------------------------------------------------------------------------
T.section("7:25: the thumbturn lock's report held up past the keypad unlock")
--------------------------------------------------------------------------------
do
  frontPorch()
  local t = clock + 37 -- 7:25:37, the thumbturn unlock
  clock = t + 10
  lockState(2) -- the thumbturn unlock's report, late
  operation(KEYPAD, UNLOCK, 0, t + 10) -- the keypad unlock at 7:25:47, at once
  clock = t + 11
  lockState(1) -- the thumbturn lock's report, after the keypad unlock's event
  operation(MANUAL, MANUAL_LOCK, NO_USER, t + 3)
  lockState(2) -- the keypad unlock's report
  logAnswers(6, KEYPAD, UNLOCK, 0, t + 10)
  local told = F.told()
  T.eq(
    "the keypad user names the keypad unlock, not the thumbturn's",
    history(3),
    { "Unlocked/Guest", "Locked/Manual", "Unlocked/Manual" }
  )
  T.eq("the proxy is told the keypad unlock", lastAction(told), { "Guest", "Unlocked by Guest (Keypad)" })
  local pushed = {}
  for message, source in tostring(F.last(told, "HISTORY")):gmatch("<message>(.-)</message><source>(.-)</source>") do
    pushed[#pushed + 1] = message .. "/" .. source
  end
  T.eq("and the history it was sent last", { pushed[1], pushed[2], pushed[3] }, history(3))
end

--------------------------------------------------------------------------------
T.section("the thumbturn unlock's own event, last of all, names it")
--------------------------------------------------------------------------------
do
  frontPorch()
  local t = clock + 37
  clock = t + 10
  lockState(2)
  operation(KEYPAD, UNLOCK, 0, t + 10)
  clock = t + 11
  lockState(1)
  operation(MANUAL, MANUAL_LOCK, NO_USER, t + 3)
  lockState(2)
  operation(MANUAL, MANUAL_UNLOCK, NO_USER, t)
  T.eq("each operation names its own entry", history(3), { "Unlocked/Guest", "Locked/Manual", "Unlocked/Manual" })
end

--------------------------------------------------------------------------------
T.section("the same operations in order, as the lock sent them later that morning")
--------------------------------------------------------------------------------
do
  frontPorch()
  local t = clock + 37
  clock = t
  lockState(2)
  operation(MANUAL, MANUAL_UNLOCK, NO_USER, t)
  T.eq("a thumbturn unlock reads Manual", lastAction(F.told()), { "Manual", "Unlocked (Manual)" })
  clock = t + 3
  lockState(1)
  operation(MANUAL, MANUAL_LOCK, NO_USER, t + 3)
  clock = t + 10
  lockState(2)
  operation(KEYPAD, UNLOCK, 0, t + 10)
  T.eq("a keypad unlock names its user", lastAction(F.told()), { "Guest", "Unlocked by Guest (Keypad)" })
  T.eq("each in its entry", history(3), { "Unlocked/Guest", "Locked/Manual", "Unlocked/Manual" })
end

--------------------------------------------------------------------------------
T.section("an operation's event and its log record are one entry")
--------------------------------------------------------------------------------
do
  frontPorch()
  local t = clock + 37
  clock = t
  lockState(2)
  operation(KEYPAD, UNLOCK, 0, t)
  logAnswers(7, KEYPAD, UNLOCK, 0, t)
  T.eq("one unlock, named once", history(5), { "Unlocked/Guest" })
end

--------------------------------------------------------------------------------
T.section("a log record of an earlier operation names no new change")
--------------------------------------------------------------------------------
do
  frontPorch()
  local t = clock + 37
  clock = t
  lockState(2) -- a thumbturn unlock whose event was lost
  logAnswers(8, KEYPAD, UNLOCK, 0, t - 3600) -- the log has not caught up: the newest is an hour old
  T.eq("the proxy is told the thumbturn's unlock", lastAction(F.told()), { "Manual", "Unlocked" })
  T.eq("and so is its entry", history(1), { "Unlocked/Manual" })
end

--------------------------------------------------------------------------------
T.section("a lock of a lock already locked names no later change")
--------------------------------------------------------------------------------
do
  frontPorch()
  local t = clock + 37
  clock = t
  F.proxy("LOCK")
  operation(RF, LOCK, NO_USER, t) -- Control4's lock: the lock was locked already
  clock = t + 9
  lockState(2) -- a thumbturn unlock and lock, their events lost
  clock = t + 10
  lockState(1)
  T.eq("the thumbturn's lock is not taken for Control4's", history(2), { "Locked/Manual", "Unlocked/Manual" })
end

T.finish()
