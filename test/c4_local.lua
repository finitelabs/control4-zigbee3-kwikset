-- Driver-local environment seams, per CONTRIBUTING "Driver-local test support".
-- Require this from any suite that loads the binder or the driver; c4_shim is
-- preloaded by `make test` and run_test.sh, this is not.
--
-- Three things. C4:SendZigbeePacket, which only a Zigbee driver calls, recorded so
-- a suite can see what went out. The C4:Persist* store as a controller answers it: a
-- write is read back only once it lands, which a suite marks at the seams between
-- calls with ShimPersistLand. And C4:ZigbeeV2(), opt-in through ShimInstallZigbeeV2.

require("c4_shim")

-- C4:Persist* as measured on OS 4.3.0: a value set is read back by C4:PersistGetValue
-- only once the write lands, about 50 ms later, so a read soon after the set misses it;
-- the shim lands writes between calls. A delete of a landed value is read back at
-- once, but a write still landing lands after it; an absent key answers no value at all.
-- A write lands in c4_shim's store, which keeps what the controller keeps of it.
local storeGet, storeSet, storeDelete = C4.PersistGetValue, C4.PersistSetValue, C4.PersistDeleteValue
local persist_pending = {}

function C4:PersistGetValue(key, encrypted)
  local v = storeGet(self, key, encrypted)
  if v == nil then
    return
  end
  return v
end

function C4:PersistSetValue(key, value, encrypted)
  persist_pending[key] = { value = value, encrypted = encrypted }
end

function C4:PersistDeleteValue(key)
  storeDelete(self, key)
end

--- Land every write made so far, as the store has by the next call into the driver.
function ShimPersistLand()
  for k, w in pairs(persist_pending) do
    storeSet(C4, k, w.value, w.encrypted)
  end
  persist_pending = {}
end

local zigbee_packets = {}

function C4:SendZigbeePacket(payload, profileId, clusterId, groupId, srcEndpoint, dstEndpoint)
  zigbee_packets[#zigbee_packets + 1] = {
    payload = payload,
    profileId = profileId,
    clusterId = clusterId,
    groupId = groupId,
    srcEndpoint = srcEndpoint,
    dstEndpoint = dstEndpoint,
  }
end

--- @return table packets Every packet passed to C4:SendZigbeePacket, in order.
function ShimZigbeePackets()
  return zigbee_packets
end

--- Forget the recorded packets, so a case counts only its own.
function ShimResetZigbeePackets()
  zigbee_packets = {}
end

-- C4:ZigbeeV2(), the part the bind list uses, as measured on OS 4.3.0 (plugs, sleepy
-- sensors, and a driver whose device the Zigbee server does not know, 2026-09-24).
-- Anything the shim does not model raises rather than answers, so no test can lean
-- on invented behaviour. zserver, Director and the device are played by the
-- controller that ShimInstallZigbeeV2 returns.

-- The coordinator's clusters per endpoint, as decoded on the dev controller.
local V2_ENDPOINT_RANGES = {
  [1] = { { 0x0000, 0x0001 }, { 0x0003, 0x0008 }, { 0x001A, 0x001A }, { 0x0020, 0x0020 }, { 0x0500, 0x0502 } },
  [2] = { { 0x0100, 0x0103 }, { 0x0201, 0x0204 }, { 0x0300, 0x0301 }, { 0x0B00, 0x0B05 } },
  [3] = {
    { 0x0002, 0x0002 },
    { 0x0009, 0x0009 },
    { 0x000F, 0x000F },
    { 0x0200, 0x0200 },
    { 0x0400, 0x0406 },
    { 0x040C, 0x040D },
    { 0x0702, 0x0702 },
  },
  [4] = { { 0x040E, 0x041D } },
  [5] = { { 0x041E, 0x0429 } },
  [196] = { { 0xFC00, 0xFC09 } },
  [197] = { { 0x0001, 0x0001 } },
  [198] = { { 0x0001, 0x0001 } },
}

--- The coordinator endpoint zserver binds a list entry to when the entry names none:
--- the lowest after ep1 that models the cluster, else ep1.
local function v2Endpoint(cluster)
  local best
  for ep, ranges in pairs(V2_ENDPOINT_RANGES) do
    for _, r in ipairs(ranges) do
      if ep ~= 1 and cluster >= r[1] and cluster <= r[2] and (best == nil or ep < best) then
        best = ep
      end
    end
  end
  return best or 1
end

-- The callback slots; each 4.3.0 name shares its slot with the 4.2.1 alias.
local V2_SLOTS = {
  OnZdoSentStatus = "status",
  CmdZdoExecStatusCb = "status",
  OnZdoGetBindTableResponse = "table",
  ResZdoGetBindCb = "table",
  OnZdoBindConfigStatusEvent = "config",
}

-- Bind_rsp statuses that make zserver disable the whole list: 0x80, 0x82, 0x84, 0x8B
-- and 0x8D (INVALID_ENDPOINT was measured). Any other it retries on a timer.
local V2_DISABLING = { [0x80] = true, [0x82] = true, [0x84] = true, [0x8B] = true, [0x8D] = true }

local NOT_FOUND = "Device not found in Zigbee Manager"

-- The host's integer read: a number or a numeric string, truncated toward zero.
local function v2Int(v)
  local n = tonumber(v)
  if n == nil then
    return nil
  end
  return n < 0 and math.ceil(n) or math.floor(n)
end

--- Install C4:ZigbeeV2() and return its controller.
--- opts.coord: the coordinator's EUI64, which zserver fills into a list entry.
--- ctl.known: false until Director has added the device: every device call answers 0
--- and "Device not found in Zigbee Manager", but GetZdoBindConfig an empty list.
--- ctl.asleep: zserver holds a sleepy device's reads until it wakes.
--- ctl.answers: key (srcEp * 65536 + cluster) -> the status the device answers a bind
--- or unbind of it with, instead of SUCCESS.
--- ctl.corrupted: true once a table read was sent while zserver synced, which also
--- raises; a caller's pcall can swallow the raise.
--- @return table ctl { table, list, held, published, state, syncs, known, asleep, answers,
---   made, live, inits, calls, issued, invalid, queue, corrupted, cb(), deliver(n),
---   accept(n), silence(), restart(), online() }
function ShimInstallZigbeeV2(opts)
  opts = opts or {}
  local ctl = {
    coord = opts.coord or "00124B0001CE4B21",
    table = {}, -- the device's binding table
    list = nil, -- Director's copy of the bind list the driver set
    held = {}, -- the list zserver holds, each entry's destination filled in
    published = {}, -- the list zserver last published, with a state: Director compares with it
    state = nil, -- zserver's state for it
    syncs = 0, -- lists Director sent zserver
    known = true,
    asleep = false,
    answers = {},
    made = 0, -- objects C4:ZigbeeV2() returned
    collected = 0, -- and how many of them have been collected
    live = setmetatable({}, { __mode = "v" }), -- the ones not yet collected
    inits = 0,
    calls = {}, -- method name -> times called
    issued = {}, -- every table read sent, in order
    invalid = {}, -- calls answered 0 and a message, never sent
    queue = {}, -- reads not yet answered, and zserver's work not yet done
    nextCid = 2.4416681809710234e+17,
  }
  -- The device's one callback registration: the object that last called Init().
  -- Held weakly, as Director holds it.
  local reg = setmetatable({}, { __mode = "v" })
  -- The state zserver kept across a Director restart, and the list it was for.
  local retained
  -- A Director restart adds the device twice; the second add is still to come.
  local readd

  -- Every answer goes to the object that last called Init(), whoever sent it.
  local function fire(slot, ...)
    local obj = reg.obj
    if obj and obj._cb[slot] then
      ShimPersistLand()
      obj._cb[slot](...)
    end
  end

  local function page(start)
    local binds = {}
    for i = start + 1, math.min(start + 3, #ctl.table) do -- pages of 3
      local b = ctl.table[i]
      binds[#binds + 1] = {
        clusterId = b.clusterId,
        srcEndpoint = b.srcEndpoint,
        dstEndpoint = b.dstEndpoint,
        dstDeviceEuid = b.dstDeviceEuid,
      }
    end
    return { status = "ZDO_STATUS_SUCCESS", statusInt = 0, entries = #ctl.table, startIndex = start, binds = binds }
  end

  -- zserver's diff reads an EUI64 as a number, so its case does not matter.
  local function matches(rec, e)
    return rec.clusterId == e.clusterId
      and rec.srcEndpoint == e.srcEndpoint
      and rec.dstEndpoint == e.dstEndpoint
      and rec.dstDeviceEuid:upper() == e.dstDeviceEuid:upper()
  end

  local function has(list, rec)
    for _, e in ipairs(list) do
      if matches(e, rec) then
        return true
      end
    end
    return false
  end

  -- zserver publishes its list with each state, which is how Director hears it.
  local function publish(state, list)
    ctl.published = list or ctl.held
    fire("config", { state = state })
  end

  local function refusal(rec)
    local st = ctl.answers[rec.srcEndpoint * 65536 + rec.clusterId]
    if st ~= nil and not V2_DISABLING[st] then
      error("shim: a status zserver retries on a timer was not modelled")
    end
    return st
  end

  -- zserver's sync: it reads the whole table (its pages reach the driver too), unbinds
  -- every unicast record the list lacks, then binds what is missing in list order.
  -- A disabling answer stops it there.
  local function sync()
    for start = 0, math.max(#ctl.table - 1, 0), 3 do
      fire("table", page(start))
    end
    local kept = {}
    for i, rec in ipairs(ctl.table) do
      if not has(ctl.held, rec) then
        if refusal(rec) then
          for j = i, #ctl.table do
            kept[#kept + 1] = ctl.table[j]
          end
          ctl.table, ctl.state = kept, "disabled"
          return publish("disabled")
        end
      else
        kept[#kept + 1] = rec
      end
    end
    ctl.table = kept
    for _, e in ipairs(ctl.held) do
      if not has(ctl.table, e) then
        if refusal(e) then
          ctl.state = "disabled"
          return publish("disabled")
        end
        ctl.table[#ctl.table + 1] = {
          clusterId = e.clusterId,
          srcEndpoint = e.srcEndpoint,
          dstEndpoint = e.dstEndpoint,
          dstDeviceEuid = e.dstDeviceEuid:upper(),
        }
      end
    end
    ctl.state = "synced"
    publish("synced")
  end

  -- Director sends a list only when it differs from the one zserver last published: as
  -- many entries, and each found there on cluster and source endpoint, and on what else
  -- it names, its EUI64 byte for byte. The coordinator named in upper case after none
  -- was sent, lower after upper sent, and none after lower were skipped. After a
  -- Director restart the drivers' Sets, 0.4 to 1 s after addZ3Node, were compared with
  -- the list zserver held before Director's empty one.
  local function found(e)
    for _, p in ipairs(ctl.published) do
      if
        p.clusterId == e.clusterId
        and p.srcEndpoint == e.srcEndpoint
        and (e.dstEndpoint == nil or p.dstEndpoint == e.dstEndpoint)
        and (e.dstDeviceEuid == nil or p.dstDeviceEuid == e.dstDeviceEuid)
      then
        return true
      end
    end
    return false
  end
  -- zserver takes a new list at once, so it replaces a sync still waiting, and is
  -- pending about 5 ms later. What an entry leaves out it fills in: the coordinator's
  -- EUI64 in lower case and its endpoint; what it names it keeps as given.
  local function send(entries)
    local same = #entries == #ctl.published
    for _, e in ipairs(entries) do
      same = same and found(e)
    end
    if same then
      return
    end
    ctl.syncs = ctl.syncs + 1
    ctl.held = {}
    for i, e in ipairs(entries) do
      ctl.held[i] = {
        clusterId = e.clusterId,
        srcEndpoint = e.srcEndpoint,
        dstEndpoint = e.dstEndpoint or v2Endpoint(e.clusterId),
        dstDeviceEuid = e.dstDeviceEuid or ctl.coord:lower(),
      }
    end
    ctl.state = "pending"
    for i = #ctl.queue, 1, -1 do
      if ctl.queue[i].kind == "sync" then
        table.remove(ctl.queue, i)
      end
    end
    ctl.queue[#ctl.queue + 1] = { kind = "config", state = "pending" }
    ctl.queue[#ctl.queue + 1] = { kind = "sync" }
  end

  local methods = {}
  function methods:Init()
    ctl.inits = ctl.inits + 1
    reg.obj = self
    return 0
  end
  for name, slot in pairs(V2_SLOTS) do
    methods[name] = function(self, ...)
      if select("#", ...) < 1 then
        error("Not enough arguments passed (expected 1: func)")
      end
      if type((...)) ~= "function" then
        error("func should be a function")
      end
      self._cb[slot] = (...)
      return self
    end
  end
  function methods:SendZdoGetBindTable(...)
    if select("#", ...) < 1 then
      error("Not enough arguments passed (expected 1: index)")
    end
    local index = v2Int((...))
    if index == nil then
      error("index should be a number")
    end
    local cmd = { kind = "read", startIndex = index }
    if index < 0 then
      ctl.invalid[#ctl.invalid + 1] = cmd
      return 0, "SendZdoGetBindTable invalid index: " .. index
    elseif not ctl.known then
      ctl.invalid[#ctl.invalid + 1] = cmd
      return 0, NOT_FOUND
    elseif ctl.state == "pending" then
      -- zserver took the driver's page as its own, counted phantom records, and stalled.
      ctl.corrupted = true
      error("shim: a table read while zserver syncs corrupts its sync")
    end
    cmd.cid = ctl.nextCid
    ctl.nextCid = ctl.nextCid + 4294967296
    ctl.issued[#ctl.issued + 1] = cmd
    ctl.queue[#ctl.queue + 1] = cmd
    return cmd.cid, ""
  end
  methods.CmdZdoGetBind = methods.SendZdoGetBindTable
  function methods:SetZdoBindConfig(...)
    local list = ...
    if select("#", ...) < 1 or type(list) ~= "table" then
      error("shim: a Set without a list was not modelled")
    end
    local entries = {}
    for i, e in ipairs(list) do
      local c, s, d = v2Int(e.clusterId), v2Int(e.srcEndpoint), v2Int(e.dstEndpoint or 0)
      local eui = e.dstDeviceEuid or ""
      if c == nil or s == nil or d == nil or type(eui) ~= "string" then
        error("shim: only entries of { clusterId, srcEndpoint, dstEndpoint, dstDeviceEuid } are modelled")
      elseif c < 1 then
        ctl.invalid[#ctl.invalid + 1] = list
        return 0, "SetZdoBindConfig entry " .. i .. " invalid clusterId: " .. c
      elseif c > 0xFFFF or s < 1 or s > 240 or d < 0 or d > 240 then
        error("shim: a cluster past 16 bits or an endpoint outside 1-240 was not modelled")
      elseif eui ~= "" and not (#eui == 16 and eui:match("^%x+$")) then
        error("shim: an EUI64 zserver cannot read as 16 hex digits was not modelled")
      end
      entries[i] =
        { clusterId = c, srcEndpoint = s, dstEndpoint = d ~= 0 and d or nil, dstDeviceEuid = eui ~= "" and eui or nil }
    end
    -- As every device-level call answered before Director added the device.
    if not ctl.known then
      ctl.invalid[#ctl.invalid + 1] = list
      return 0, NOT_FOUND
    end
    ctl.list = entries
    send(entries)
    return 1, ""
  end
  function methods:GetZdoBindConfig()
    local out = {}
    for i, e in ipairs(ctl.list or {}) do
      out[i] = {
        clusterId = e.clusterId,
        srcEndpoint = e.srcEndpoint,
        dstEndpoint = e.dstEndpoint,
        dstDeviceEuid = e.dstDeviceEuid,
      }
    end
    return out, ""
  end

  local mt = {
    __index = function(_, key)
      local m = methods[key]
      return function(...)
        ctl.calls[key] = (ctl.calls[key] or 0) + 1
        if m == nil then
          error("shim: ZigbeeV2:" .. tostring(key) .. " is not modelled")
        end
        return m(...)
      end
    end,
  }
  C4.ZigbeeV2 = function()
    ctl.made = ctl.made + 1
    local obj = setmetatable({ _cb = {}, _id = ctl.made }, mt)
    -- Collecting ANY object unregisters the device's callbacks, whichever object
    -- registered them.
    obj._gc = newproxy(true)
    getmetatable(obj._gc).__gc = function()
      ctl.collected = ctl.collected + 1
      reg.obj = nil
    end
    ctl.live[ctl.made] = obj
    return obj
  end

  --- The callbacks the device's registered object holds, or nil: what a test plays
  --- by hand for an answer or a state the controller was not asked for. Each is a
  --- call of its own, so the store has landed what the calls before it wrote.
  function ctl.cb()
    if not reg.obj then
      return nil
    end
    return setmetatable({}, {
      __index = function(_, slot)
        local fn = reg.obj and reg.obj._cb[slot]
        return fn and function(...)
          ShimPersistLand()
          return fn(...)
        end
      end,
    })
  end

  local function answer(cmd)
    local seq = {
      { 61445, "ZSTATUS_QUEUE_RECEIVED" },
      { 5, "ZSTATUS_IN_PROGRESS" },
      { 0, "ZSTATUS_OK" },
    }
    for i = cmd.accepted and 3 or 1, 3 do
      fire("status", cmd.cid, seq[i][1], seq[i][2])
    end
    -- StartIndex is one byte on the air: 256 was answered as 0.
    fire("table", page(cmd.startIndex % 256))
  end

  --- Work through the oldest `n` items (all, including ones queued meanwhile, when n
  --- is nil) in order: the device's answers to reads, zserver's states and syncs, and
  --- a restart's second add. While ctl.asleep nothing past a read or a sync is done.
  function ctl.deliver(n)
    local done = 0
    while #ctl.queue > 0 and (n == nil or done < n) do
      local item = ctl.queue[1]
      if ctl.asleep and item.kind ~= "config" and item.kind ~= "add" then
        break
      end
      table.remove(ctl.queue, 1)
      if item.kind == "read" then
        answer(item)
      elseif item.kind == "config" then
        publish(item.state, item.list)
      elseif item.kind == "add" then
        send(ctl.list or {})
      else
        sync()
      end
      done = done + 1
    end
    return done
  end

  --- zserver takes the oldest `n` reads (all when nil) for a sleepy device that is
  --- asleep: queued, then in progress, until deliver() answers them at its wake.
  function ctl.accept(n)
    local done = 0
    for _, cmd in ipairs(ctl.queue) do
      if n ~= nil and done >= n then
        break
      end
      if cmd.kind == "read" and not cmd.accepted then
        cmd.accepted = true
        fire("status", cmd.cid, 61445, "ZSTATUS_QUEUE_RECEIVED")
        fire("status", cmd.cid, 5, "ZSTATUS_IN_PROGRESS")
        done = done + 1
      end
    end
    return done
  end

  --- The device and zserver go quiet: nothing queued so far is ever done.
  function ctl.silence()
    ctl.queue = {}
  end

  --- Director restarts: it loses its copy of the list and has not added the device,
  --- while zserver keeps the list it holds and its state.
  function ctl.restart()
    ctl.list, ctl.known = {}, false
    retained = ctl.state and { state = ctl.state, list = ctl.held }
    readd = true
  end

  --- Director hears the device ONLINE, as at addZ3Node: it sends its own copy of the
  --- list when it differs from the one zserver last published, an empty one after a
  --- restart, and the driver first hears the state zserver kept (behind its Set).
  --- After a restart zserver's own ONLINE for the device, before any state it publishes,
  --- adds it again, and Director sends its copy again where it differs.
  function ctl.online()
    if readd then
      ctl.queue[#ctl.queue + 1] = { kind = "add" }
      readd = nil
    end
    if retained then
      ctl.queue[#ctl.queue + 1] = { kind = "config", state = retained.state, list = retained.list }
      retained = nil
    end
    send(ctl.list or {})
  end

  return ctl
end

--- Remove C4:ZigbeeV2 again, back to a controller without it.
function ShimRemoveZigbeeV2()
  C4.ZigbeeV2 = nil
end

return true
