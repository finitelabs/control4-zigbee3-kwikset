-- The programming events kwikset_zigbee3_lock fires. It fired them with
-- C4:FireEvent(1) and the like, which takes an event's name: on dev (4.3.0) a
-- number fired nothing, so Locked, Unlocked, Jammed and Battery Low never ran
-- their programming.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_events.lua

local T = require("testlib")
local F = require("lock_fixtures")

local POWER = 0x0001

--- The lock answers a LockState read: 0 not fully locked, 1 locked, 2 unlocked.
local function readLockState(v)
  F.readResponse({ F.attr(0x0000, 0x30, v) })
end

--- The lock answers a battery read, in half percent steps.
local function readBattery(pct)
  F.receive(POWER, false, 0x51, F.READ_RSP, F.attr(0x0021, 0x20, pct * 2))
end

T.section("each lock event fires by its id")
F.start(F.KEYPAD)
OnZigbeeOnlineStatusChanged("ONLINE", "", "")
readLockState(1)
F.fired()
readLockState(2)
T.eq("unlocked fires Unlocked (2)", F.fired(), { 2 })
readLockState(1)
T.eq("locked fires Locked (1)", F.fired(), { 1 })
readLockState(0)
T.eq("not fully locked fires Jammed (3)", F.fired(), { 3 })

T.section("Battery Low fires by its id on the crossing into low")
readBattery(40)
F.fired()
readBattery(12)
T.eq("Battery Low (4)", F.fired(), { 4 })
readBattery(10)
T.eq("and not again while low", F.fired(), {})

T.finish()
