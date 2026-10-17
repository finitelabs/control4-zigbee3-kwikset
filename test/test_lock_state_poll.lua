-- What kwikset_zigbee3_lock tells the lock proxy when it reads a lock that has not
-- moved, and how often it reads. Every 30 s it read LockState and, finding no
-- change, sent LOCK_STATUS_CHANGED with SOURCE Control4 and MANUAL false, so within
-- 30 s of "Unlocked by Test (Keypad)" the proxy was told Control4 (Front Porch,
-- 2026-10-17). The lock proxy docs send it when the status changes, and Control4's
-- own lock drivers only then. With zserver's DoorLock bind in place the lock pushes
-- each operation itself, so the 30 s read wakes a battery lock for nothing.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_state_poll.lua

local T = require("testlib")
local F = require("lock_fixtures")

local COORD = "00124B0001CE4B21" -- the shim's coordinator

-- The controller's clock, which the suite moves.
local realTime = os.time
local clock = realTime({ year = 2026, month = 10, day = 17, hour = 7, min = 25, sec = 47 })
os.time = function(t) -- luacheck: ignore
  if t ~= nil then
    return realTime(t)
  end
  return clock
end

--- The lock answers a LockState read: 1 locked, 2 unlocked.
local function readLockState(v)
  F.readResponse({ F.attr(0x0000, 0x30, v) })
end

--- The lock pushes a keypad unlock by its user 1, with no time.
local function keypadUnlock()
  F.receive(F.DOORLOCK, true, 0x41, F.OPER_EVENT, string.char(0x00, 0x02) .. F.u16(1) .. string.rep("\0", 6))
end

--- The LOCK_STATUS_CHANGED notifies among `told`.
local function statusChanges(told)
  local out = {}
  for _, n in ipairs(told) do
    if n.command == "LOCK_STATUS_CHANGED" then
      out[#out + 1] = { n.params.SOURCE, n.params.LAST_ACTION_DESCRIPTION, n.params.MANUAL }
    end
  end
  return out
end

--- The clusters and attributes the frames among `frames` read, as "cluster/attr".
local function reads(frames)
  local out = {}
  for _, f in ipairs(frames) do
    if not f.specific and f.cmd == 0x00 then
      for at = 1, #f.payload - 1, 2 do
        out[#out + 1] = string.format("%04x/%04x", f.cluster, f.payload:byte(at) + f.payload:byte(at + 1) * 256)
      end
    end
  end
  table.sort(out)
  return out
end

--- A store with the keypad lock, a user 1, and `extra`.
local function store(extra)
  local seed = {}
  for k, v in pairs(F.KEYPAD) do
    seed[k] = v
  end
  seed.users = { [1] = { name = "Guest", code = "2468", active = true, slot = 1 } }
  seed.userIds = { first = 0, last = 29 }
  for k, v in pairs(extra or {}) do
    seed[k] = v
  end
  return seed
end

--------------------------------------------------------------------------------
T.section("a reading that finds no change tells the proxy nothing")
--------------------------------------------------------------------------------
do
  F.start(store())
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  readLockState(1)
  F.told()
  readLockState(2)
  keypadUnlock()
  T.eq(
    "a keypad unlock is told, then named",
    statusChanges(F.told()),
    { { "Manual", "Unlocked", true }, { "Guest", "Unlocked by Guest (Keypad)", true } }
  )
  clock = clock + 30
  readLockState(2)
  T.eq("the next poll, finding it still unlocked, is not", statusChanges(F.told()), {})
  keypadUnlock()
  T.eq("nor is the lock's event again", statusChanges(F.told()), {})
  readLockState(1)
  T.eq("a read that finds it locked is", statusChanges(F.told()), { { "Manual", "Locked", true } })
end

--------------------------------------------------------------------------------
T.section("with DoorLock bound, LockState is read with the battery, hourly")
--------------------------------------------------------------------------------
do
  -- The list's record a load kept: synced, DoorLock on ep2 bound.
  F.start(store({
    zbindCoordEui = COORD,
    zbindCoordZserver = 20,
    zbindList = { eui = "00124B0001AABBCC", refused = {}, bound = { 2 * 65536 + F.DOORLOCK }, state = "synced" },
  }))
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  T.eq("no 30 s read", Timer.StatePoll, nil)
  T.truthy("the hourly read is armed", Timer.BatteryPoll)
  F.sent()
  F.tick("BatteryPoll")
  T.eq("which reads LockState and the battery", reads(F.sent()), { "0001/0021", "0101/0000" })
end

--------------------------------------------------------------------------------
T.section("until zserver has bound DoorLock, LockState is read every 30 s")
--------------------------------------------------------------------------------
do
  local ctl = F.start(store({ zbindCoordEui = COORD }))
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  T.truthy("the 30 s read is armed", Timer.StatePoll)
  F.sent()
  F.tick("StatePoll")
  T.eq("and reads LockState", reads(F.sent()), { "0101/0000" })
  ctl.deliver()
  T.eq("once it has, the 30 s read stops", Timer.StatePoll, nil)
  OnZigbeeOnlineStatusChanged("OFFLINE", "", "")
  T.eq("offline, nothing is read", { Timer.StatePoll, Timer.BatteryPoll }, {})
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  T.eq("back online with DoorLock bound, none again", Timer.StatePoll, nil)
end

--------------------------------------------------------------------------------
T.section("a lock that refuses the DoorLock bind keeps the 30 s read")
--------------------------------------------------------------------------------
do
  local ctl = F.start(store({ zbindCoordEui = COORD }))
  ctl.answers[2 * 65536 + F.DOORLOCK] = 0x84 -- NOT_SUPPORTED, which disables the list
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  ctl.deliver()
  T.eq("the binder names it refused", (F.stored("zbindList") or {}).refused, { 2 * 65536 + F.DOORLOCK })
  T.eq("and zserver synced the list without it", ctl.state, "synced")
  T.truthy("and the 30 s read goes on", Timer.StatePoll)
end

T.finish()
