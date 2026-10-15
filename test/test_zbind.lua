-- The lock's bind list in src/zigbee/zbind.lua, over src/zigbee/zv2.lua and the
-- ZigbeeV2 shim in c4_local.lua, which plays zserver, Director and the device as a
-- 4.3.0 controller was measured to (test_zv2.lua holds the shim to those measurements).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_zbind.lua
--
-- The paths a lock takes:
--   1. A fresh pair: the list is set, zserver syncs it, and the coordinator is read
--      from the table once, after zserver's own read.
--   2. A reload: an unchanged list costs nothing, and a moved endpoint is set again;
--      another device's record is not taken.
--   3. A Director restart: the list is set again as soon as Director has the device,
--      the coordinator spelled the other way so Director sends it, replacing the empty
--      list Director pushes before zserver acts on it; a state other than pending is
--      taken once none follows it, since the one zserver kept and the empty list's
--      come first.
--   4. A disabled list: the table names the DoorLock bind the lock refused, which is
--      then left to the status poll; a table holding anything else names none.
--   5. A rejoin: a lock that came back with an empty table gets its list again, the
--      coordinator spelled the other way so Director sends it.
--   6. A read that got no page is asked again when the lock next speaks, and a list
--      zserver leaves pending is set again two hours after a frame.
--   7. Nothing is read while zserver syncs (the last section checks every path above),
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
local DOORLOCK = 0x0101
-- The lock's DoorLock on its application endpoint, as the driver lists it.
local TARGETS = { { srcEp = 2, cluster = DOORLOCK } }
-- zserver binds it at the coordinator endpoint that models locks.
local BOUND = "0101/2>2"
-- An earlier load set this lock's list.
local SET_BEFORE = { zbindList = { eui = EUI } }
local function key(srcEp, cluster)
  return srcEp * 65536 + cluster
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
  T.unload("^zigbee%.")
  return require("zigbee.zbind")
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

--- A binder for the device at `eui` (EUI by default) on controller 20, as the driver
--- makes it, `stale` after a load that was not a driver update; `heard` gets each
--- hook's settled flag.
local function binder(ZBind, eui, stale)
  local zb = ZBind:new(stale)
  zb.address = function()
    return eui or EUI
  end
  zb.zserverId = function()
    return 20
  end
  local heard = {}
  zb.hookFn = function(settled)
    heard[#heard + 1] = tostring(settled)
  end
  return zb, heard
end

--- Apply `targets` (TARGETS by default) as the driver does.
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
  check(
    "the list went: DoorLock on the lock's endpoint",
    ctl.syncs == 1 and #ctl.list == 1 and ctl.list[1].clusterId == DOORLOCK and ctl.list[1].srcEndpoint == 2
  )
  check(
    "with no destination: zserver fills in the coordinator",
    ctl.list[1].dstEndpoint == nil and ctl.list[1].dstDeviceEuid == nil
  )
  check("with no coordinator known, nothing is read before zserver has synced", #ctl.issued == 0)
  ctl.deliver(1)
  check("pending", zb.state == "pending" and heard[1] == "false", zb.state)
  ctl.deliver(1) -- zserver's sync
  check("zserver bound DoorLock at the coordinator's ep2", tableOf(ctl) == BOUND, tableOf(ctl))
  check("synced, and the table read once, after zserver's own read", zb.state == "synced" and reads(ctl) == "0")
  ctl.deliver()
  check("the coordinator the listed record names", zb:coordinator() == COORD, tostring(zb:coordinator()))
  check("kept, with its controller", stored("zbindCoordEui") == COORD and stored("zbindCoordZserver") == 20)
  check(
    "the hook heard pending, synced, and the read's end, settled",
    table.concat(heard, ",") == "false,true,true",
    table.concat(heard, ",")
  )
  local list = stored("zbindList")
  check("the list's record is kept for this lock", list.eui == EUI and #list.refused == 0 and list.state == "synced")
  check("no read left in flight", zb.walking == nil and #ctl.queue == 0)
end

--------------------------------------------------------------------------------
T.section("a reload: an unchanged list costs nothing, and a moved endpoint is set again")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  ZBind = reload()
  local again, heard = binder(ZBind)
  check("the last load's state shows once the address is known", again:known() == EUI and again.state == "synced")
  local calls, syncs = ctl.calls.SetZdoBindConfig, ctl.syncs
  apply(again)
  check("the list is set again, and Director skips it", ctl.calls.SetZdoBindConfig == calls + 1 and ctl.syncs == syncs)
  check("so no state comes, and nothing is read", #ctl.queue == 0 and #heard == 0 and reads(ctl) == "0")
  apply(again)
  check("the same list later in the session is not set at all", ctl.calls.SetZdoBindConfig == calls + 1)
  apply(again, { { srcEp = 1, cluster = DOORLOCK } })
  ctl.deliver()
  check(
    "the lock's endpoint learned anew: the list moves with it",
    ctl.syncs == syncs + 1 and tableOf(ctl) == "0101/1>2" and again.state == "synced",
    tableOf(ctl)
  )

  -- A re-pair: the record names the device it was kept for.
  ZBind = reload()
  local other = binder(ZBind, "00124B0001DDEEFF")
  other:known()
  check("another device's record is not taken", other.state == nil and next(other.refused) == nil)
end

--------------------------------------------------------------------------------
T.section("a Director restart: the list is set again, spelled the other way, once Director has the device")
--------------------------------------------------------------------------------
do
  -- Director lost its lists; the driver's calls failed until addZ3Node, where Director
  -- pushed an empty list, and the driver's Set 0.4 to 1 s later was compared with the
  -- list zserver published before it, so it was skipped.
  local ctl, ZBind = fresh({ zbindCoordEui = COORD })
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  check("bound, and nothing read: the coordinator was known", tableOf(ctl) == BOUND and reads(ctl) == "")
  ctl.restart()
  ZBind = reload()
  local again = binder(ZBind, nil, true)
  apply(again)
  check("not found: tried again in a second", armedFor.ZBindApply == 1000 and Timer.ZBindApply ~= nil)
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
    ctl.syncs == 3 and ctl.list[1].dstDeviceEuid == COORD and Timer.ZBindApply == nil
  )
  check("and no state is taken for it until one comes", Timer.ZBindSettle == nil and again.state == nil)
  -- The synced zserver kept for the list before came first, then the empty list's
  -- pending and this list's; a sleepy device's own sync waits for its wake. Each
  -- device's ONLINE added it again first, and Director sent this list once more.
  ctl.asleep = true
  ctl.deliver()
  check("the second add sends this list again: one pending more", ctl.syncs == 4 and #ctl.queue == 1, ctl.syncs)
  check(
    "the synced zserver kept is not this list's: pending",
    again.state == "pending" and Timer.ZBindSettle == nil,
    tostring(again.state)
  )
  ctl.asleep = false
  ctl.deliver()
  check("which replaced the empty one before zserver acted on it: nothing was unbound", tableOf(ctl) == BOUND)
  check("its synced is taken once no state follows it", again.state == "pending" and armedFor.ZBindSettle == 10000)
  fire("ZBindSettle")
  check("synced", again.state == "synced")
  check("and kept as spelled, so the next restart spells it the other way", stored("zbindList").form == "upper")

  -- Director's own states before the list goes are not the driver's.
  ctl.restart()
  ZBind = reload()
  local later, heard = binder(ZBind, nil, true)
  apply(later)
  ctl.known = true
  ctl.online()
  ctl.deliver(3) -- the second add, the synced zserver kept, and the empty list's pending
  check(
    "Director's own pending shows, after the synced zserver kept",
    later.state == "pending" and table.concat(heard, ",") == "false,false",
    table.concat(heard, ",")
  )
  later:wake()
  later.pendingHeard = os.time() - 7200
  later:wake()
  check("and is not the driver's to set again", ctl.syncs == 6)
  local n = #ctl.issued
  ctl.cb().config({ state = "synced" }) -- as if its empty list had synced
  check("nor is anything read for it", #ctl.issued == n)
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

  -- After a reboot an unknown can come between the Set and its pending, and the empty
  -- list could end, synced or disabled, before zserver takes this one: none is this list's.
  ctl.restart()
  ZBind = reload()
  local held, heardHeld = binder(ZBind, nil, true)
  apply(held)
  ctl.known = true
  ctl.online()
  fire("ZBindApply")
  ctl.cb().config({ state = "unknown" })
  check("an unknown after the Set does not show", held.state == nil and #heardHeld == 0)
  ctl.deliver(3) -- the second add, the synced zserver kept, then the empty list's pending
  ctl.cb().config({ state = "synced" })
  ctl.cb().config({ state = "disabled" })
  ctl.deliver(1) -- this list's
  check(
    "nor the empty list's end: pending, and no read while zserver syncs",
    held.state == "pending" and not ctl.corrupted
  )
  ctl.deliver()
  fire("ZBindSettle")
  check("this list's own synced is", held.state == "synced" and tableOf(ctl) == BOUND)

  -- With no coordinator known it cannot be spelled another way: Director skips it, and
  -- zserver syncs the empty list.
  ctl, ZBind = fresh(SET_BEFORE)
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  ctl.restart()
  local ZBind2 = reload()
  local stale = binder(ZBind2, nil, true)
  apply(stale)
  ctl.known = true
  ctl.online()
  fire("ZBindApply")
  check(
    "no coordinator known: the list goes as it was, and is skipped",
    ctl.syncs == 2 and ctl.list[1].dstDeviceEuid == nil
  )
  stale:wake()
  ctl.deliver(2) -- the second add, which Director skips as unchanged, then the synced zserver kept
  check(
    "neither a frame nor the synced zserver kept sends a read while zserver syncs the empty list",
    not ctl.corrupted
  )
  ctl.deliver(2)
  check("the empty list's sync unbinds it", tableOf(ctl) == "")
  -- Each synced after a list set while stale is taken once no state follows it.
  fire("ZBindSettle")
  ctl.deliver()
  fire("ZBindSettle")
  ctl.deliver()
  check(
    "the read after it finds the table empty, and the list set again is sent",
    tableOf(ctl) == BOUND and stale:coordinator() == COORD,
    tableOf(ctl)
  )
  fire("ZBindSettle")
  check(
    "then spelled out, and synced",
    ctl.syncs == 4 and ctl.list[1].dstDeviceEuid == COORD and stale.state == "synced"
  )

  -- A driver update whose Set fails for another reason is stale too; with no coordinator
  -- known Director then skips the list as the one zserver holds, and no state comes.
  ctl, ZBind = fresh(SET_BEFORE)
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  ZBind2 = reload()
  local updated = binder(ZBind2)
  local obj = require("zigbee.zv2"):object()
  rawset(obj, "Init", function()
    return 1
  end)
  apply(updated)
  rawset(obj, "Init", nil)
  fire("ZBindApply")
  check("skipped: nothing shows yet", ctl.syncs == 1 and updated.state == nil)
  fire("ZBindSettle")
  check(
    "with no state after it, the one before stands, and the coordinator is read for",
    updated.state == "synced" and #ctl.issued == 2
  )
  ctl.deliver()
  fire("ZBindSettle")
  check("then the list is spelled out, and synced", ctl.syncs == 2 and updated.state == "synced")

  -- Until Director has the device its address does not resolve either.
  ctl, ZBind = fresh({ zbindList = { eui = EUI, state = "synced" } })
  zb = binder(ZBind)
  local address
  zb.address = function()
    return address
  end
  apply(zb)
  check(
    "no address: no list, tried again in a second, as a Set Director refuses is",
    ctl.calls.SetZdoBindConfig == nil and armedFor.ZBindApply == 1000 and zb.state == nil
  )
  zb.retrySince = zb.retrySince - 301
  fire("ZBindApply")
  check("every minute once five have passed", armedFor.ZBindApply == 60000 and ctl.calls.SetZdoBindConfig == nil)
  address = EUI
  fire("ZBindApply")
  check("then the list", #ctl.list == 1 and ctl.list[1].srcEndpoint == 2)
  check("and nothing is left to retry", Timer.ZBindApply == nil and zb.retrySince == nil)
  ctl.deliver()
  fire("ZBindSettle")
  check("set while stale, its synced is taken once none follows it", zb.state == "synced" and tableOf(ctl) == BOUND)
end

--------------------------------------------------------------------------------
T.section("a disabled list: the table names the bind the lock refused, and the poll covers it")
--------------------------------------------------------------------------------
do
  -- NOT_SUPPORTED to the bind: zserver disabled the list with nothing bound.
  local ctl, ZBind = fresh(SET_BEFORE)
  ctl.answers[key(2, DOORLOCK)] = 0x84
  local zb, heard = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  check("disabled, nothing bound", zb.state == "disabled" and tableOf(ctl) == "")
  check("the table is read", reads(ctl) == "0")
  ctl.deliver(1)
  check("the entry the table lacks is refused", keys(zb.refused) == tostring(key(2, DOORLOCK)), keys(zb.refused))
  check("nothing is left to list, so nothing is set again", ctl.syncs == 1 and Timer.ZBindApply == nil)
  check("never settled", heard[#heard] == "false")
  check("kept refused for the next load", #stored("zbindList").refused == 1)
  ZBind = reload()
  local again = binder(ZBind)
  local calls = ctl.calls.SetZdoBindConfig
  apply(again)
  check("after a reload no list is set either", ctl.calls.SetZdoBindConfig == calls)
  apply(again, { { srcEp = 1, cluster = DOORLOCK } })
  check("but one on another endpoint is", ctl.calls.SetZdoBindConfig == calls + 1)

  -- A record whose unbind the lock refused, ahead of DoorLock: nothing is named.
  ctl, ZBind = fresh({ zbindList = SET_BEFORE.zbindList, zbindCoordEui = COORD }, { rec(0x0001, 1) })
  ctl.answers[key(2, 0x0001)] = 0x84
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  check("a record the list lacked, whose unbind was refused: nothing refused", next(zb.refused) == nil)
  check("and nothing set again", ctl.syncs == 1 and zb.state == "disabled")

  -- With no coordinator known, a record could point at a previous one.
  ctl, ZBind = fresh(SET_BEFORE, { rec(0x0001, 1, "00124B0001CE4B99") })
  ctl.answers[key(2, 0x0001)] = 0x84
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  check("records and no coordinator known: nothing refused", next(zb.refused) == nil and ctl.syncs == 1)
  zb:wake()
  check("nor read again while none is known", #ctl.issued == 1)
end

--------------------------------------------------------------------------------
T.section("a rejoin: a lock that came back with an empty table gets its list again")
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
    ctl.syncs == syncs + 1 and #ctl.list == 1 and ctl.list[1].dstDeviceEuid == COORD and ctl.list[1].dstEndpoint == nil
  )
  ctl.deliver()
  check("and zserver binds it where it did", tableOf(ctl) == BOUND, tableOf(ctl))
  fire("ZBindSettle")
  check("synced", zb.state == "synced")

  -- A second loss names the case zserver lacks.
  ctl.table = {}
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  fire("ZBindSettle")
  check(
    "a second loss spells it in lower case, and is bound again",
    ctl.syncs == syncs + 2 and ctl.list[1].dstDeviceEuid == COORD:lower() and tableOf(ctl) == BOUND,
    tableOf(ctl)
  )

  zb:check()
  ctl.cb().config({ state = "pending" }) -- zserver's own sync, from a reboot it noticed
  check("a pending state within the wait cancels the check", Timer.ZBindCheck == nil)
  zb:check()
  check("and while it is not synced there is none", Timer.ZBindCheck == nil)
  ctl.cb().config({ state = "synced" })

  -- The rejoin's read names a coordinator the read after synced missed.
  ctl, ZBind = fresh()
  local heard
  zb, heard = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  check("the read after synced got no page", zb:coordinator() == nil)
  zb:check()
  fire("ZBindCheck")
  ctl.deliver()
  check("a rejoin's read names the coordinator", zb:coordinator() == COORD and stored("zbindCoordEui") == COORD)
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
end

--------------------------------------------------------------------------------
T.section("the coordinator: kept with its controller, else read once")
--------------------------------------------------------------------------------
do
  -- One learned on another controller is not this device's.
  local ctl, ZBind = fresh({ zbindCoordEui = "00124B0001CE4B99", zbindCoordZserver = 35 })
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  check("the one learned on another controller is dropped, and the table read", reads(ctl) == "0")
  check("which names this one", zb:coordinator() == COORD and stored("zbindCoordZserver") == 20)

  -- One stored while no controller was known is kept.
  ctl, ZBind = fresh({ zbindCoordEui = COORD })
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  check("one stored without its controller is taken, and nothing read", zb:coordinator() == COORD and reads(ctl) == "")

  -- A bind an installer made since zserver's sync is not one of the list's.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.table[#ctl.table + 1] = rec(0x0006, 1, "4CE175B4C3970000")
  ctl.deliver()
  check("an unlisted record names nothing", zb:coordinator() == COORD)

  -- A table whose listed records name two nodes names no coordinator.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb, { TARGETS[1], { srcEp = 2, cluster = 0x0001 } })
  ctl.deliver(2)
  ctl.table[2].dstDeviceEuid = "00124B0001CE4B99" -- as zserver would never leave it; played to disprove
  ctl.deliver()
  check("two nodes: none is taken", zb:coordinator() == nil and stored("zbindCoordEui") == nil)
end

--------------------------------------------------------------------------------
T.section("nothing is read while zserver syncs")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  check("a read is out after synced", reads(ctl) == "0")
  ctl.cb().config({ state = "pending" }) -- Director's own list, before the page came
  ctl.deliver()
  check(
    "the pending state dropped the read: its page names no coordinator",
    stored("zbindCoordEui") == nil and zb.walking == nil
  )
  check("and reads no further", reads(ctl) == "0", reads(ctl))

  -- A disabled list whose read never came: nothing is judged until the lock speaks.
  ctl, ZBind = fresh({ zbindCoordEui = COORD })
  ctl.answers[key(2, DOORLOCK)] = 0x84
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  check("no page: nothing refused, nothing set", next(zb.refused) == nil and ctl.syncs == 1)
end

--------------------------------------------------------------------------------
T.section("a read that got no page is asked again when the lock next speaks")
--------------------------------------------------------------------------------
do
  -- A sleepy lock dozed before the read after disabled reached it.
  local ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  ctl.answers[key(2, DOORLOCK)] = 0x84
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.silence()
  fire("ZV2Read")
  check("no page: nothing refused yet", next(zb.refused) == nil and zb.walking == nil)
  ZBind = reload()
  local again = binder(ZBind)
  apply(again)
  check("a reload hears no state for its list, and reads nothing", again.state == "disabled" and #ctl.issued == 1)
  again:wake()
  ctl.deliver()
  check("its next frame reads the table", #ctl.issued == 2 and again.refused[key(2, DOORLOCK)])

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
  check("frames ask at most every quarter hour", #ctl.issued == 2 and zb:coordinator() == nil)
  zb.askedAt = zb.askedAt - 900
  zb:wake()
  ctl.deliver()
  check("then again, and the table names the coordinator", #ctl.issued == 3 and zb:coordinator() == COORD)
  zb.askedAt = zb.askedAt - 900
  zb:wake()
  check("which is not read again", #ctl.issued == 3)
end

--------------------------------------------------------------------------------
T.section("a list zserver leaves pending is set again two hours after a frame")
--------------------------------------------------------------------------------
do
  -- zserver's table read ended NO_APS_ACK and was never retried, so the list stayed
  -- pending through the device's later wakes.
  local ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  local zb = binder(ZBind)
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
    ctl.syncs == 3 and zb.state == "synced" and tableOf(ctl) == BOUND,
    tableOf(ctl)
  )

  -- A sync that ends starts no clock for the next list.
  ctl, ZBind = fresh({ zbindCoordEui = COORD, zbindList = SET_BEFORE.zbindList })
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(1)
  zb:wake()
  zb.pendingHeard = zb.pendingHeard - 7200
  ctl.deliver()
  apply(zb, { { srcEp = 1, cluster = DOORLOCK } })
  ctl.deliver(1)
  zb:wake()
  check("a later list's first frame while pending sets nothing", ctl.syncs == 2)
end

--------------------------------------------------------------------------------
T.section("no list is set while the driver's own read is out")
--------------------------------------------------------------------------------
do
  -- zserver's read takes any page it hears: a Set now would start one.
  local moved = { { srcEp = 1, cluster = DOORLOCK } }
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  check("synced, and the read for the coordinator is out", zb.walking ~= nil and reads(ctl) == "0")
  apply(zb, moved)
  check("a changed list waits for it", ctl.syncs == 1)
  ctl.deliver(1)
  check("and goes once its page is in", ctl.syncs == 2 and ctl.list[1].srcEndpoint == 1 and zb:coordinator() == COORD)
  ctl.deliver()
  check("then syncs", zb.state == "synced" and tableOf(ctl) == "0101/1>2", tableOf(ctl))

  -- Director's own list meanwhile: the page is zserver's to take, and the read is over.
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver(2)
  ctl.cb().config({ state = "pending" })
  apply(zb, moved)
  check("a pending state leaves the list waiting on the read", ctl.syncs == 1 and zb.walking ~= nil)
  ctl.deliver(1)
  check("whose page ends it, naming nothing, and the list goes", ctl.syncs == 2 and zb:coordinator() == nil)
end

--------------------------------------------------------------------------------
T.section("what the list cannot hold is never sent, and the list is never empty")
--------------------------------------------------------------------------------
do
  local ctl, ZBind = fresh()
  local zb = binder(ZBind)
  apply(zb, { { srcEp = 2, cluster = 0x0000 }, TARGETS[1] })
  check("Basic cannot be listed: only DoorLock goes", #ctl.list == 1 and ctl.list[1].clusterId == DOORLOCK)
  ctl, ZBind = fresh()
  zb = binder(ZBind)
  apply(zb, { { srcEp = 242, cluster = DOORLOCK } })
  check("nor Green Power's endpoint 242: no list at all", ctl.calls.SetZdoBindConfig == nil and Timer.ZBindApply == nil)
  apply(zb, { { srcEp = 2, cluster = 0x0000 } })
  check("nor for Basic alone", ctl.calls.SetZdoBindConfig == nil)
  apply(zb, {})
  check("nor for no targets", ctl.calls.SetZdoBindConfig == nil)
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
  check("a closed binder hears no state", #heard == 0 and zb.state == nil)
  ctl.known = false
  apply(zb, { { srcEp = 1, cluster = DOORLOCK } })
  check("a Set that fails is tried again", Timer.ZBindApply ~= nil)
  zb:close()
  check("until it is closed", Timer.ZBindApply == nil and zb.retrySince == nil)

  -- The same lock back: zserver went pending on Director's copy of the list while no
  -- binder listened, and the lock sleeps.
  ctl, ZBind = fresh({ zbindCoordEui = COORD })
  zb = binder(ZBind)
  apply(zb)
  ctl.deliver()
  zb:close()
  ctl.published, ctl.asleep = {}, true
  ctl.online()
  ctl.deliver()
  local next = binder(ZBind)
  apply(next)
  check("the next binder takes that pending over its record's synced", next.state == "pending")
  ctl.asleep = false
  ctl.deliver()
  check("and the synced at its wake", next.state == "synced")
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
