-- The lock driver's real-time bind, with the driver loaded as Director loads it.
-- An earlier build stored the coordinator it found (zbindCoordEui) and the gateway
-- endpoint it used (zbindGwEp) beside the lock's endpoint (dstEndpoint). A driver
-- update over those keys must set zserver's list at once, take the stored coordinator
-- as its own, leave zbindGwEp unread, and go on handling the lock.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_event_bind.lua

require("c4_shim")
require("c4_local") -- driver-local seams, including the ZigbeeV2 shim
require("drivers-common-public.global.timer") -- Timer / TimerFunctions / KillAllTimers

-- The raw source loads the DriverCentral client too; it has no part here.
package.loaded["cloud-client-byte"] = true

local logging = require("lib.logging")
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  if type(logging[m]) == "function" then
    logging[m] = function() end
  end
end

local T = require("testlib")
local check = T.check
local persist = require("lib.persist")

local EUI = "00124B0001AABBCC"
local COORD = "00124B0001CE4B21" -- the shim's coordinator
local DOORLOCK = 0x0101
local BOUND = "0101/2>2"
-- What an earlier build left: the lock's endpoint, its keypad verdict, and its binder's keys.
local EARLIER = { dstEndpoint = 2, supportsUserCodes = true, keypadKnown = true, zbindCoordEui = COORD, zbindGwEp = 2 }

-- The controller's lookups for this lock; the binder normalises the address.
function C4:FindEuidBasedOnNodeId()
  return EUI
end
function C4:FindZserverIDBasedOnNodeId()
  return 20
end
-- The OS the driver.xml asks for.
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  return section == "minimum_os_version" and "4.3.0" or configInfo(self, section)
end
function C4:GetVersionInfo()
  return { version = "4.3.0" }
end
-- What the driver tells the lock proxy.
local proxied = {}
function C4:SendToProxy(binding, command, params)
  proxied[#proxied + 1] = { binding = binding, command = command, params = params }
end
Properties["Driver Status"] = ""
Properties["Firmware Version"] = ""

local DRIVER = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./")
  .. "../drivers/kwikset_zigbee3_lock/driver.lua"

--- What the store holds under a key, as lib.persist decodes it.
local function stored(key)
  ShimPersistLand()
  return Deserialize(C4:PersistGetValue(key, false))
end

--- The device's table as "cluster/srcEp>dstEp" strings, in table order.
local function tableOf(ctl)
  local out = {}
  for _, b in ipairs(ctl.table) do
    out[#out + 1] = string.format("%04X/%d>%d", b.clusterId, b.srcEndpoint, b.dstEndpoint)
      .. (b.dstDeviceEuid == COORD and "" or "@" .. b.dstDeviceEuid)
  end
  return table.concat(out, ",")
end

--- A binding-table record as the lock holds it.
local function rec(cluster, dstEp)
  return { clusterId = cluster, srcEndpoint = 2, dstEndpoint = dstEp, dstDeviceEuid = COORD }
end

local seeded = {}
--- Load the driver as Director does after `initType`, over a store holding `seed` and a
--- lock whose binding table holds `records`.
local function start(seed, records, initType)
  KillAllTimers()
  ShimPersistLand()
  for k in pairs(persist._persist) do
    seeded[k] = true
  end
  for k in pairs(seeded) do
    C4:PersistDeleteValue(k)
  end
  seeded = {}
  for k, v in pairs(seed) do
    seeded[k] = true
    C4:PersistSetValue(k, Serialize(v), false)
  end
  ShimPersistLand()
  persist._persist = {}
  local ctl = ShimInstallZigbeeV2()
  for i, r in ipairs(records) do
    ctl.table[i] = r
  end
  T.unload("^zigbee%.")
  ShimResetZigbeePackets()
  proxied = {}
  dofile(DRIVER)
  OnDriverInit()
  OnDriverLateInit(initType)
  CancelTimer("UpdateCheck")
  return ctl
end

--- Fire one named timer now, as its expiry would.
local function fire(name)
  local h = Timer[name]
  local fn = h and TimerFunctions[h]
  CancelTimer(name)
  ShimPersistLand()
  fn(h, 0)
end

--- The last notify of `command` the proxy got, or nil.
local function lastNotify(command)
  for i = #proxied, 1, -1 do
    if proxied[i].command == command then
      return proxied[i]
    end
  end
  return nil
end

-- A keypad user's lock as the lock pushes it: Operation Event Notification, source
-- Keypad, code Lock, user 3, no PIN, no time, no data.
local KEYPAD_LOCK = string.char(0x09, 0x10, 0x20, 0x00, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
-- A LockState read answered: locked.
local LOCK_STATE_LOCKED = string.char(0x18, 0x01, 0x01, 0x00, 0x00, 0x00, 0x30, 0x01)

--------------------------------------------------------------------------------
T.section("a driver update over an earlier build's keys: the list goes at once")
--------------------------------------------------------------------------------
do
  local ctl = start(EARLIER, { rec(DOORLOCK, 2) }, "DIT_UPDATING")
  check(
    "late init set DoorLock on the stored endpoint",
    ctl.syncs == 1 and #ctl.list == 1 and ctl.list[1].clusterId == DOORLOCK and ctl.list[1].srcEndpoint == 2
  )
  check("naming no destination: Director keeps the list across an update", ctl.list[1].dstDeviceEuid == nil)
  ctl.deliver()
  check("zserver found the bind already in the table, and kept it", tableOf(ctl) == BOUND and ctl.state == "synced")
  check("nothing was read: the stored coordinator is taken", #ctl.issued == 0)
  check("which stays as it was", stored("zbindCoordEui") == COORD)
  check("zbindGwEp is left as it was, unread", stored("zbindGwEp") == 2)
  local list = stored("zbindList")
  check("the list's record is kept for this lock", type(list) == "table" and list.eui == EUI and list.state == "synced")

  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  local reads = 0
  for _, p in ipairs(ShimZigbeePackets()) do
    reads = reads + ((p.clusterId == DOORLOCK and p.dstEndpoint == 2) and 1 or 0)
  end
  check("the lock is read on its stored endpoint", reads > 0)
  OnZigbeePacketIn(KEYPAD_LOCK, 0x0104, DOORLOCK, 0, 2, 1)
  local n = lastNotify("LOCK_STATUS_CHANGED")
  check(
    "a pushed keypad lock reaches the proxy, with its user",
    n ~= nil and n.binding == 5001 and n.params.LOCK_STATUS == "locked" and n.params.SOURCE == "User 3",
    n and n.params
  )
  check("and sets no list again", ctl.syncs == 1 and #ctl.queue == 0)
end

--------------------------------------------------------------------------------
T.section("a driver update over an earlier build's keys, the bind gone from the lock")
--------------------------------------------------------------------------------
do
  local ctl = start(EARLIER, {}, "DIT_UPDATING")
  ctl.deliver()
  check("zserver binds DoorLock", tableOf(ctl) == BOUND and ctl.state == "synced", tableOf(ctl))
  check("and nothing is read", #ctl.issued == 0)
end

--------------------------------------------------------------------------------
T.section("a driver update over an earlier build that had dropped its coordinator")
--------------------------------------------------------------------------------
do
  -- That build deleted both of its keys after an attempt that failed.
  local ctl = start({ dstEndpoint = 2, supportsUserCodes = true, keypadKnown = true }, {}, "DIT_UPDATING")
  ctl.deliver()
  check("zserver binds DoorLock", tableOf(ctl) == BOUND and ctl.state == "synced", tableOf(ctl))
  check("and the table is read once for the coordinator", #ctl.issued == 1 and stored("zbindCoordEui") == COORD)
end

--------------------------------------------------------------------------------
T.section("a controller reboot over an earlier build's keys names the stored coordinator")
--------------------------------------------------------------------------------
do
  -- Director then holds no list for the lock, so one naming the coordinator is sent.
  local ctl = start(EARLIER, { rec(DOORLOCK, 2) }, "DIT_STARTUP")
  check("the list names the stored coordinator", ctl.syncs == 1 and ctl.list[1].dstDeviceEuid == COORD)
  ctl.deliver()
  check("and zserver keeps the bind", tableOf(ctl) == BOUND and ctl.state == "synced")
end

--------------------------------------------------------------------------------
T.section("a first join: the list waits for the lock's endpoint")
--------------------------------------------------------------------------------
do
  local ctl = start({}, {}, "DIT_ADDING")
  check("no endpoint learned: no list", ctl.calls.SetZdoBindConfig == nil)
  OnZigbeePacketIn(LOCK_STATE_LOCKED, 0x0104, DOORLOCK, 0, 2, 1)
  check("the lock answers from ep2: DoorLock listed there", ctl.syncs == 1 and ctl.list[1].srcEndpoint == 2)
  ctl.deliver()
  check("zserver binds it", tableOf(ctl) == BOUND, tableOf(ctl))
  -- A new driver's list may not be the one zserver syncs: its synced stands once none follows.
  check("its synced waits to stand", Timer.ZBindSettle ~= nil and #ctl.issued == 0)
  fire("ZBindSettle")
  ctl.deliver()
  check("then the table names the coordinator", stored("zbindCoordEui") == COORD)
  check("kept with its controller", stored("zbindCoordZserver") == 20)
end

--------------------------------------------------------------------------------
T.section("a rejoin has the binder look at the lock's table")
--------------------------------------------------------------------------------
do
  local ctl = start(EARLIER, { rec(DOORLOCK, 2) }, "DIT_UPDATING")
  ctl.deliver()
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  check("a first ONLINE is no rejoin", Timer.ZBindCheck == nil)
  OnZigbeeOnlineStatusChanged("OFFLINE", "", "")
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  check("back from OFFLINE, the table is read after a wait", Timer.ZBindCheck ~= nil)
  CancelTimer("ZBindCheck")
  OnZigbeeOnlineStatusChanged("REBOOT", "", "")
  check("so after a REBOOT", Timer.ZBindCheck ~= nil)
  OnDriverDestroyed()
  check("and teardown stops it", Timer.ZBindCheck == nil)
end

T.finish()
