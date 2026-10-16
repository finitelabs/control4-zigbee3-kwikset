-- The lock driver's bind list, with the driver loaded as Director loads it. The store
-- holds the lock's endpoint (dstEndpoint) and the coordinator's EUI64 (zbindCoordEui),
-- those and the list's record a load kept (zbindList), the endpoint alone, or neither.
-- A driver update must take a stored coordinator as its own, read the lock's table
-- once before its first list and not over a list already set, keep the lock's binds
-- to the coordinator (DoorLock, and the Poll Control it joined with), and go on
-- handling the lock.
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
local POLL_CONTROL = 0x0020
-- The store: the lock's endpoint and keypad verdict, and the coordinator it is bound to.
local STORED = { dstEndpoint = 2, supportsUserCodes = true, keypadKnown = true, zbindCoordEui = COORD }
-- Those, the coordinator's controller, and the record a load kept once it set the list.
local LISTED = {
  dstEndpoint = 2,
  supportsUserCodes = true,
  keypadKnown = true,
  zbindCoordEui = COORD,
  zbindCoordZserver = 20,
  zbindList = { eui = EUI, refused = {}, state = "synced" },
}
-- The endpoint and keypad verdict alone, no coordinator.
local NO_COORD = { dstEndpoint = 2, supportsUserCodes = true, keypadKnown = true }

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

--- Director's copy of the list as "cluster/srcEp>dstEp" strings, "-" for an endpoint
--- left to zserver and "@EUI64" for a coordinator named.
local function listOf(ctl)
  local out = {}
  for _, e in ipairs(ctl.list or {}) do
    out[#out + 1] = string.format("%04X/%d>%s", e.clusterId, e.srcEndpoint, e.dstEndpoint or "-")
      .. (e.dstDeviceEuid and "@" .. e.dstDeviceEuid or "")
  end
  return table.concat(out, ",")
end

--- A binding-table record as the lock holds it.
local function rec(cluster, dstEp)
  return { clusterId = cluster, srcEndpoint = 2, dstEndpoint = dstEp, dstDeviceEuid = COORD }
end

--- The table the Kwikset locks on a 4.3.0 controller held: Poll Control from ep2 to the
--- coordinator's ep1, and DoorLock from ep2 to its ep2.
local function joined()
  return { rec(POLL_CONTROL, 1), rec(DOORLOCK, 2) }
end
local JOINED = "0020/2>1,0101/2>2"
-- What zserver binds, in list order, on a lock that holds neither.
local BOUND = "0101/2>2,0020/2>1"

-- Each earlier load's zv2, kept: collecting its ZigbeeV2 object would unregister the
-- callbacks of the next, where a controller gives each load a Lua state of its own.
local loads = {}
--- Run the driver's source and init as Director does after `initType`.
local function load(initType)
  loads[#loads + 1] = package.loaded["zigbee3.zv2"]
  T.unload("^zigbee3%.")
  ShimResetZigbeePackets()
  proxied = {}
  dofile(DRIVER)
  OnDriverInit()
  OnDriverLateInit(initType)
  CancelTimer("UpdateCheck")
end

local seeded = {}
--- Load the driver as Director does after `initType`, over a store holding `seed` and a
--- lock whose binding table holds `records`; `before(ctl)` readies the controller first.
local function start(seed, records, initType, before)
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
  if before then
    before(ctl)
  end
  load(initType)
  return ctl
end

--- Load the driver again as Director does after `initType`, over what the last load
--- stored and the same controller and lock.
local function reload(initType)
  KillAllTimers()
  ShimPersistLand()
  persist._persist = {}
  load(initType)
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
T.section("a driver update over a stored coordinator: the table is read, then the list keeps both binds")
--------------------------------------------------------------------------------
do
  local ctl = start(STORED, joined(), "DIT_UPDATING")
  -- The first list unbinds what it leaves out, so what the lock holds is read before it.
  check("late init reads the lock's table, and sets no list yet", #ctl.issued == 1 and ctl.syncs == 0)
  ctl.deliver(1)
  -- Naming no coordinator: Director keeps the list across an update.
  check(
    "then sets DoorLock, then Poll Control to the coordinator's ep1, from the stored endpoint",
    ctl.syncs == 1 and listOf(ctl) == "0101/2>-,0020/2>1",
    listOf(ctl)
  )
  ctl.deliver()
  check(
    "zserver found both binds in the table, and kept them",
    tableOf(ctl) == JOINED and ctl.state == "synced",
    tableOf(ctl)
  )
  check("nothing else was read: the stored coordinator is taken", #ctl.issued == 1)
  check("which stays as it was", stored("zbindCoordEui") == COORD)
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
T.section("a driver update over a stored coordinator, the binds gone from the lock")
--------------------------------------------------------------------------------
do
  local ctl = start(STORED, {}, "DIT_UPDATING")
  ctl.deliver()
  check(
    "zserver binds DoorLock, then Poll Control at the coordinator's ep1",
    tableOf(ctl) == BOUND and ctl.state == "synced",
    tableOf(ctl)
  )
  check("and the table is read only before the list", #ctl.issued == 1)
end

--------------------------------------------------------------------------------
T.section("a driver update over the binds a lock joined with, no coordinator stored")
--------------------------------------------------------------------------------
do
  -- The store holds the endpoint but no coordinator: a table read after synced names it.
  local ctl = start(NO_COORD, joined(), "DIT_UPDATING")
  ctl.deliver()
  check("the first sync keeps both binds", tableOf(ctl) == JOINED and ctl.state == "synced", tableOf(ctl))
  check("and the table is read once for the coordinator", #ctl.issued == 1 and stored("zbindCoordEui") == COORD)
end

--------------------------------------------------------------------------------
T.section("a driver update over a list a load set costs nothing")
--------------------------------------------------------------------------------
do
  -- The first load gives Director and zserver the list; the second is the update.
  local ctl = start(LISTED, joined(), "DIT_UPDATING")
  check("the record is this lock's: its list goes unread", ctl.syncs == 1 and #ctl.issued == 0, listOf(ctl))
  ctl.deliver()
  local calls = ctl.calls.SetZdoBindConfig
  reload("DIT_UPDATING")
  check("the list is set again, and Director skips it", ctl.calls.SetZdoBindConfig == calls + 1 and ctl.syncs == 1)
  check("so nothing is read, and the binds stay", #ctl.issued == 0 and #ctl.queue == 0 and tableOf(ctl) == JOINED)
  local list = stored("zbindList")
  check("and the record still says synced", type(list) == "table" and list.eui == EUI and list.state == "synced")
end

--------------------------------------------------------------------------------
T.section("a controller reboot over the list's record names the stored coordinator")
--------------------------------------------------------------------------------
do
  -- Director then holds no list for the lock, so one naming the coordinator is sent.
  local ctl = start(LISTED, joined(), "DIT_STARTUP")
  check(
    "the list names the stored coordinator, with no read first",
    ctl.syncs == 1 and listOf(ctl) == "0101/2>-@" .. COORD .. ",0020/2>1@" .. COORD and #ctl.issued == 0,
    listOf(ctl)
  )
  ctl.deliver()
  check("and zserver keeps both binds", tableOf(ctl) == JOINED and ctl.state == "synced", tableOf(ctl))
end

--------------------------------------------------------------------------------
T.section("a first join: the list waits for the lock's endpoint")
--------------------------------------------------------------------------------
do
  local ctl = start({}, {}, "DIT_ADDING")
  check("no endpoint learned: no list", ctl.calls.SetZdoBindConfig == nil)
  OnZigbeePacketIn(LOCK_STATE_LOCKED, 0x0104, DOORLOCK, 0, 2, 1)
  check(
    "the lock answers from ep2: both listed there",
    ctl.syncs == 1 and listOf(ctl) == "0101/2>-,0020/2>1",
    listOf(ctl)
  )
  ctl.deliver()
  check("zserver binds them", tableOf(ctl) == BOUND, tableOf(ctl))
  -- A new driver's list may not be the one zserver syncs: its synced stands once none follows.
  check("its synced waits to stand", Timer.ZBindSettle ~= nil and #ctl.issued == 0)
  fire("ZBindSettle")
  ctl.deliver()
  check("then the table names the coordinator", stored("zbindCoordEui") == COORD)
  check("kept with its controller", stored("zbindCoordZserver") == 20)
end

--------------------------------------------------------------------------------
T.section("a lock that refuses the Poll Control bind keeps DoorLock")
--------------------------------------------------------------------------------
do
  local ctl = start(STORED, {}, "DIT_UPDATING", function(c)
    c.answers[2 * 65536 + POLL_CONTROL] = 0x84 -- NOT_SUPPORTED, which disables the list
  end)
  ctl.deliver(3) -- the table read, pending, then zserver's sync
  check(
    "the sync bound DoorLock before the refusal disabled the list",
    tableOf(ctl) == "0101/2>2" and ctl.state == "disabled",
    tableOf(ctl)
  )
  ctl.deliver()
  local list = stored("zbindList")
  check(
    "the table named Poll Control as refused",
    type(list) == "table" and #list.refused == 1 and list.refused[1] == 2 * 65536 + POLL_CONTROL
  )
  check("and the list without it synced", listOf(ctl) == "0101/2>-" and ctl.state == "synced", listOf(ctl))
  check("DoorLock still bound", tableOf(ctl) == "0101/2>2", tableOf(ctl))
end

--------------------------------------------------------------------------------
T.section("a frame after a table read that timed out reads it again")
--------------------------------------------------------------------------------
do
  local ctl = start(NO_COORD, joined(), "DIT_UPDATING")
  ctl.deliver(2) -- pending, then zserver's sync
  check("synced, and the read for the coordinator is out", ctl.state == "synced" and #ctl.issued == 1)
  ctl.silence()
  fire("ZV2Read")
  check("no page came, and nothing reads again on its own", #ctl.issued == 1 and Timer.ZV2Read == nil)
  OnZigbeePacketIn(LOCK_STATE_LOCKED, 0x0104, DOORLOCK, 0, 2, 1)
  check("the lock's next frame reads it again", #ctl.issued == 2)
  ctl.deliver()
  check("and that read names the coordinator", stored("zbindCoordEui") == COORD)
end

--------------------------------------------------------------------------------
T.section("ONLINE after a Set refused before Director added the lock sets the list at once")
--------------------------------------------------------------------------------
do
  local ctl = start(LISTED, joined(), "DIT_STARTUP", function(c)
    c.known = false
  end)
  check(
    "refused as not found: nothing set, a retry armed",
    ctl.syncs == 0 and #ctl.invalid == 1 and Timer.ZBindApply ~= nil
  )
  ctl.known = true
  ctl.online() -- Director adds the lock, then the driver hears it ONLINE
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  check("ONLINE sets it without waiting for the retry", ctl.syncs == 1 and Timer.ZBindApply == nil)
  ctl.deliver()
  check("and zserver keeps both binds", tableOf(ctl) == JOINED and ctl.state == "synced", tableOf(ctl))
end

--------------------------------------------------------------------------------
T.section("a reboot over a stored coordinator before Director has the lock: the list goes once it speaks")
--------------------------------------------------------------------------------
do
  local ctl = start(STORED, joined(), "DIT_STARTUP", function(c)
    c.known = false
  end)
  check(
    "the read before the first list is refused as not found: nothing set",
    ctl.syncs == 0 and #ctl.invalid == 1 and ctl.invalid[1].kind == "read"
  )
  ctl.known = true
  ctl.online()
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  OnZigbeePacketIn(LOCK_STATE_LOCKED, 0x0104, DOORLOCK, 0, 2, 1)
  ctl.deliver()
  check(
    "by the lock's next frame the table is read, and the list names the coordinator",
    #ctl.issued == 1 and listOf(ctl) == "0101/2>-@" .. COORD .. ",0020/2>1@" .. COORD,
    listOf(ctl)
  )
  check("and zserver keeps both binds", tableOf(ctl) == JOINED and ctl.state == "synced", tableOf(ctl))
end

--------------------------------------------------------------------------------
T.section("a rejoin has the binder look at the lock's table")
--------------------------------------------------------------------------------
do
  local ctl = start(STORED, joined(), "DIT_UPDATING")
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
