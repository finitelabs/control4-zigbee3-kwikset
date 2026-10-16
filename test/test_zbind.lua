-- The bind list of src/zigbee3/zbind.lua, over src/zigbee3/zv2.lua and the ZigbeeV2
-- shim in c4_local.lua, which plays zserver, Director and the device as a 4.3.0
-- controller was measured to (test_zv2.lua holds the shim to those measurements).
--
-- Run from the driver root:
--   make test
--
-- The paths a device takes:
--   1. A fresh pair: the list is set, zserver syncs it, and the coordinator is read
--      from the table once, after zserver's own read. Where a coordinator is known,
--      the table is read before the first list, and what points at another device
--      is carried in it, except while zserver may sync a re-paired device's old list.
--   2. A reload: an unchanged list costs nothing, and what the last load learned
--      shows at once; another device's list is not taken.
--   3. A Director restart: the list is set again as soon as Director has the device,
--      the coordinator spelled the other way so Director sends it, replacing the empty
--      list Director pushes before zserver acts on it; a state other than pending is
--      taken once none follows it, since the one zserver kept and the empty list's
--      come first.
--   4. A disabled list: the table names the entry the device refused, which is
--      polled, and the rest is set again; a record to another device is carried
--      instead, and a table holding anything else names none.
--   5. A rejoin: a device that came back with an empty table gets its list again,
--      the coordinator spelled the other way so Director sends it.
--   6. A target that names its coordinator endpoint is bound there and set again when
--      it moves; its refusal is named as any other's, and one out of range never goes.
--   7. A read that got no page is asked again when the device next speaks, and a
--      list zserver leaves pending is set again two hours after a frame.
--   8. Nothing is read while zserver syncs (the last section checks every path above),
--      no list is set while a read is out, and what the list cannot hold is never sent.

require("c4_shim")
require("c4_local") -- driver-local seams, including the ZigbeeV2 shim
require("drivers-common-public.global.timer") -- Timer / TimerFunctions / KillAllTimers

-- The binder runs over the real lib.persist and the shim's C4 store, so what is kept
-- is what a reload reads back. The store reads a write back only after the call that
-- made it, so every place the test stands between two calls lands the writes.
local persist = require("lib.persist")
local seeded = {}
--- Seed the store as a load finds it, with lib.persist's cache emptied.
local function setStore(t)
  ShimPersistLand()
  for k in pairs(persist._persist) do
    seeded[k] = true
  end
  for k in pairs(seeded) do
    C4:PersistDeleteValue(k)
  end
  seeded = {}
  for k, v in pairs(t or {}) do
    seeded[k] = true
    C4:PersistSetValue(k, Serialize(v), false)
  end
  ShimPersistLand()
  persist._persist = {}
end
--- What the store holds under a key, as lib.persist decodes it.
local function stored(key)
  ShimPersistLand()
  return Deserialize(C4:PersistGetValue(key, false))
end

local logging = require("lib.logging")
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  if type(logging[m]) == "function" then
    logging[m] = function() end
  end
end

local T = require("testlib")
local check = T.check

local EUI = "00124B0001AABBCC"
local COORD = "00124B0001CE4B21" -- the shim's coordinator
local OLD_COORD = "00124B0001CE4B99"
local BULB = "001788010BADBEEF"
-- An earlier load set this device's list, so nothing is read before the next.
local SET_BEFORE = { zbindList = { eui = EUI } }
-- An FP300's: Power Configuration, Temperature, and the Lumi cluster SendZdoBind refuses.
local TARGETS = { { srcEp = 1, cluster = 0x0001 }, { srcEp = 1, cluster = 0x0402 }, { srcEp = 1, cluster = 0xFCC0 } }
local BOUND = "0001/1>197,0402/1>3,FCC0/1>1"
local function key(srcEp, cluster)
  return srcEp * 65536 + cluster
end

--- A binding-table record as the device holds it.
local function rec(cluster, dstEp, dst, srcEp)
  return { clusterId = cluster, srcEndpoint = srcEp or 1, dstEndpoint = dstEp, dstDeviceEuid = dst or COORD }
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

--- A set of keys as "k,k", sorted.
local function keys(set)
  local out = {}
  for k in pairs(set or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return table.concat(out, ",")
end

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
  ShimPersistLand()
  fn(h, 0)
  return true
end

--- The driver's modules loaded again, as a reload has them; the controller stays.
local function load()
  KillAllTimers()
  T.unload("^zigbee3%.")
  return require("zigbee3.zbind")
end

-- Every controller fresh() made, for the last section.
local controllers = {}

--- A newly loaded driver over a store seeded with `seed` and a device holding `records`.
local function fresh(seed, records)
  setStore(seed)
  local ctl = ShimInstallZigbeeV2()
  controllers[#controllers + 1] = ctl
  for i, r in ipairs(records or {}) do
    ctl.table[i] = r
  end
  return ctl, load()
end

--- The driver loaded again over what the last load stored.
local function reload()
  ShimPersistLand()
  persist._persist = {}
  return load()
end

--- A binder for the device at `eui` (EUI by default) on controller 20, as Device makes
--- it, `stale` after a load that was not a driver update; `heard` gets each hook's
--- settled flag.
local function binder(ZBind, fallback, eui, stale)
  local zb = ZBind:new(stale)
  zb.address = function()
    return eui or EUI
  end
  zb.zserverId = function()
    return 20
  end
  zb.coordFallback = function()
    return fallback
  end
  local heard = {}
  zb.hookFn = function(settled)
    heard[#heard + 1] = tostring(settled)
  end
  return zb, heard
end

--- Apply `targets` (TARGETS by default) as Device does.
local function apply(zb, targets)
  zb:apply(targets or TARGETS, zb.hookFn)
end

--- The table reads the driver sent, as their StartIndex, comma-joined.
local function reads(ctl)
  local out = {}
  for _, c in ipairs(ctl.issued) do
    out[#out + 1] = tostring(c.startIndex)
  end
  return table.concat(out, ",")
end

--------------------------------------------------------------------------------
T.section("a fresh pair: the list is set, zserver syncs it, and the table names the coordinator")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb, heard = binder(ZBind)
  apply(zb)
  check("the list went, in the targets' order", ctl.syncs == 1 and #ctl.list == 3 and ctl.list[3].clusterId == 0xFCC0)
  check("with no destination: zserver fills in the coordinator", ctl.list[1].dstEndpoint == nil)
  check("with no coordinator known, nothing is read before zserver has synced", #ctl.issued == 0)
  ctl.deliver(1)
  local snap = zb:snapshot()
  check("pending", snap.state == "pending" and heard[1] == "false", snap.state)
  local all = keys({ [key(1, 0x0001)] = true, [key(1, 0x0402)] = true, [key(1, 0xFCC0)] = true })
  check("every entry listed, none bound yet", keys(snap.listed) == all and next(snap.bound) == nil)
  ctl.deliver(1) -- zserver's sync
  check("zserver bound every entry, 0xFCC0 at its ep1", tableOf(ctl) == BOUND, tableOf(ctl))
  check(
    "synced, and the table read once, after zserver's own read",
    zb:snapshot().state == "synced" and reads(ctl) == "0",
    reads(ctl)
  )
  check("a read is in flight", zb:isActive())
  ctl.deliver()
  snap = zb:snapshot()
  check("the coordinator the listed records name", snap.coordEui == COORD, tostring(snap.coordEui))
  check("kept, with its controller", stored("zbindCoordEui") == COORD and stored("zbindCoordZserver") == 20)
  check("every entry bound", keys(snap.bound) == keys(snap.listed) and snap.at ~= nil)
  check(
    "the hook heard pending, synced, and the read's end, settled",
    table.concat(heard, ",") == "false,true,true",
    table.concat(heard, ",")
  )
  local list = stored("zbindList")
  check(
    "the list's record is kept for this device",
    list.eui == EUI and #list.bound == 3 and #list.refused == 0 and list.state == "synced" and list.at == snap.at
  )
  check("no read left in flight", not zb:isActive() and #ctl.queue == 0)
end

--------------------------------------------------------------------------------
T.section("before a device's first list, its bindings to other devices are read and carried")
--------------------------------------------------------------------------------
do
  -- A remote already bound to the coordinator, whose table also holds an installer's
  -- binding to a bulb and a Basic record.
  local remote = { { srcEp = 1, cluster = 0x0006 } }
  local ctl, ZBind = fresh({ zbindCoordEui = COORD }, { rec(0x0000, 1), rec(0x0006, 1), rec(0x0006, 11, BULB) })
  local zb = binder(ZBind)
  apply(zb, remote)
  check("the table is read first, and no list set yet", reads(ctl) == "0" and ctl.syncs == 0 and zb:isActive())
  ctl.deliver(1)
  check(
    "then the list, naming the binding to the bulb in full",
    ctl.syncs == 1 and #ctl.list == 2 and ctl.list[2].dstEndpoint == 11 and ctl.list[2].dstDeviceEuid == BULB
  )
  ctl.deliver()
  check("zserver kept it, and removed only Basic", tableOf(ctl) == "0006/1>1,0006/1>11@" .. BULB, tableOf(ctl))
  check("carried in the record for the next load", #stored("zbindList").carried == 1)

  -- A reboot: Director and zserver hold no list, so the next load's Set is a change.
  ctl.list, ctl.held, ctl.published = nil, {}, {}
  ZBind = reload()
  local again = binder(ZBind)
  apply(again, remote)
  check("after a reboot the list goes unread, and carries it", reads(ctl) == "0" and #ctl.list == 2)
  ctl.deliver()
  check("so nothing is unbound", tableOf(ctl) == "0006/1>1,0006/1>11@" .. BULB, tableOf(ctl))

  -- A rejoin's read of the whole table carries what the device holds then.
  local LAMP = "0017880100C0FFEE"
  ctl.table = { rec(0x0006, 1), rec(0x0006, 11, LAMP), rec(0x0008, 11, LAMP), rec(0x0008, 11, BULB) }
  again:check()
  fire("ZBindCheck")
  ctl.deliver(2)
  local carried = stored("zbindList").carried
  check(
    "a rejoin reads every page, and carries what the device holds, not one unbound by hand",
    reads(ctl) == "0,0,3" and #carried == 3 and carried[3].cluster == 0x0008 and carried[3].dst == BULB,
    reads(ctl)
  )
  ctl.deliver()
  check(
    "the list set again keeps them",
    tableOf(ctl) == "0006/1>1,0006/1>11@" .. LAMP .. ",0008/1>11@" .. LAMP .. ",0008/1>11@" .. BULB,
    tableOf(ctl)
  )

  -- A sleepy remote's read that got no page: no list until a frame reads it again.
  -- A record the list cannot name (endpoint 0) is not carried.
  ctl, ZBind = fresh({ zbindCoordEui = COORD }, { rec(0x0006, 11, BULB), rec(0x0008, 0, BULB) })
  zb = binder(ZBind)
  apply(zb, remote)
  ctl.silence()
  fire("ZV2Read")
  check("no page: still no list", ctl.syncs == 0 and not zb:isActive())
  zb:wake()
  ctl.deliver()
  check(
    "the next frame reads it, and the list carries the binding",
    reads(ctl) == "0,0" and tableOf(ctl) == "0006/1>11@" .. BULB .. ",0006/1>1",
    tableOf(ctl)
  )

  -- 604 heard unknown before its first list (09-25 13:54), which kept no record.
  ctl, ZBind = fresh({ zbindCoordEui = COORD }, { rec(0x0006, 1), rec(0x0006, 11, BULB) })
  apply(binder(ZBind), remote)
  ctl.silence()
  fire("ZV2Read")
  ctl.cb().config({ state = "unknown" })
  ZBind = reload()
  apply(binder(ZBind), remote)
  ctl.deliver()
  check(
    "a state before the first list: the next load still reads first, and carries the binding",
    reads(ctl) == "0,0" and tableOf(ctl) == "0006/1>1,0006/1>11@" .. BULB,
    tableOf(ctl)
  )

  -- A list whose state has not come yet was set: the next load reads nothing first.
  ctl, ZBind = fresh({ zbindCoordEui = COORD })
  apply(binder(ZBind), remote)
  ctl.deliver(1)
  ZBind = reload()
  apply(binder(ZBind), remote)
  check("a list set is known at the next load before its state comes", ctl.calls.SendZdoGetBindTable == 1)

  -- A re-pair: Director gives the new node the old list first, and a read while zserver
  -- syncs it would take its page.
  ctl, ZBind = fresh({ zbindCoordEui = COORD }, { rec(0x0006, 1), rec(0x0006, 11, BULB) })
  zb = binder(ZBind)
  apply(zb, remote)
  ctl.deliver()
  zb:close()
  local new = binder(ZBind, nil, "00124B0001DDEEFF")
  ctl.table, ctl.held, ctl.published = {}, {}, {}
  ctl.online()
  ctl.deliver(1)
  apply(new, remote)
  check("a first list while zserver syncs another is set unread", reads(ctl) == "0" and #ctl.list == 1)
  ctl.deliver()
  check("and replaces it", tableOf(ctl) == "0006/1>1" and new:snapshot().state == "synced", tableOf(ctl))

  -- A sleepy device's re-pair: its binder is made only after the interview, when the
  -- pending has come and the sync waits for the device to wake.
  ctl, ZBind = fresh({ zbindCoordEui = COORD }, { rec(0x0006, 1), rec(0x0006, 11, BULB) })
  zb = binder(ZBind)
  apply(zb, remote)
  ctl.deliver()
  zb:close()
  ctl.table, ctl.held, ctl.published = {}, {}, {}
  ctl.asleep = true
  ctl.online()
  ctl.deliver()
  new = binder(ZBind, nil, "00124B0001DDEEFF")
  apply(new, remote)
  check(
    "a pending heard before the binder was made: the first list is set unread",
    reads(ctl) == "0" and #ctl.list == 1
  )
  ctl.asleep = false
  ctl.deliver()
  check("and replaces it at the wake", tableOf(ctl) == "0006/1>1" and new:snapshot().state == "synced", tableOf(ctl))

  -- A driver update in between: the new Lua state heard no pending, but the record still
  -- names the old device.
  ctl, ZBind = fresh({ zbindCoordEui = COORD }, { rec(0x0006, 1), rec(0x0006, 11, BULB) })
  apply(binder(ZBind), remote)
  ctl.deliver()
  ctl.table, ctl.held, ctl.published = {}, {}, {}
  ctl.asleep = true
  ctl.online()
  ctl.deliver()
  ZBind = reload()
  new = binder(ZBind, nil, "00124B0001DDEEFF")
  apply(new, remote)
  check("a load before a re-paired device's first list sets it unread", reads(ctl) == "0" and #ctl.list == 1)
  ctl.asleep = false
  ctl.deliver()
  check("and it replaces Director's at the wake", tableOf(ctl) == "0006/1>1", tableOf(ctl))
end

--------------------------------------------------------------------------------
T.section("a reload: an unchanged list costs nothing, and the last load's record shows at once")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  ZBind = reload()
  local again, heard = binder(ZBind)
  local snap = again:snapshot()
  check(
    "the last load's bound entries, state and time",
    keys(snap.bound) ~= "" and snap.state == "synced" and snap.at ~= nil
  )
  local calls, syncs = ctl.calls.SetZdoBindConfig, ctl.syncs
  apply(again)
  check("the list is set again, and Director skips it", ctl.calls.SetZdoBindConfig == calls + 1 and ctl.syncs == syncs)
  check("so no state comes, and nothing is read", #ctl.queue == 0 and #heard == 0 and reads(ctl) == "0")
  apply(again)
  check("the same list later in the session is not set at all", ctl.calls.SetZdoBindConfig == calls + 1)
  apply(again, { TARGETS[1], TARGETS[2] })
  ctl.deliver()
  check("a changed list is", ctl.syncs == syncs + 1 and tableOf(ctl) == "0001/1>197,0402/1>3", tableOf(ctl))
  check("and what it dropped is no longer bound", again:snapshot().bound[key(1, 0xFCC0)] == nil)

  -- A re-pair: the record names the device it was kept for.
  ZBind = reload()
  local other = binder(ZBind, nil, "00124B0001DDEEFF")
  check("another device's record is not taken", next(other:snapshot().bound) == nil and other:snapshot().state == nil)
end

--------------------------------------------------------------------------------
T.section("a Director restart: the list is set again, spelled the other way, once Director has the device")
--------------------------------------------------------------------------------
do
  -- 09-25 13:54: Director lost its lists; the driver's calls failed until addZ3Node,
  -- where Director pushed an empty list, and the driver's Set 0.4 to 1 s later was
  -- compared with the list zserver published before it, so it was skipped.
  local ctl, ZBind = fresh({ zbindCoordEui = COORD })
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  local before = keys(zb:snapshot().bound)
  ctl.restart()
  ZBind = reload()
  local again = binder(ZBind, nil, nil, true)
  apply(again)
  again.at = "before"
  check("not found: tried again in a second", armedFor.ZBindApply == 1000 and again:isActive())
  fire("ZBindApply")
  check("and again", armedFor.ZBindApply == 1000 and Timer.ZBindApply ~= nil)
  again.retrySince = again.retrySince - 301
  fire("ZBindApply")
  check("every minute once five have passed", armedFor.ZBindApply == 60000)
  ctl.known = true
  ctl.online() -- Director's empty list at addZ3Node, not yet published
  fire("ZBindApply")
  check(
    "the next try sets the list, the coordinator spelled out, so Director sends it",
    ctl.syncs == 3 and ctl.list[1].dstDeviceEuid == COORD and not again:isActive()
  )
  check("and no state is taken for it until one comes", Timer.ZBindSettle == nil)
  -- 16:59: the synced zserver kept for the list before came first, then the empty
  -- list's pending and this list's; 674's own sync waited for its wake. On 09-29 each
  -- device's ONLINE added it again first, and Director sent this list once more.
  ctl.asleep = true
  ctl.deliver()
  check("the second add sends this list again: one pending more", ctl.syncs == 4 and #ctl.queue == 1, ctl.syncs)
  local snap = again:snapshot()
  check(
    "the synced zserver kept is not this list's: pending, nothing bound",
    snap.state == "pending" and next(snap.bound) == nil and snap.at == "before" and Timer.ZBindSettle == nil
  )
  ctl.asleep = false
  ctl.deliver()
  check(
    "which replaced the empty one before zserver acted on it: nothing was unbound",
    tableOf(ctl) == BOUND,
    tableOf(ctl)
  )
  check(
    "its synced is taken once no state follows it",
    again:snapshot().state == "pending" and armedFor.ZBindSettle == 10000
  )
  fire("ZBindSettle")
  check("synced, and bound", again:snapshot().state == "synced" and again:snapshot().at ~= "before")
  check("and kept as spelled, so the next restart spells it the other way", stored("zbindList").form == "upper")

  -- Director's own states before the list goes are not the driver's.
  ctl.restart()
  ZBind = reload()
  local later, heard = binder(ZBind, nil, nil, true)
  apply(later)
  ctl.known = true
  ctl.online()
  ctl.deliver(3) -- the second add, the synced zserver kept, and the empty list's pending
  check(
    "Director's own pending shows, after the synced zserver kept",
    later:snapshot().state == "pending" and table.concat(heard, ",") == "false,false"
  )
  later:wake()
  later.pendingHeard = os.time() - 7200
  later:wake()
  check("and is not the driver's to set again", ctl.syncs == 6)
  local n = #ctl.issued
  ctl.cb().config({ state = "synced" }) -- as if its empty list had synced
  check("nor moves anything bound, and nothing is read", keys(later:snapshot().bound) == before and #ctl.issued == n)
  fire("ZBindApply")
  ctl.deliver()
  check("the list set then is spelled in lower case", ctl.syncs == 7 and ctl.list[1].dstDeviceEuid == COORD:lower())
  check("and replaces the empty one", tableOf(ctl) == BOUND, tableOf(ctl))

  -- A driver update before Director has the device: its Set is refused as well.
  ctl.restart()
  ZBind = reload()
  local early = binder(ZBind)
  apply(early)
  ctl.known = true
  ctl.online()
  fire("ZBindApply")
  ctl.deliver()
  check(
    "a Set refused after a driver update is spelled the other way too",
    ctl.syncs == 10 and ctl.list[1].dstDeviceEuid == COORD and tableOf(ctl) == BOUND,
    tableOf(ctl)
  )

  -- After a reboot 619 heard unknown between its Set and its pending, and the empty list
  -- could end, synced or disabled, before zserver takes this one: none is this list's.
  ctl.restart()
  ZBind = reload()
  local held, heardHeld = binder(ZBind, nil, nil, true)
  apply(held)
  ctl.known = true
  ctl.online()
  fire("ZBindApply")
  ctl.cb().config({ state = "unknown" })
  check("an unknown after the Set does not show", held:snapshot().state == nil and #heardHeld == 0)
  ctl.deliver(3) -- the second add, the synced zserver kept, then the empty list's pending
  ctl.cb().config({ state = "synced" })
  ctl.cb().config({ state = "disabled" })
  ctl.deliver(1) -- this list's
  snap = held:snapshot()
  check(
    "nor the empty list's end: pending, nothing bound, and no read while zserver syncs",
    snap.state == "pending" and next(snap.bound) == nil and not ctl.corrupted
  )
  ctl.deliver()
  fire("ZBindSettle")
  check("this list's own synced is", keys(held:snapshot().bound) == keys(held:snapshot().listed))

  -- With no coordinator known it cannot be spelled another way: Director skips it, and
  -- zserver syncs the empty list.
  ctl, ZBind = fresh(SET_BEFORE)
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  ctl.restart()
  ZBind = reload()
  again = binder(ZBind, nil, nil, true)
  apply(again)
  ctl.known = true
  ctl.online()
  fire("ZBindApply")
  check(
    "no coordinator known: the list goes as it was, and is skipped",
    ctl.syncs == 2 and ctl.list[1].dstDeviceEuid == nil
  )
  again:wake()
  ctl.deliver(2) -- the second add, which Director skips as unchanged, then the synced zserver kept
  check(
    "neither a frame nor the synced zserver kept sends a read while zserver syncs the empty list",
    not ctl.corrupted
  )
  ctl.deliver(2)
  check("the empty list's sync shows nothing bound", tableOf(ctl) == "" and next(again:snapshot().bound) == nil)
  -- Each synced after a list set while stale is taken once no state follows it.
  fire("ZBindSettle")
  ctl.deliver()
  fire("ZBindSettle")
  ctl.deliver()
  check(
    "the read after it finds the table empty, and the list set again is sent",
    tableOf(ctl) == BOUND and again:snapshot().coordEui == COORD,
    tableOf(ctl)
  )
  fire("ZBindSettle")
  check(
    "then spelled out, and shown bound",
    ctl.syncs == 4
      and ctl.list[1].dstDeviceEuid == COORD
      and keys(again:snapshot().bound) == keys(again:snapshot().listed)
  )

  -- A driver update whose Set fails for another reason is stale too; with no coordinator
  -- known Director then skips the list as the one zserver holds, and no state comes.
  ctl, ZBind = fresh(SET_BEFORE)
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  ZBind = reload()
  local updated = binder(ZBind)
  local obj = require("zigbee3.zv2"):object()
  rawset(obj, "Init", function()
    return 1
  end)
  apply(updated)
  rawset(obj, "Init", nil)
  fire("ZBindApply")
  check("skipped: nothing shows yet", ctl.syncs == 1 and updated:snapshot().state == nil)
  fire("ZBindSettle")
  check(
    "with no state after it, the one before stands, and the coordinator is read for",
    updated:snapshot().state == "synced" and #ctl.issued == 2
  )
  ctl.deliver()
  fire("ZBindSettle")
  check(
    "then the list is spelled out, and shown bound",
    ctl.syncs == 2 and keys(updated:snapshot().bound) == keys(updated:snapshot().listed)
  )

  -- Until Director has the device its address does not resolve either.
  ctl, ZBind = fresh({ zbindList = { eui = EUI, refused = { key(1, 0x0402) }, bound = {}, state = "synced" } })
  zb = binder(ZBind)
  local address
  zb.address = function()
    return address
  end
  check("no address: no record shown", zb:snapshot().state == nil and next(zb:snapshot().refused) == nil)
  apply(zb)
  check(
    "no list, tried again in a second, as a Set Director refuses is",
    ctl.calls.SetZdoBindConfig == nil and armedFor.ZBindApply == 1000 and zb:isActive()
  )
  zb.retrySince = zb.retrySince - 301
  fire("ZBindApply")
  check("every minute once five have passed", armedFor.ZBindApply == 60000 and ctl.calls.SetZdoBindConfig == nil)
  address = EUI
  fire("ZBindApply")
  check("then the list, without what the device's record refused", #ctl.list == 2 and ctl.list[2].clusterId == 0xFCC0)
  check("and nothing is left to retry", Timer.ZBindApply == nil and not zb:isActive())
end

--------------------------------------------------------------------------------
T.section("a disabled list: the table names the entry the device refused, and the rest is set again")
--------------------------------------------------------------------------------
do
  -- 619 at 23:51: srcEp 255 drew INVALID_ENDPOINT and disabled the list; the entries
  -- before it were bound, and a changed list synced.
  local targets = { { srcEp = 1, cluster = 0x0006 }, { srcEp = 2, cluster = 0x0006 }, { srcEp = 3, cluster = 0x0006 } }
  local ctl, ZBind = fresh(SET_BEFORE)
  ctl.answers[key(2, 0x0006)] = 0x82
  local zb = binder(ZBind, COORD)
  apply(zb, targets)
  ctl.deliver(2)
  check("disabled, with the first entry bound", zb:snapshot().state == "disabled" and tableOf(ctl) == "0006/1>1")
  check("the table is read", reads(ctl) == "0")
  ctl.deliver(1)
  local snap = zb:snapshot()
  check("the entry the table lacks is refused", keys(snap.refused) == tostring(key(2, 0x0006)), keys(snap.refused))
  check("and what the table holds shows bound", keys(snap.bound) == tostring(key(1, 0x0006)), keys(snap.bound))
  ctl.deliver()
  snap = zb:snapshot()
  check("the rest set again and synced", snap.state == "synced" and tableOf(ctl) == "0006/1>1,0006/3>1", tableOf(ctl))
  check("without the refused entry", #ctl.list == 2 and not snap.listed[key(2, 0x0006)])
  check("which stays refused", #stored("zbindList").refused == 1)
  ZBind = reload()
  local again = binder(ZBind, COORD)
  local calls = ctl.calls.SetZdoBindConfig
  apply(again, targets)
  check("after a reload too: the same list, skipped", ctl.calls.SetZdoBindConfig == calls + 1 and #ctl.queue == 0)
  check(
    "traffic on it does not make it bound",
    again:noteTraffic(2, 0x0006) == false and not again:snapshot().bound[key(2, 0x0006)]
  )

  -- A binding to another device made since the list was set: the device refused
  -- its unbind, so the list carries it from then on, and names nothing.
  ctl, ZBind = fresh(SET_BEFORE, { rec(0x0008, 1, BULB) })
  ctl.answers[key(1, 0x0008)] = 0x84
  zb = binder(ZBind, COORD)
  apply(zb, targets)
  ctl.deliver()
  snap = zb:snapshot()
  check("a record the list lacked, whose unbind was refused: nothing refused", next(snap.refused) == nil)
  check(
    "it is carried, and the list set again synced",
    snap.state == "synced" and ctl.syncs == 2 and tableOf(ctl) == "0008/1>1@" .. BULB .. ",0006/1>1,0006/2>1,0006/3>1",
    tableOf(ctl)
  )

  -- A binding to another device the list carries names nothing refused.
  ctl, ZBind = fresh(
    { zbindList = { eui = EUI, carried = { { srcEp = 1, cluster = 0x0008, dstEp = 11, dst = BULB } } } },
    { rec(0x0008, 11, BULB) }
  )
  ctl.answers[key(2, 0x0006)] = 0x82
  zb = binder(ZBind, COORD)
  apply(zb, targets)
  ctl.deliver()
  check(
    "beside a carried binding, the entry the table lacks is refused",
    keys(zb:snapshot().refused) == tostring(key(2, 0x0006))
      and tableOf(ctl) == "0008/1>11@" .. BULB .. ",0006/1>1,0006/3>1",
    tableOf(ctl)
  )

  -- Nor is a second record for a listed entry: an FP300's 0x0402 once placed at ep1,
  -- whose unbind the device refused before zserver bound anything.
  ctl, ZBind = fresh(SET_BEFORE, { rec(0x0001, 197), rec(0x0402, 1), rec(0x0402, 3) })
  ctl.answers[key(1, 0x0402)] = 0x84
  zb = binder(ZBind, COORD)
  zb.at = "before"
  apply(zb)
  ctl.deliver()
  snap = zb:snapshot()
  check("a listed entry held twice: nothing refused", snap.state == "disabled" and next(snap.refused) == nil)
  check("and nothing set again", ctl.syncs == 1)
  check("what the table holds shows, and when it was read", snap.bound[key(1, 0x0402)] and snap.at ~= "before")
  check("kept for the next load", #stored("zbindList").bound == 2)
  -- A Director restart: the disabled zserver kept comes after the list set again.
  ctl.restart()
  ZBind = reload()
  zb = binder(ZBind, COORD, nil, true)
  apply(zb)
  ctl.known = true
  ctl.online()
  fire("ZBindApply")
  local n = #ctl.issued
  ctl.deliver(2) -- the second add, then the disabled zserver kept
  check("the disabled zserver kept is not read for", #ctl.issued == n and not ctl.corrupted)

  -- With no coordinator known, a record could point at a previous one.
  ctl, ZBind = fresh({}, { rec(0x0001, 1, OLD_COORD), rec(0x0402, 3, OLD_COORD) })
  ctl.answers[key(1, 0x0001)] = 0x84
  local fallback
  zb = binder(ZBind)
  zb.coordFallback = function()
    return fallback
  end
  apply(zb)
  ctl.deliver()
  check("records and no coordinator known: nothing refused", next(zb:snapshot().refused) == nil and ctl.syncs == 1)
  zb:wake()
  check("nor read again while none is known", #ctl.issued == 1)
  fallback = COORD -- a sibling on this controller synced meanwhile
  zb.askedAt = zb.askedAt - 900
  zb:wake()
  ctl.deliver(1)
  check("once one is, a frame reads it again", #ctl.issued == 2)
  check("whose records to a previous coordinator are carried now", #zb.carried == 2 and ctl.syncs == 2)
  zb.askedAt = zb.askedAt - 900
  zb:wake()
  check("and it is not asked again", #ctl.issued == 2)

  -- A table with no record names the first entry, coordinator or not.
  ctl, ZBind = fresh()
  ctl.answers[key(1, 0x0001)] = 0x82
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  snap = zb:snapshot()
  check("an empty table: the first entry is refused", keys(snap.refused) == tostring(key(1, 0x0001)))
  check(
    "the rest bound, and the coordinator read from it",
    tableOf(ctl) == "0402/1>3,FCC0/1>1" and snap.coordEui == COORD
  )
end

--------------------------------------------------------------------------------
T.section("a rejoin: a device that came back with an empty table gets its list again")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  local syncs = ctl.syncs
  zb:check()
  check("the table is read only after a wait", armedFor.ZBindCheck == 10000 and #ctl.issued == 0)
  fire("ZBindCheck")
  ctl.deliver()
  check("one page read; the table still holds the list, so nothing is set", reads(ctl) == "0" and ctl.syncs == syncs)

  ctl.table = {} -- a factory reset under the same device
  zb:check()
  fire("ZBindCheck")
  ctl.deliver(1)
  check(
    "an empty table: the same list, the coordinator spelled out, which Director sends",
    ctl.syncs == syncs + 1 and #ctl.list == 3 and ctl.list[1].dstDeviceEuid == COORD and ctl.list[1].dstEndpoint == nil
  )
  check("the empty table shows", next(zb:snapshot().bound) == nil)
  ctl.deliver()
  check("and zserver binds it where it did", tableOf(ctl) == BOUND, tableOf(ctl))
  fire("ZBindSettle")
  check("synced", zb:snapshot().state == "synced" and zb:snapshot().bound[key(1, 0xFCC0)])

  -- A coordinator only a sibling knew is kept as the device's own once the list names
  -- it, so a reboot's Set before the sibling is readable names it as the last list did,
  -- and a second loss names the case zserver lacks.
  local sibling = COORD
  ctl, ZBind = fresh(SET_BEFORE)
  zb = binder(ZBind)
  zb.coordFallback = function()
    return sibling
  end
  apply(zb)
  ctl.deliver()
  ctl.table = {}
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  ctl.list, ctl.held, ctl.published, sibling = nil, {}, {}, nil -- a reboot
  ZBind = reload()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  ctl.table = {}
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  check(
    "a second loss spells it in lower case, and is bound again",
    ctl.syncs == 4 and ctl.list[1].dstDeviceEuid == COORD:lower() and tableOf(ctl) == BOUND,
    tableOf(ctl)
  )

  fire("ZBindSettle")
  zb:check()
  ctl.cb().config({ state = "pending" }) -- zserver's own sync, from a reboot it noticed
  check("a pending state within the wait cancels the check", Timer.ZBindCheck == nil)
  zb:check()
  check("and while it is not synced there is none", Timer.ZBindCheck == nil)
  ctl.cb().config({ state = "synced" })

  -- The list set again is disabled: the refused entry goes, and the rest is set.
  ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  ctl.table = {}
  ctl.answers[key(1, 0x0402)] = 0x82
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  fire("ZBindSettle")
  ctl.deliver()
  check(
    "a repair the device refuses ends in a list without the entry",
    tableOf(ctl) == "0001/1>197,FCC0/1>1",
    tableOf(ctl)
  )
  check("synced", zb:snapshot().state == "synced" and zb:snapshot().refused[key(1, 0x0402)])

  -- What a check reads is shown and kept: a listed record to another node, and one
  -- the list does not hold, are not bound.
  ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  zb = binder(ZBind)
  apply(zb, { TARGETS[1], TARGETS[2] })
  ctl.deliver()
  ctl.table[2].dstDeviceEuid = OLD_COORD
  ctl.table[3] = rec(0x0006, 1)
  zb.at = "before"
  zb:check()
  fire("ZBindCheck")
  ctl.deliver(1)
  local bound = keys(zb:snapshot().bound)
  check("only the listed record to the coordinator is bound", bound == tostring(key(1, 0x0001)), bound)
  check("with when it was read", zb:snapshot().at ~= "before")
  local list = stored("zbindList")
  check("kept for the next load", #list.bound == 1 and list.at == zb:snapshot().at)

  -- The rejoin's read names a coordinator the read after synced missed.
  ctl, ZBind = fresh()
  local heard
  zb, heard = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  check("the read after synced got no page", zb:snapshot().coordEui == nil)
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  check("a rejoin's read names the coordinator", zb:snapshot().coordEui == COORD and stored("zbindCoordEui") == COORD)
  check("and the hook hears it settled", heard[#heard] == "true")

  -- An empty table while no coordinator is known cannot be spelled another way.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  ctl.table = {}
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  check("no coordinator known: a lost table is not set again", ctl.syncs == 1 and stored("zbindList").form == nil)

  -- A list of one too.
  ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  zb = binder(ZBind)
  apply(zb, { TARGETS[1] })
  ctl.deliver()
  ctl.table = {}
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  check("a list of one is set again, and bound", ctl.syncs == 2 and tableOf(ctl) == "0001/1>197", tableOf(ctl))
end

--------------------------------------------------------------------------------
T.section("the coordinator: this controller's, else a sibling's, else read once")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh(SET_BEFORE)
  local zb = binder(ZBind, COORD)
  apply(zb)
  ctl.deliver()
  check(
    "a sibling on this controller learned it: nothing is read",
    reads(ctl) == "" and zb:snapshot().coordEui == COORD
  )

  -- One learned on another controller is not this device's.
  ctl, ZBind = fresh({ zbindCoordEui = OLD_COORD, zbindCoordZserver = 35 })
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  check("the one learned on another controller is dropped, and the table read", reads(ctl) == "0")
  check("which names this one", zb:snapshot().coordEui == COORD and stored("zbindCoordZserver") == 20)

  -- A table whose listed records name two nodes names no coordinator.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.table[2].dstDeviceEuid = OLD_COORD -- as zserver would never leave it; played to disprove
  ctl.deliver()
  check("two nodes: none is taken", zb:snapshot().coordEui == nil and stored("zbindCoordEui") == nil)

  -- A binding to another device the list carries on one of the driver's own clusters.
  ctl, ZBind = fresh(
    { zbindList = { eui = EUI, carried = { { srcEp = 1, cluster = 0x0006, dstEp = 11, dst = BULB } } } },
    { rec(0x0006, 11, BULB) }
  )
  zb = binder(ZBind)
  apply(zb, { { srcEp = 1, cluster = 0x0006 } })
  ctl.deliver()
  check("a carried binding on the driver's own cluster does not hide the coordinator", zb:snapshot().coordEui == COORD)

  -- A bind an installer made since zserver's sync is not one of the list's.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.table[#ctl.table + 1] = rec(0x0006, 1, "4CE175B4C3970000")
  ctl.deliver()
  check("an unlisted record names nothing", zb:snapshot().coordEui == COORD)
end

--------------------------------------------------------------------------------
T.section("a target that names its coordinator endpoint is bound there")
--------------------------------------------------------------------------------
do
  -- A lock's: DoorLock where zserver puts it, and Poll Control named at the coordinator's
  -- ep1, where the lock's join bound its check-in.
  local lock = { { srcEp = 2, cluster = 0x0101 }, { srcEp = 2, cluster = 0x0020, dstEp = 1 } }
  local moved = { lock[1], { srcEp = 2, cluster = 0x0020, dstEp = 3 } }
  local seed = { zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList }
  local ctl, ZBind = fresh(seed)
  local zb = binder(ZBind)
  apply(zb, lock)
  check("the list names it", #ctl.list == 2 and ctl.list[2].dstEndpoint == 1)
  check("and leaves the other target to zserver", ctl.list[1].dstEndpoint == nil)
  ctl.deliver()
  check("bound where named", zb:snapshot().state == "synced" and tableOf(ctl) == "0101/2>2,0020/2>1", tableOf(ctl))
  apply(zb, moved)
  ctl.deliver()
  check(
    "moved in the session: the same keys, set again, and bound there",
    ctl.syncs == 2 and tableOf(ctl) == "0101/2>2,0020/2>3",
    tableOf(ctl)
  )
  apply(zb, moved)
  check("and not set again while it stays", ctl.calls.SetZdoBindConfig == 2)
  ZBind = reload()
  apply(binder(ZBind), moved)
  check("a reload sets it again, and Director skips it", ctl.calls.SetZdoBindConfig == 3 and ctl.syncs == 2)

  -- The device refuses it: the table after disabled names it, and the rest is set again.
  ctl, ZBind = fresh(seed)
  ctl.answers[key(2, 0x0020)] = 0x82
  zb = binder(ZBind)
  apply(zb, lock)
  ctl.deliver()
  local snap = zb:snapshot()
  check("its refusal is named", keys(snap.refused) == tostring(key(2, 0x0020)), keys(snap.refused))
  check(
    "and DoorLock is set again alone, and synced",
    snap.state == "synced" and #ctl.list == 1 and tableOf(ctl) == "0101/2>2",
    tableOf(ctl)
  )

  -- A record on its cluster at another endpoint is not the entry's, so one whose unbind
  -- the device refused names nothing.
  ctl, ZBind = fresh(seed, { rec(0x0020, 3, COORD, 2) })
  ctl.answers[key(2, 0x0020)] = 0x84
  zb = binder(ZBind)
  apply(zb, lock)
  ctl.deliver()
  snap = zb:snapshot()
  check("a record off the named endpoint: nothing refused", snap.state == "disabled" and next(snap.refused) == nil)
  check("nothing shown bound, and nothing set again", next(snap.bound) == nil and ctl.syncs == 1)

  -- setList refuses an endpoint outside 1-240, which would be tried again every minute.
  check(
    "a coordinator endpoint outside 1-240 cannot be listed",
    not ZBind.listable(2, 0x0020, 0) and not ZBind.listable(2, 0x0020, 241) and not ZBind.listable(2, 0x0020, 1.5)
  )
  check("one inside can", ZBind.listable(2, 0x0020, 240) == true)
  ctl, ZBind = fresh(seed)
  zb = binder(ZBind)
  apply(zb, { lock[1], { srcEp = 2, cluster = 0x0020, dstEp = 241 } })
  check(
    "only what the list can hold goes, and nothing is tried again",
    ctl.list ~= nil
      and #ctl.list == 1
      and ctl.list[1].clusterId == 0x0101
      and Timer.ZBindApply == nil
      and not zb:isActive()
  )
end

--------------------------------------------------------------------------------
T.section("nothing is read while zserver syncs")
--------------------------------------------------------------------------------
do
  -- 674 and 619: a read while zserver syncs corrupts its sync.
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  check("a read is out after synced", reads(ctl) == "0")
  ctl.table[#ctl.table + 1] = rec(0x0405, 3) -- a second page to read
  ctl.cb().config({ state = "pending" }) -- Director's own list, before the page came
  ctl.deliver()
  check(
    "the pending state dropped the read: its page names no coordinator",
    stored("zbindCoordEui") == nil and not zb:isActive()
  )
  check("and reads no further", reads(ctl) == "0", reads(ctl))

  -- A disabled list whose read never came: nothing is judged until the device speaks.
  ctl, ZBind = fresh()
  ctl.answers[key(1, 0x0402)] = 0x84
  zb = binder(ZBind, COORD)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  check("no page: nothing refused, nothing set", next(zb:snapshot().refused) == nil and ctl.syncs == 1)
end

--------------------------------------------------------------------------------
T.section("a read that got no page is asked again when the device next speaks")
--------------------------------------------------------------------------------
do
  -- A sleepy FP300 dozed before the read after disabled reached it.
  local ctl, ZBind = fresh(SET_BEFORE)
  ctl.answers[key(1, 0x0402)] = 0x84
  local zb = binder(ZBind, COORD)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  check("no page: nothing refused yet", next(zb:snapshot().refused) == nil and not zb:isActive())
  ZBind = reload()
  local again = binder(ZBind, COORD)
  apply(again)
  check(
    "a reload hears no state for its list, and reads nothing",
    again:snapshot().state == "disabled" and #ctl.issued == 1
  )
  again:wake()
  ctl.deliver()
  check("its next frame reads the table", #ctl.issued == 2 and again:snapshot().refused[key(1, 0x0402)])
  check("which names the entry, and the rest is bound", tableOf(ctl) == "0001/1>197,FCC0/1>1", tableOf(ctl))

  -- The read for the coordinator after synced, likewise.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  zb:wake()
  check("no page: the next frame reads the table again", #ctl.issued == 2)
  ctl.silence()
  fire("ZV2Read")
  zb:wake()
  check("frames ask at most every quarter hour", #ctl.issued == 2 and zb:snapshot().coordEui == nil)
  zb.askedAt = zb.askedAt - 900
  zb:wake()
  ctl.deliver()
  check("then again, and the table names the coordinator", #ctl.issued == 3 and zb:snapshot().coordEui == COORD)
  zb.askedAt = zb.askedAt - 900
  zb:wake()
  check("which is not read again", #ctl.issued == 3)
end

--------------------------------------------------------------------------------
T.section("a list zserver leaves pending is set again two hours after a frame")
--------------------------------------------------------------------------------
do
  -- 583: zserver's table read ended NO_APS_ACK at 05:03:51 and was never retried, so
  -- the list stayed pending through the device's later wakes.
  local ctl, ZBind = fresh(SET_BEFORE)
  local zb = binder(ZBind, COORD)
  apply(zb)
  ctl.deliver(1)
  ctl.silence()
  zb:wake()
  zb.pendingHeard = zb.pendingHeard - 7199
  zb:wake()
  check("pending under two hours after a frame: nothing is set", ctl.syncs == 1)
  zb.pendingHeard = zb.pendingHeard - 1
  zb:wake()
  check("then the same list, the coordinator spelled out", ctl.syncs == 2 and ctl.list[1].dstDeviceEuid == COORD)
  ctl.deliver(1) -- pending again, and its sync stalls too
  ctl.silence()
  zb:wake()
  zb.pendingHeard = zb.pendingHeard - 7199
  zb:wake()
  check("the next waits two hours from the frame after it", ctl.syncs == 2)
  zb.pendingHeard = zb.pendingHeard - 1
  zb:wake()
  ctl.deliver()
  fire("ZBindSettle")
  check(
    "spelled the other way, and zserver syncs it",
    ctl.syncs == 3 and zb:snapshot().state == "synced" and tableOf(ctl) == BOUND,
    tableOf(ctl)
  )

  -- A sync that ends starts no clock for the next list.
  ctl, ZBind = fresh(SET_BEFORE)
  zb = binder(ZBind, COORD)
  apply(zb)
  ctl.deliver(1)
  zb:wake()
  zb.pendingHeard = zb.pendingHeard - 7200
  ctl.deliver()
  apply(zb, { TARGETS[1], TARGETS[2] })
  ctl.deliver(1)
  zb:wake()
  check("a later list's first frame while pending sets nothing", ctl.syncs == 2)
end

--------------------------------------------------------------------------------
T.section("no list is set while the driver's own read is out")
--------------------------------------------------------------------------------
do
  -- zserver's read takes any page it hears (674 at 20:28): a Set now would start one.
  local more = { TARGETS[1], TARGETS[2], TARGETS[3], { srcEp = 1, cluster = 0x0405 } }
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  check("synced, and the read for the coordinator is out", zb:isActive() and reads(ctl) == "0")
  apply(zb, more)
  check("a changed list waits for it", ctl.syncs == 1)
  ctl.deliver(1)
  check("and goes once its page is in", ctl.syncs == 2 and #ctl.list == 4 and zb:snapshot().coordEui == COORD)
  ctl.deliver()
  check("then syncs", zb:snapshot().state == "synced" and tableOf(ctl) == BOUND .. ",0405/1>3", tableOf(ctl))

  -- Director's own list meanwhile: the page is zserver's to take, and the read is over.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.cb().config({ state = "pending" })
  apply(zb, more)
  check("a pending state leaves the list waiting on the read", ctl.syncs == 1 and zb:isActive())
  ctl.deliver(1)
  check("whose page ends it, naming nothing, and the list goes", ctl.syncs == 2 and zb:snapshot().coordEui == nil)
end

--------------------------------------------------------------------------------
T.section("what the list cannot hold is never sent, and the list is never empty")
--------------------------------------------------------------------------------
do
  local ZBind
  local ctl
  ctl, ZBind = fresh()
  check("Basic cannot be listed", ZBind.listable(1, 0x0000) == false)
  check("nor Green Power's endpoint 242", ZBind.listable(242, 0x0021) == false)
  check("On/Off on endpoint 1 can", ZBind.listable(1, 0x0006) == true)
  local zb = binder(ZBind)
  apply(zb, { { srcEp = 1, cluster = 0x0000 }, { srcEp = 1, cluster = 0x0006 } })
  check("only what it can hold goes", #ctl.list == 1 and ctl.list[1].clusterId == 0x0006)
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb, { { srcEp = 1, cluster = 0x0000 } })
  check("nothing it can hold: no list at all", ctl.calls.SetZdoBindConfig == nil and not zb:isActive())
  apply(zb, {})
  check("nor for no targets", ctl.calls.SetZdoBindConfig == nil)
end

--------------------------------------------------------------------------------
T.section("traffic shows a listed entry bound for the session")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb = binder(ZBind, COORD)
  check("nothing is listed before a list is set", zb:noteTraffic(1, 0x0402) == false)
  apply(zb)
  ctl.deliver(1)
  check("a report on a listed entry shows it bound", zb:noteTraffic(1, 0x0402) == true)
  check("once", zb:noteTraffic(1, 0x0402) == false and zb:snapshot().bound[key(1, 0x0402)])
  check("one on an unlisted cluster does not", zb:noteTraffic(1, 0x0006) == false)
  check("nor garbage", zb:noteTraffic(nil, 6) == false)
  ZBind = reload()
  local again = binder(ZBind, COORD)
  check("traffic is not kept across a reload", again:snapshot().bound[key(1, 0x0402)] == nil)
  apply(again)
  ctl.deliver()
  check("zserver's sync shows every entry", keys(again:snapshot().bound) == keys(again:snapshot().listed))
  check("and a bound entry's traffic changes nothing shown", again:noteTraffic(1, 0x0001) == false)
end

--------------------------------------------------------------------------------
T.section("a closed binder hears nothing and keeps no timer")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb, heard = binder(ZBind)
  apply(zb)
  zb:close()
  ctl.deliver()
  check("a closed binder hears no state", #heard == 0 and zb:snapshot().state == nil)
  ctl.known = false
  apply(zb, { TARGETS[1] })
  check("a Set that fails is tried again", Timer.ZBindApply ~= nil)
  zb:close()
  check("until it is closed", Timer.ZBindApply == nil and not zb:isActive())

  -- The same device back: zserver went pending on Director's copy of the list while no
  -- binder listened, and the device sleeps.
  ctl, ZBind = fresh({ zbindCoordEui = COORD })
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  zb:close()
  ctl.published, ctl.asleep = {}, true
  ctl.online()
  ctl.deliver()
  zb = binder(ZBind)
  apply(zb)
  check("the next binder takes that pending over its record's synced", zb:snapshot().state == "pending")
  ctl.asleep = false
  ctl.deliver()
  check("and the synced at its wake", zb:snapshot().state == "synced")
end

--------------------------------------------------------------------------------
T.section("no path above read the table while zserver synced")
--------------------------------------------------------------------------------
do
  -- zv2's pcall turns the shim's raise into a read that did not go, so the shim notes it.
  local n = 0
  for _, ctl in ipairs(controllers) do
    n = n + (ctl.corrupted and 1 or 0)
  end
  check("no controller saw one", n == 0, n)
end

T.finish()
