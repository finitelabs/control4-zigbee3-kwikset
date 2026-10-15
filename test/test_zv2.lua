-- The controller's Zigbee API, C4:ZigbeeV2(), and the driver's use of it
-- (src/zigbee/zv2.lua).
--
-- The first sections hold the shim in c4_local.lua to what a 4.3.0 controller did
-- when it was measured, so the suites built on it test against the real API: the
-- bind list zserver keeps for a device, and the table read. The rest drive zv2.lua:
-- one object for the driver's life, Init()ed once with three callbacks, a state heard
-- while no binder listens kept for the next, a list that is never empty, and a read
-- that takes only its own page.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_zv2.lua

require("c4_shim")
require("c4_local") -- driver-local seams, including the ZigbeeV2 shim
require("drivers-common-public.global.timer") -- Timer / TimerFunctions / KillAllTimers

local logging = require("lib.logging")
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  if type(logging[m]) == "function" then
    logging[m] = function() end
  end
end

local T = require("testlib")
local check = T.check

local COORD = "00124B0001CE4B21" -- the shim's coordinator
local OLD_COORD = "00124B0001CE4B99"
local BULB = "001788010BADBEEF"
local NOT_FOUND = "Device not found in Zigbee Manager"
local DOORLOCK = 0x0101

-- The delay each named timer was last armed with.
local armedFor = {}
do
  local set = SetTimer
  SetTimer = function(id, delay, ...)
    armedFor[id] = delay
    return set(id, delay, ...)
  end
end

--- Fire one named timer now, as its expiry would.
local function fire(name)
  local h = Timer[name]
  if h == nil then
    return false
  end
  local fn = TimerFunctions[h]
  CancelTimer(name)
  fn(h, 0)
  return true
end

--- Every call a callback got, each as { n = argument count, ... }.
local function recorder()
  local r = {}
  return r, function(...)
    r[#r + 1] = { n = select("#", ...), ... }
  end
end

--- A binding-table record as the device holds it.
local function rec(cluster, dstEp, dst, srcEp)
  return { clusterId = cluster, srcEndpoint = srcEp or 2, dstEndpoint = dstEp, dstDeviceEuid = dst or COORD }
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

--- The states a recorder heard, comma-joined.
local function states(r)
  local out = {}
  for _, c in ipairs(r) do
    out[#out + 1] = c[1].state
  end
  return table.concat(out, ",")
end

--- A fresh zv2 module against a fresh shim, as a newly loaded driver has.
local function fresh(opts)
  KillAllTimers()
  local ctl = ShimInstallZigbeeV2(opts)
  T.unload("^zigbee%.")
  return ctl, require("zigbee.zv2")
end

--------------------------------------------------------------------------------
T.section("the shim: objects, Init and callback setters as measured")
--------------------------------------------------------------------------------
do
  local ctl = ShimInstallZigbeeV2()
  local zb = C4:ZigbeeV2()
  check("each call makes a new object", C4:ZigbeeV2() ~= zb and ctl.made == 2)
  check("Init returns 0", zb:Init() == 0)
  check("and 0 again", zb:Init() == 0 and ctl.inits == 2)
  T.raises("a setter with no function", function()
    zb:OnZdoSentStatus()
  end, "Not enough arguments passed (expected 1: func)")
  for _, bad in ipairs({ false, 5, "f" }) do
    T.raises("a setter given " .. tostring(bad), function()
      zb:OnZdoSentStatus(bad)
    end, "func should be a function")
  end
  check("a setter returns the object", zb:OnZdoSentStatus(function() end) == zb)
  -- The 4.2.1 name and the 4.3.0 name set one slot: the last setter wins.
  local old, oldFn = recorder()
  local new, newFn = recorder()
  zb:ResZdoGetBindCb(oldFn)
  zb:OnZdoGetBindTableResponse(newFn)
  zb:SendZdoGetBindTable(0)
  ctl.deliver()
  check("the alias shares the slot: only the last setter hears", #old == 0 and #new == 1, #old .. "/" .. #new)
  T.raises("a method the shim does not model raises", function()
    zb:OnSysCheckInHandledEvent(function() end)
  end, "is not modelled")
  check("and is recorded", ctl.calls.OnSysCheckInHandledEvent == 1)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: one callback registration per device, as measured")
--------------------------------------------------------------------------------
do
  local ctl = ShimInstallZigbeeV2()
  local a, b = C4:ZigbeeV2(), C4:ZigbeeV2()
  local heardA, fnA = recorder()
  local heardB, fnB = recorder()
  a:OnZdoSentStatus(fnA)
  b:OnZdoSentStatus(fnB)
  a:SendZdoGetBindTable(0)
  ctl.deliver()
  check("commands go out without Init(), but nobody hears them", #ctl.issued == 1 and #heardA + #heardB == 0)
  a:Init()
  b:SendZdoGetBindTable(0)
  ctl.deliver()
  check("the object that called Init() hears every command, whoever sent it", #heardA == 3 and #heardB == 0)
  b:Init()
  a:SendZdoGetBindTable(0)
  ctl.deliver()
  check("the last Init() wins", #heardA == 3 and #heardB == 3)

  -- Collecting any object unregisters the device, even one never Init()ed.
  do
    local _ = C4:ZigbeeV2()
  end
  collectgarbage()
  collectgarbage()
  check("the throwaway was collected", ctl.collected == 1, ctl.collected)
  a:SendZdoGetBindTable(0)
  ctl.deliver()
  check("and the device's registration went with it", #heardA == 3 and #heardB == 3)
  b:Init()
  a:SendZdoGetBindTable(0)
  ctl.deliver()
  check("Init() again restores it", #heardB == 6)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: the table read, as measured")
--------------------------------------------------------------------------------
do
  local ctl = ShimInstallZigbeeV2()
  ctl.table = { rec(0x0702, 3), rec(0x0B04, 2), rec(0x0006, 1), rec(0x0020, 1) }
  local zb = C4:ZigbeeV2()
  zb:Init()
  T.raises("a read with no index", function()
    zb:SendZdoGetBindTable()
  end, "Not enough arguments passed (expected 1: index)")
  for _, bad in ipairs({ "x", true }) do
    T.raises("an index " .. tostring(bad), function()
      zb:SendZdoGetBindTable(bad)
    end, "index should be a number")
  end
  local rid, rmsg = zb:SendZdoGetBindTable(-1)
  check("a negative index: 0 and why, and nothing sent", rid == 0 and rmsg == "SendZdoGetBindTable invalid index: -1")
  local st, stFn = recorder()
  local pages, pageFn = recorder()
  zb:OnZdoSentStatus(stFn)
  zb:OnZdoGetBindTableResponse(pageFn)
  local cid, empty = zb:SendZdoGetBindTable(0)
  check("a read returns a commandId and an empty string", type(cid) == "number" and cid > 2 ^ 53 and empty == "")
  zb:SendZdoGetBindTable("3")
  zb:SendZdoGetBindTable(10)
  zb:SendZdoGetBindTable(256)
  ctl.deliver()
  check("queued, in progress, ok", st[1][2] == 61445 and st[2][2] == 5 and st[3][2] == 0 and st[1][1] == cid)
  check("each status names itself", st[1][3] == "ZSTATUS_QUEUE_RECEIVED" and st[3][3] == "ZSTATUS_OK")
  local p1, p2, p3, p4 = pages[1][1], pages[2][1], pages[3][1], pages[4][1]
  check("a page holds 3 records, and counts the whole table", #p1.binds == 3 and p1.entries == 4 and p1.startIndex == 0)
  check("a numeric string is an index: the 4th needs StartIndex 3", #p2.binds == 1 and p2.startIndex == 3)
  check("past the end: an empty page", #p3.binds == 0 and p3.entries == 4 and p3.startIndex == 10 and p3.statusInt == 0)
  check("StartIndex is one byte: 256 is answered as 0", p4.startIndex == 0 and #p4.binds == 3)
  local b = p1.binds[1]
  check(
    "a record: cluster, endpoints and the destination as a hex string",
    b.clusterId == 0x0702 and b.srcEndpoint == 2 and b.dstEndpoint == 3 and b.dstDeviceEuid == COORD
  )
  check("the status as a name and a number", p1.status == "ZDO_STATUS_SUCCESS" and p1.statusInt == 0)

  -- A sleepy device: zserver takes the read, and the device answers at its wake.
  zb:SendZdoGetBindTable(0)
  ctl.accept()
  check("asleep: queued, then in progress, and nothing more", #st == 14 and st[14][2] == 5 and #pages == 4, #st)
  ctl.deliver()
  check("at its wake: ok, then the page", #st == 15 and st[15][2] == 0 and #pages == 5)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: a device Director has not added, as measured")
--------------------------------------------------------------------------------
do
  local ctl = ShimInstallZigbeeV2()
  ctl.known = false
  local zb = C4:ZigbeeV2()
  local rid, rmsg = zb:SendZdoGetBindTable(0)
  check("a table read returns 0 and why", rid == 0 and rmsg == NOT_FOUND, rmsg)
  local sid, smsg = zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  check("and so does a Set", sid == 0 and smsg == NOT_FOUND, smsg)
  local cfg, cmsg = zb:GetZdoBindConfig()
  check("its bind list reads empty", type(cfg) == "table" and #cfg == 0 and cmsg == "")
  check("nothing was sent", #ctl.issued == 0 and ctl.syncs == 0)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: a bind list is stored, then pending, then synced, as measured")
--------------------------------------------------------------------------------
do
  -- Set returned 1 and "", pending about 5 ms later, then zserver read the table and
  -- synced. Given no endpoints, it moved Power Configuration to ep197 and bound
  -- 0xFCC0 at ep1: "1 to unbind, 2 to bind".
  local ctl = ShimInstallZigbeeV2()
  ctl.table = { rec(0x0001, 1, nil, 1), rec(0x0400, 3, nil, 1), rec(0x0402, 3, nil, 1), rec(0x0405, 3, nil, 1) }
  local zb = C4:ZigbeeV2()
  zb:Init()
  local cfg, cfgFn = recorder()
  local pages, pageFn = recorder()
  zb:OnZdoBindConfigStatusEvent(cfgFn)
  zb:OnZdoGetBindTableResponse(pageFn)
  local list = {}
  for i, c in ipairs({ 0x0001, 0x0400, 0x0402, 0x0405, 0xFCC0 }) do
    list[i] = { clusterId = c, srcEndpoint = 1 }
  end
  local ok, msg = zb:SetZdoBindConfig(list)
  check("Set returns 1 and an empty string", ok == 1 and msg == "", tostring(ok))
  check("no state before the call returns", #cfg == 0)
  local got = zb:GetZdoBindConfig()
  check(
    "Get returns Director's copy, as it was set",
    #got == 5 and got[5].clusterId == 0xFCC0 and got[5].dstEndpoint == nil
  )
  ctl.deliver(1)
  check("then pending", states(cfg) == "pending", states(cfg))
  ctl.deliver()
  check("each state is one table holding only the state", cfg[2].n == 1 and next(cfg[2][1], next(cfg[2][1])) == nil)
  check("then synced", states(cfg) == "pending,synced", states(cfg))
  check("zserver's own table read reached the driver's callback", #pages == 2 and pages[2][1].startIndex == 3)
  check(
    "Power Configuration moved to ep197, the rest untouched, 0xFCC0 bound at ep1",
    tableOf(ctl) == "0400/1>3,0402/1>3,0405/1>3,0001/1>197,FCC0/1>1",
    tableOf(ctl)
  )

  -- The same list again is skipped by Director, with no state.
  local sent = ctl.syncs
  check("the same list again returns 1", zb:SetZdoBindConfig(list) == 1)
  ctl.deliver()
  check("but nothing reaches zserver, and no state follows", ctl.syncs == sent and #cfg == 2)
  -- Removing one entry unbinds only its record.
  table.remove(list)
  zb:SetZdoBindConfig(list)
  ctl.deliver()
  check("a list without an entry unbinds that record alone", tableOf(ctl) == "0400/1>3,0402/1>3,0405/1>3,0001/1>197")
  check("pending, then synced again", states(cfg) == "pending,synced,pending,synced", states(cfg))
  local bad, bmsg = zb:SetZdoBindConfig({ { clusterId = 0, srcEndpoint = 1 } })
  check(
    "cluster 0 is refused, so Basic cannot be listed",
    bad == 0 and bmsg == "SetZdoBindConfig entry 1 invalid clusterId: 0"
  )
  check("and nothing of it was stored", #zb:GetZdoBindConfig() == 4)
  T.raises("an EUI64 zserver cannot read as a number is not modelled", function()
    zb:SetZdoBindConfig({ { clusterId = 6, srcEndpoint = 1, dstEndpoint = 1, dstDeviceEuid = "bulb" } })
  end, "16 hex digits")
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: DoorLock goes to the coordinator's ep2, and a named EUI64 is kept as given")
--------------------------------------------------------------------------------
do
  -- An entry that named no destination was held with the coordinator in lower case; one
  -- that named it in upper case after that was sent and synced with nothing to do, and
  -- then one naming none matched it and was skipped. zserver binds a named entry the
  -- table lacks where it names.
  local ctl = ShimInstallZigbeeV2()
  local zb = C4:ZigbeeV2()
  zb:Init()
  zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  ctl.deliver()
  check("DoorLock bound at the endpoint that models locks", tableOf(ctl) == "0101/2>2", tableOf(ctl))
  check("left out, the coordinator is held in lower case", ctl.held[1].dstDeviceEuid == COORD:lower())
  local n = ctl.syncs
  zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2, dstDeviceEuid = COORD } })
  ctl.deliver()
  check(
    "named in upper case it is sent, and zserver finds nothing to do",
    ctl.syncs == n + 1 and tableOf(ctl) == "0101/2>2" and ctl.state == "synced"
  )
  zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  check("an entry that names none matches it, and is skipped", ctl.syncs == n + 1)
  zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2, dstDeviceEuid = COORD:lower() } })
  ctl.deliver()
  check("named in lower case after upper, it is sent again", ctl.syncs == n + 2 and tableOf(ctl) == "0101/2>2")
  local named = { { clusterId = DOORLOCK, srcEndpoint = 2, dstEndpoint = 11, dstDeviceEuid = BULB } }
  zb:SetZdoBindConfig(named)
  ctl.deliver()
  check(
    "a named entry the table lacks is bound where it names, and the old record unbound",
    tableOf(ctl) == "0101/2>11@" .. BULB,
    tableOf(ctl)
  )
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: zserver unbinds every record the list lacks, then binds in list order")
--------------------------------------------------------------------------------
do
  -- A Basic bind, a stale record and a device-to-device bind: a list without them
  -- unbinds all three.
  local ctl = ShimInstallZigbeeV2()
  ctl.table = { rec(0x0000, 1), rec(DOORLOCK, 2, OLD_COORD), rec(0x0006, 1, "4CE175B4C3970000") }
  local zb = C4:ZigbeeV2()
  zb:Init()
  zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  ctl.deliver()
  check("the rest unbound, and DoorLock bound to this coordinator", tableOf(ctl) == "0101/2>2", tableOf(ctl))
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: a refused bind disables the list until it changes, as measured")
--------------------------------------------------------------------------------
do
  -- srcEp 9 drew INVALID_ENDPOINT, the list was disabled, and the good entry after it
  -- was never bound; the same list again was skipped, and a changed one synced.
  local ctl = ShimInstallZigbeeV2()
  ctl.answers[9 * 65536 + DOORLOCK] = 0x82
  local zb = C4:ZigbeeV2()
  zb:Init()
  local cfg, cfgFn = recorder()
  zb:OnZdoBindConfigStatusEvent(cfgFn)
  local list = { { clusterId = 0x0006, srcEndpoint = 1 }, { clusterId = DOORLOCK, srcEndpoint = 9 } }
  list[3] = { clusterId = DOORLOCK, srcEndpoint = 2 }
  zb:SetZdoBindConfig(list)
  ctl.deliver()
  check("disabled", states(cfg) == "pending,disabled", states(cfg))
  check("the entries before it bound, the one after it not", tableOf(ctl) == "0006/1>1", tableOf(ctl))
  zb:SetZdoBindConfig(list)
  ctl.deliver()
  check("the same list again: skipped, still disabled", #cfg == 2 and ctl.state == "disabled")
  table.remove(list, 2)
  zb:SetZdoBindConfig(list)
  ctl.deliver()
  check(
    "a changed list syncs",
    states(cfg) == "pending,disabled,pending,synced" and tableOf(ctl) == "0006/1>1,0101/2>2"
  )
  ctl.answers[9 * 65536 + DOORLOCK] = 0x8C
  T.raises("a status zserver retries is not modelled", function()
    zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 9 } })
    ctl.deliver()
  end, "retries on a timer")
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: a sleepy device's sync waits for its wake, and a new list replaces it")
--------------------------------------------------------------------------------
do
  local ctl = ShimInstallZigbeeV2()
  ctl.table = { rec(0x0001, 197), rec(DOORLOCK, 2) }
  ctl.asleep = true
  local zb = C4:ZigbeeV2()
  zb:Init()
  local cfg, cfgFn = recorder()
  zb:OnZdoBindConfigStatusEvent(cfgFn)
  zb:SetZdoBindConfig({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  ctl.deliver()
  check("pending at once, and the table untouched while it sleeps", states(cfg) == "pending" and #ctl.table == 2)
  T.raises("a table read while zserver syncs corrupts it", function()
    zb:SendZdoGetBindTable(0)
  end, "while zserver syncs")
  check("and is noted, which a caller's pcall cannot hide", ctl.corrupted == true)
  zb:SetZdoBindConfig({ { clusterId = 0x0001, srcEndpoint = 2 }, { clusterId = DOORLOCK, srcEndpoint = 2 } })
  ctl.asleep = false
  ctl.deliver()
  check("at its wake only the newer list runs", tableOf(ctl) == "0001/2>197,0101/2>2", tableOf(ctl))
  check("pending for each list, synced once", states(cfg) == "pending,pending,synced", states(cfg))
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("the shim: after a Director restart, Director sends an empty list, as measured")
--------------------------------------------------------------------------------
do
  -- Director lost its lists and sent an empty one at addZ3Node and on ONLINE, and
  -- zserver began unbinding everything. The drivers' Sets, 0.4 to 1 s after addZ3Node,
  -- were compared with the list zserver published before the empty one and skipped;
  -- at a reload 6 minutes later the same Sets were sent. Each driver first heard the
  -- state zserver kept, 0.04 to 0.63 s after its Set.
  local ctl = ShimInstallZigbeeV2()
  local zb = C4:ZigbeeV2()
  zb:Init()
  local cfg, cfgFn = recorder()
  zb:OnZdoBindConfigStatusEvent(cfgFn)
  local list = { { clusterId = DOORLOCK, srcEndpoint = 2 } }
  zb:SetZdoBindConfig(list)
  ctl.deliver()
  check("bound", tableOf(ctl) == "0101/2>2")
  ctl.restart()
  ctl.known = true -- Director has the device again at addZ3Node
  ctl.online()
  zb:SetZdoBindConfig(list)
  check("the same list before zserver published the empty one is skipped", ctl.syncs == 2)
  ctl.deliver()
  check(
    "the synced zserver kept comes first, then the empty list's pending",
    states(cfg) == "pending,synced,synced,pending,synced",
    states(cfg)
  )
  check("the empty list unbinds it", #ctl.table == 0 and ctl.state == "synced")
  zb:SetZdoBindConfig(list)
  check("after it, the same list is sent", ctl.syncs == 3)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("one object for the driver's life, Init()ed once with three callbacks")
--------------------------------------------------------------------------------
do
  local ctl, ZV2 = fresh()
  local obj = ZV2:object()
  check("the object", obj ~= nil and ZV2:object() == obj and ctl.made == 1, ctl.made)
  check("the object alone needs no Init()", ctl.inits == 0)
  check("a read goes", ZV2:readTable(0) ~= nil)
  ctl.deliver()
  check("a list goes", ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } }) == true)
  check("Init()ed once, on one object", ctl.inits == 1 and ctl.made == 1)
  local names = {}
  for name in pairs(ctl.calls) do
    names[#names + 1] = name
  end
  table.sort(names)
  check(
    "only Init, the three callbacks, the Set and the read",
    table.concat(names, ",")
      == "Init,OnZdoBindConfigStatusEvent,OnZdoGetBindTableResponse,OnZdoSentStatus,SendZdoGetBindTable,SetZdoBindConfig",
    table.concat(names, ",")
  )
  -- The module holds the object, so a full collection leaves its callbacks in place.
  collectgarbage()
  collectgarbage()
  local heard = {}
  ZV2:onState(function(state)
    heard[#heard + 1] = state
  end)
  ctl.deliver()
  check(
    "the object survives a collection, and the list's states are handed on",
    table.concat(heard, ",") == "pending,synced"
  )
  ZV2:onState(nil)
  ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 1 } })
  ctl.deliver()
  check("and not to a listener that stopped", #heard == 2)
  ShimRemoveZigbeeV2()

  KillAllTimers()
  T.unload("^zigbee%.")
  local none = require("zigbee.zv2")
  check("no C4:ZigbeeV2: no object", none:object() == nil)
  check("and no list", none:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } }) == false)
  check("nor read", none:readTable(0) == nil)
end

--------------------------------------------------------------------------------
T.section("a state heard while nobody listens goes to the next listener")
--------------------------------------------------------------------------------
do
  local ctl, ZV2 = fresh()
  local heard = {}
  local function listen(state)
    heard[#heard + 1] = tostring(state)
  end
  ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  ctl.deliver()
  ZV2:onState(listen)
  check(
    "the last state heard goes to the next listener",
    table.concat(heard, ",") == "synced",
    table.concat(heard, ",")
  )
  ZV2:onState(listen)
  check("once", #heard == 1)
  ZV2:onState(nil)
  ctl.asleep = true
  ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 1 } })
  ctl.deliver()
  ZV2:onState(listen)
  ctl.asleep = false
  ctl.deliver()
  check(
    "a sleepy device's pending too, and what follows goes straight to it",
    table.concat(heard, ",") == "synced,pending,synced",
    table.concat(heard, ",")
  )
  ZV2:onState(nil)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("an Init() that fails is tried again, not remembered")
--------------------------------------------------------------------------------
do
  -- Init() returns 1 while the controller's Zigbee manager is not up (the host's own
  -- check); played on the object itself, since it was never seen live.
  local ctl, ZV2 = fresh()
  local obj = ZV2:object()
  rawset(obj, "Init", function()
    return 1
  end)
  local ok, why = ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  check("no list while Init() fails", ok == false and why == "the Zigbee API is unavailable", why)
  rawset(obj, "Init", nil)
  check("the next call Init()s and goes", ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } }) == true)
  check("on the same object", ctl.inits == 1 and ctl.made == 1 and ctl.syncs == 1)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("a list is never empty and holds only what the API takes")
--------------------------------------------------------------------------------
do
  local ctl, ZV2 = fresh()
  for _, case in ipairs({
    { nil, "no list" },
    { {}, "an empty list" },
    { { { clusterId = 0, srcEndpoint = 2 } }, "Basic" },
    { { { clusterId = 0x10000, srcEndpoint = 2 } }, "a cluster past 16 bits" },
    { { { clusterId = DOORLOCK, srcEndpoint = 0 } }, "source endpoint 0" },
    { { { clusterId = DOORLOCK, srcEndpoint = 242 } }, "Green Power's endpoint" },
    { { { clusterId = 6.5, srcEndpoint = 2 } }, "a cluster that is no integer" },
    { { { clusterId = DOORLOCK, srcEndpoint = 2, dstEndpoint = 0, dstDeviceEuid = BULB } }, "destination endpoint 0" },
    { { { clusterId = DOORLOCK, srcEndpoint = 2, dstDeviceEuid = "1788010BADBEEF" } }, "a short EUI64" },
    { { { clusterId = DOORLOCK, srcEndpoint = 2, dstDeviceEuid = "001788010BADBEEG" } }, "one not hex" },
  }) do
    local ok, why = ZV2:setList(case[1])
    check(case[2] .. " is not set, and says why", ok == false and type(why) == "string")
  end
  check("none reached the API", (ctl.calls.SetZdoBindConfig or 0) == 0 and ctl.inits == 0)
  -- The API's own refusal comes back as it gave it: played on the object, since the
  -- driver's checks keep every measured refusal from reaching it.
  rawset(ZV2:object(), "SetZdoBindConfig", function()
    return 0, "SetZdoBindConfig entry 2 invalid srcEndpoint: 0"
  end)
  local ok, why = ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  check(
    "a Set the API refuses is not set",
    ok == false and why == "SetZdoBindConfig entry 2 invalid srcEndpoint: 0",
    why
  )
  rawset(ZV2:object(), "SetZdoBindConfig", function()
    error("host error")
  end)
  check("nor one that raises", ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } }) == false)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("a read takes its own page: by StartIndex, once zserver has taken it")
--------------------------------------------------------------------------------
do
  local ctl, ZV2 = fresh()
  ctl.table = { rec(DOORLOCK, 2), rec(0x0702, 3), rec(0x0B04, 2), rec(0x0006, 1, OLD_COORD, 3) }
  local pages, fails = {}, 0
  local function onPage(p)
    pages[#pages + 1] = p
  end
  local function onFail()
    fails = fails + 1
  end
  local function read(at)
    ZV2:readTable(at):next(onPage, onFail)
  end
  read(0)
  ctl.deliver()
  read(3)
  ctl.deliver()
  check("three records, more to come", pages[1].count == 3 and pages[1].atEnd == false)
  local r = pages[1].records[2]
  check("a record", r.srcEp == 2 and r.cluster == 0x0702 and r.dstEp == 3 and r.dst == COORD)
  check(
    "the last one ends the table",
    pages[2].count == 1 and pages[2].atEnd == true and pages[2].records[1].dst == OLD_COORD
  )
  read(4)
  ctl.deliver()
  check("an empty page ends it too", pages[3].count == 0 and pages[3].atEnd == true)

  -- zserver's own pages reach the callback during its sync; none is taken for a read.
  local cb = ctl.cb()
  local function page(at)
    return { status = "ZDO_STATUS_SUCCESS", statusInt = 0, entries = 4, startIndex = at, binds = {} }
  end
  cb.table(page(0))
  check("a page with no read out is nobody's", #pages == 3 and fails == 0)
  read(0)
  local cmd = table.remove(ctl.queue, 1)
  cb.table(page(0))
  check("nor one before zserver has taken the read", #pages == 3)
  cb.status(cmd.cid, 61445, "ZSTATUS_QUEUE_RECEIVED")
  cb.table(page(3))
  cb.table({ status = "ZDO_STATUS_SUCCESS", statusInt = 0, entries = 4, binds = {} })
  check("nor one for another StartIndex, or none", #pages == 3 and fails == 0)
  cb.status(cmd.cid + 4294967296, 0, "ZSTATUS_OK")
  check("another command's status moves nothing", armedFor.ZV2Read == ZV2.CMD_TAKE_MS)
  cb.status(cmd.cid, 5, "ZSTATUS_IN_PROGRESS")
  cb.table(page(0))
  check("its own page, before its ok, is taken", #pages == 4 and fails == 0)
  cb.status(cmd.cid, 0, "ZSTATUS_OK")
  cb.table(page(0))
  check("and its late ok or a second copy changes nothing", #pages == 4 and fails == 0 and Timer.ZV2Read == nil)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("a read that gets no page in time, or a failure, fails")
--------------------------------------------------------------------------------
do
  local ctl, ZV2 = fresh()
  local fails = 0
  local function onFail()
    fails = fails + 1
  end
  local function read(at)
    ZV2:readTable(at):next(function() end, onFail)
  end
  read(0)
  check("sent, and zserver given its time to take it", armedFor.ZV2Read == ZV2.CMD_TAKE_MS)
  ctl.accept()
  check("taken: still waiting", Timer.ZV2Read ~= nil and fails == 0)
  fire("ZV2Read")
  check("no status in time: it fails", fails == 1)
  local cb = ctl.cb()
  ctl.silence()
  read(0)
  local cid = ctl.issued[#ctl.issued].cid
  cb.status(cid, 0, "ZSTATUS_OK")
  check("ok: the page is waited for a short while", armedFor.ZV2Read == ZV2.CMD_WAIT_MS)
  fire("ZV2Read")
  check("then it fails", fails == 2)
  read(0)
  cid = ctl.issued[#ctl.issued].cid
  cb.status(cid, 3104, "ZSTATUS_ZIGBEE_NO_APS_ACK")
  check("a delivery failure fails it at once", fails == 3 and Timer.ZV2Read == nil)
  read(0)
  cid = ctl.issued[#ctl.issued].cid
  cb.status(cid, 5, "ZSTATUS_IN_PROGRESS")
  -- A device that refuses the read: not measured, so played by hand.
  cb.table({ status = "ZDO_STATUS_NOT_SUPPORTED", statusInt = 132, startIndex = 0, entries = 0, binds = {} })
  check("a refused read fails at once", fails == 4 and Timer.ZV2Read == nil)

  local first, replaced, second = 0, 0, 0
  ZV2:readTable(0):next(function()
    first = first + 1
  end, function()
    replaced = replaced + 1
  end)
  ZV2:readTable(0):next(function()
    second = second + 1
  end, onFail)
  ctl.deliver()
  check(
    "a new read replaces one still out, which fails",
    first == 0 and replaced == 1 and second == 1 and fails == 4,
    first .. "/" .. replaced .. "/" .. second
  )

  ctl.known = false
  check("a read the API does not send says so", ZV2:readTable(0) == nil and fails == 4)
  ShimRemoveZigbeeV2()
end

--------------------------------------------------------------------------------
T.section("a handler that raises is contained")
--------------------------------------------------------------------------------
do
  local ctl, ZV2 = fresh()
  ZV2:onState(function()
    error("boom")
  end)
  ZV2:setList({ { clusterId = DOORLOCK, srcEndpoint = 2 } })
  local ok = pcall(ctl.deliver)
  check("a state handler that raises reaches no caller", ok)
  local pages = 0
  ZV2:readTable(0):next(function()
    pages = pages + 1
    error("boom")
  end)
  ok = pcall(ctl.deliver)
  check("nor does a page handler", ok and pages == 1 and Timer.ZV2Read == nil)
  ZV2:onState(nil)
  ShimRemoveZigbeeV2()
end

T.finish()
