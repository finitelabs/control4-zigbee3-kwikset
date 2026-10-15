--- Keeps the lock's real-time bind: the record in its binding table that makes it push
--- DoorLock operation events and reports to the coordinator.
---
--- Zigbee delivers unsolicited traffic only to destinations in the device's own
--- binding table, and a driver cannot send ZDO over SendZigbeePacket. The driver
--- does not bind either. It gives zserver the device's whole list of binds through
--- the controller's Zigbee API (zigbee/zv2.lua), and zserver reads the device's
--- table, unbinds every unicast record not in the list, binds what is missing in
--- list order, retries, and waits for a sleepy device to wake. It reports a state
--- for the whole list: pending, synced, disabled, or unknown after it restarts.
---
--- The table is read here only when zserver is idle and only the table can answer:
--- after synced, the coordinator it names; after disabled, the entry the device
--- refused; after a rejoin, whether the device lost its table, which zserver does not
--- notice. A question a read left open is asked again when the device next speaks.
--- zserver's own read takes any page it hears, so nothing is read while it syncs and
--- no list is set while a read is out.
---
--- The driver uses apply, check, wake and close, and gives the two hooks below.

require("drivers-common-public.global.timer") -- SetTimer / CancelTimer, ONE_SECOND
local log = require("lib.logging")
local persist = require("lib.persist")
local ZV2 = require("zigbee.zv2")

-- The list's record { eui, refused, state, form }, kept for the device at eui.
local PERSIST_LIST = "zbindList"
-- The coordinator's EUI64, learned from a binding table, and the Zigbee server
-- (controller) it belongs to.
local PERSIST_COORD = "zbindCoordEui"
local PERSIST_COORD_ZSERVER = "zbindCoordZserver"
-- Until Director has added the device its address does not resolve and a Set
-- answers "Device not found in Zigbee Manager": tried every second, then every
-- minute once this long has passed.
local TIMER_APPLY = "ZBindApply"
local RETRY_FAST_S = 300
-- A rejoin waits this long for zserver's own sync to announce itself.
local TIMER_CHECK = "ZBindCheck"
local CHECK_WAIT_MS = 10 * ONE_SECOND
-- After a list set while stale a state other than pending is taken once this long passes
-- with none after it: a pending followed each state of another list within 0.6 s.
local TIMER_SETTLE = "ZBindSettle"
local SETTLE_MS = 10 * ONE_SECOND
-- Mgmt_Bind_rsp pages hold two or three records; the cap stops a looping device.
local PAGE_CAP = 16
-- Frames ask the table again what it left open at most this often, so a device that
-- keeps talking costs at most a read a quarter hour.
local ASK_INTERVAL_S = 15 * 60
-- A list still pending this long after a frame is set again: zserver retries a failed
-- step within about an hour on a mains device, but after 24 or more on a sleepy one,
-- and a wake meanwhile starts nothing.
local STALL_S = 2 * 60 * 60

--- Key a bind by the (srcEp, cluster) pair its entry names.
local function bindKey(srcEp, cluster)
  return srcEp * 65536 + cluster
end

-- Source endpoint 1-240, as the API takes it.
local function validKey(k)
  return type(k) == "number" and k % 1 == 0 and k >= 65536 and k < 241 * 65536
end

--- Can the list hold this bind? The API refuses cluster 0 (Basic).
local function listable(srcEp, cluster)
  return validKey(bindKey(srcEp, cluster)) and cluster ~= 0
end

--- Normalize a value to a 16-hex-digit EUI64 string, or nil if it is not one.
local function validEui(v)
  if type(v) ~= "string" then
    return nil
  end
  local h = v:gsub("[^%x]", ""):upper()
  if #h ~= 16 or h == "0000000000000000" then
    return nil
  end
  return h
end

local function toSet(list)
  local set = {}
  for _, k in ipairs(type(list) == "table" and list or {}) do
    if validKey(k) then
      set[k] = true
    end
  end
  return set
end

local function toList(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function sameKeys(a, b)
  if not b or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function listed(keys, key)
  for _, k in ipairs(keys or {}) do
    if k == key then
      return true
    end
  end
  return false
end

--- @class ZBind
--- @field address nil|fun():string? The device's EUI64, once Director has added it.
--- @field zserverId nil|fun():number? The Zigbee server (controller) the device is on.
local ZBind = {}
ZBind.__index = ZBind

--- The binder for the driver's device. Its address, and with it the list's record an
--- earlier load kept, is looked up when first needed. `stale` after any load but a
--- driver update: Director then holds no list for the device, and zserver may be
--- syncing an empty one Director pushed.
--- @param stale boolean|nil
--- @return ZBind
function ZBind:new(stale)
  local instance = setmetatable({
    eui = nil, -- the device's EUI64, once `address` gives one
    refused = {}, -- keys the device refused, found by the walk after disabled
    state = nil, -- zserver's last state for the list
    applied = nil, -- the keys this session last set, in list order
    retrySince = nil, -- os.time() of the first failed Set of this attempt
    walking = nil, -- the table walk in flight
    pendingHeard = nil, -- os.time() of the first frame heard while the list is pending
    askedAt = nil, -- os.time() a frame last asked the table
    -- After disabled: nil until the table came back, false while naming the refused
    -- entry waits for a coordinator, true once the table was judged.
    judged = nil,
    form = nil, -- nil (left out), "upper" or "lower": how the last list spelled the coordinator
    -- While zserver's list may not be this driver's: the next list spells the coordinator
    -- the other way, and a sync before it went is not this list's.
    stale = stale or nil,
    -- From a list set while stale until a state stands: { state }, the one to take then.
    settling = nil,
  }, self)
  ZV2:onState(function(state)
    instance:onState(state)
  end)
  return instance
end

--- The device's EUI64, once Director has added it. When it is first known, the list's
--- record an earlier load kept for this device is taken up.
--- @return string|nil
function ZBind:known()
  if not self.eui then
    local ok, eui = pcall(function()
      return self.address and self.address()
    end)
    self.eui = ok and validEui(eui) or nil
    local stored = self.eui and persist:get(PERSIST_LIST, false)
    if type(stored) == "table" and validEui(stored.eui) == self.eui then
      self.refused = toSet(stored.refused)
      -- A state zv2 handed on at ZBind:new is newer than the record's.
      self.state = self.state or (type(stored.state) == "string" and stored.state or nil)
      self.form = (stored.form == "upper" or stored.form == "lower") and stored.form or nil
    end
  end
  return self.eui
end

--- Persist the list's record for the next load: what is refused, the state, and how
--- the coordinator was spelled.
function ZBind:save()
  -- Not before the address is known: the record names the device it was kept for.
  if not self.eui then
    return
  end
  persist:set(PERSIST_LIST, {
    eui = self.eui,
    refused = toList(self.refused),
    state = self.state,
    form = self.form,
  })
end

--- The list as zserver would get it now: each target it can hold that the device has
--- not refused, in the targets' order, their keys, and how it spells the coordinator:
--- as the last list did, or the other way while stale.
--- @return table[] entries
--- @return integer[] keys
--- @return string|nil form
function ZBind:list()
  local entries, keys = {}, {}
  local coord = (self.form or self.stale) and self:coordinator()
  local form = self.form
  if coord and self.stale then
    form = self.form == "upper" and "lower" or "upper"
  end
  local eui = coord and (form == "lower" and coord:lower() or coord)
  for _, t in ipairs(self.targets or {}) do
    local key = bindKey(t.srcEp, t.cluster)
    if listable(t.srcEp, t.cluster) and not self.refused[key] then
      entries[#entries + 1] = { clusterId = t.cluster, srcEndpoint = t.srcEp, dstDeviceEuid = eui }
      keys[#keys + 1] = key
    end
  end
  return entries, keys, form
end

--- Hand zserver the list of `targets` ({ srcEp, cluster }), when it differs from what
--- this session last set: Director skips a list it already holds, so the first call of
--- a session costs nothing either. `hook(settled)` hears every change of state,
--- settled once zserver has synced.
--- @param targets table[]
--- @param hook fun(settled: boolean)|nil
function ZBind:apply(targets, hook)
  self.targets, self.hook = targets, hook
  -- zserver's sync would take the page of a read still out as its own: the read's end
  -- sets the list.
  if self.walking or not ZV2:object() then
    return
  end
  local known = self:known()
  local entries, keys, form = self:list()
  -- An empty list would unbind everything, so a device with nothing to list is left alone.
  if #entries > 0 and (form ~= self.form or not sameKeys(keys, self.applied)) then
    if not (known and self:send(entries, keys, form)) then
      -- Refused until Director adds the device, when it pushes an empty list for it.
      self.stale = true
      self.retrySince = self.retrySince or os.time()
      local wait = os.time() - self.retrySince < RETRY_FAST_S and ONE_SECOND or ONE_MINUTE
      SetTimer(TIMER_APPLY, wait, function()
        self:apply(self.targets, self.hook)
      end)
      return
    end
  end
  CancelTimer(TIMER_APPLY)
  self.retrySince = nil
end

--- Give zserver the list, and record it as this session's.
--- @param entries table[] The list, as ZV2:setList takes it.
--- @param keys integer[] Its targets' keys.
--- @param form string|nil How it spells the coordinator.
--- @return boolean sent
function ZBind:send(entries, keys, form)
  local ok, why = ZV2:setList(entries)
  if not ok then
    log:debug("ZBind: the bind list was not set: %s", tostring(why))
    return false
  end
  if self.stale then
    -- What zserver holds may not be this list: none of it shows until its own state stands.
    self.settling, self.state = { state = self.state }, nil
    if form == self.form then
      self:hold() -- Director may skip it as the list zserver holds: then the last state stands
    end
  end
  if form ~= self.form then
    log:debug("ZBind: the list names the coordinator in %s case, so Director sends it", form)
    -- Kept with the controller it is on now.
    self:keepCoordinator(self:coordinator())
    self.stale = nil
  end
  self.applied, self.form = keys, form
  self:save()
  return true
end

--- The list's state moved: persist it and tell the hook, settled once zserver has synced.
function ZBind:changed()
  self:save()
  if self.hook then
    local ok, err = pcall(self.hook, self.state == "synced" and self.applied ~= nil)
    if not ok then
      log:warn("ZBind: the bind hook failed: %s", tostring(err))
    end
  end
end

--- zserver's state for the list. After a list set while stale the states of other lists
--- can come first, each followed by a pending (after a restart, the one zserver kept and
--- the empty list's), so a state other than pending is taken only once none follows it.
--- @param state string pending, synced, disabled or unknown.
function ZBind:onState(state)
  if self.settling then
    CancelTimer(TIMER_SETTLE)
    if state ~= "pending" then
      self.settling.state = state
      return self:hold()
    end
  end
  self.state = state
  self.judged = nil
  self.pendingHeard = nil
  if state == "pending" then
    -- zserver's sync is running: the page of a read still out is its to take.
    CancelTimer(TIMER_CHECK)
    if self.walking then
      self.walking.dropped = true
    end
  elseif (state == "synced" or state == "disabled") and self.applied then
    self:ask()
  end
  self:changed()
end

--- The state held since a list set while stale is taken once SETTLE_MS pass with none
--- after it.
function ZBind:hold()
  SetTimer(TIMER_SETTLE, SETTLE_MS, function()
    local held = self.settling.state
    self.settling = nil
    if held then
      self:onState(held)
    end
  end)
end

--- Read the table for what is still open: after synced, the coordinator while none is
--- known; after disabled, the entry the device refused, asked again once a coordinator
--- is known when the last read needed one.
function ZBind:ask()
  if self.walking or not self.applied then
    return
  end
  local coord = self:coordinator()
  if self.state == "synced" and not coord then
    self:walk(PAGE_CAP, function(records)
      self:learnCoordinator(records)
      if records and #records == 0 then
        -- Director's empty list synced, and Director now compares with it: set this again.
        self.applied = nil
      end
      self:changed()
    end)
  elseif self.state == "disabled" and not self.judged and (coord or self.judged == nil) then
    self:walk(PAGE_CAP, function(records, complete)
      if complete then
        self:judge(records)
      else
        self:changed()
      end
    end)
  end
end

--- The device spoke, so it is awake: what the table left unanswered is asked again,
--- at most every ASK_INTERVAL_S, and a list zserver still holds pending STALL_S after
--- an earlier frame is set again, as a lost table is.
function ZBind:wake()
  local now = os.time()
  if self.state == "pending" and self.applied then
    self.pendingHeard = self.pendingHeard or now
    if now - self.pendingHeard >= STALL_S then
      self.pendingHeard = nil
      self:respell("zserver's sync has been pending since a frame two hours ago")
    end
  end
  if now - (self.askedAt or 0) >= ASK_INTERVAL_S then
    self.askedAt = now
    self:ask()
  end
end

--- Read the device's table from the start, at most `cap` pages, and hand `done` its
--- records and whether they reach its end, or nil when a page did not come. The list
--- is set once the read is over, since a change of targets waited for it.
--- @param cap integer The most pages to read.
--- @param done fun(records: table[]|nil, complete: boolean|nil)
function ZBind:walk(cap, done)
  local walk = {}
  self.walking = walk
  local records, pages = {}, 0
  local function stop(complete)
    if self.walking ~= walk then
      return
    end
    self.walking = nil
    if not walk.dropped then
      done(complete ~= nil and records or nil, complete)
    end
    self:apply(self.targets, self.hook)
  end
  local function page(at)
    local read = ZV2:readTable(at)
    if not read then
      return stop()
    end
    read
      :next(function(p)
        if self.walking ~= walk then
          return
        elseif walk.dropped then
          return stop()
        end
        for _, r in ipairs(p.records) do
          records[#records + 1] = r
        end
        pages = pages + 1
        if p.atEnd or pages >= cap then
          return stop(p.atEnd)
        end
        page(at + p.count)
      end, function()
        stop()
      end)
      :next(nil, function(err)
        log:warn("ZBind: the table walk failed: %s", tostring(err))
      end)
  end
  page(0)
end

--- A disabled list's table. The entry the device refused is polled from now on, and
--- the walk's end sets the rest.
--- @param records table[]
function ZBind:judge(records)
  local coord = self:coordinator()
  local key = self:culprit(records, coord)
  self.judged = key ~= nil or coord ~= nil
  if key then
    log:info("ZBind: the device refused ep%d cluster 0x%04x; polling it instead", math.floor(key / 65536), key % 65536)
    self.refused[key] = true
  elseif coord then
    log:warn("ZBind: zserver disabled the bind list, and the table names no entry the device refused")
  else
    log:info("ZBind: zserver disabled the bind list; the refused entry can be named once the coordinator is known")
  end
  self:changed()
end

--- The entry a disabled list failed on. zserver unbinds every record the list lacks,
--- then binds the list in order, so once the table holds only the list's records, one
--- per entry and each to the coordinator, it is the first of the driver's entries
--- missing. Any other record stayed because the device refused its unbind, which names
--- none.
--- @param records table[]
--- @param coord string|nil The coordinator's EUI64.
--- @return integer|nil key
function ZBind:culprit(records, coord)
  local held = {}
  for _, r in ipairs(records) do
    local dst = validEui(r.dst)
    if dst then
      local key = dst == coord and r.srcEp and r.cluster and bindKey(r.srcEp, r.cluster)
      if not (key and listed(self.applied, key)) or held[key] then
        return nil
      end
      held[key] = true
    end
  end
  for _, key in ipairs(self.applied) do
    if not held[key] then
      return key
    end
  end
  return nil
end

--- After a rejoin: zserver syncs on a new list only, so a device that came back with
--- an empty table would stay unbound. The table is read, and an empty one sets the
--- list again. A pending state within the wait is zserver's own sync, which cancels
--- this.
function ZBind:check()
  if self.state ~= "synced" or not self.applied or self.walking then
    return
  end
  SetTimer(TIMER_CHECK, CHECK_WAIT_MS, function()
    self:walk(PAGE_CAP, function(records)
      if records then
        self:learnCoordinator(records)
      end
      if records and #records == 0 then
        self:respell("the device lost its binds")
      end
      self:changed()
    end)
  end)
end

--- Set the same list again, the coordinator's EUI64 named in the other case than the
--- last list: Director sends only a list whose named EUI64s differ byte for byte from
--- the list zserver last published, and zserver reads an EUI64 as a number and fills a
--- missing one in lower case, so it syncs the list as the one it already held. With no
--- coordinator known it waits for one.
--- @param why string What the log says moved it.
function ZBind:respell(why)
  if self:coordinator() then
    log:info("ZBind: %s; setting the list again", why)
  else
    log:info("ZBind: %s; the list can be set again once the coordinator is known", why)
  end
  self.stale = true
  self:apply(self.targets, self.hook)
end

-- ---------------------------------------------------------------------------
-- The coordinator
-- ---------------------------------------------------------------------------

--- The Zigbee server (controller) the device is on, or nil when it is not known.
--- @return integer|nil zserver
function ZBind:controller()
  local ok, zs = pcall(function()
    return self.zserverId and self.zserverId()
  end)
  zs = ok and tonumber(zs) or nil
  return (zs and zs >= 0) and zs or nil
end

--- The coordinator this device learned, while it is still on the controller it
--- learned it on. One stored while no controller was known is kept.
--- @return string|nil
function ZBind:coordinator()
  local eui = validEui(persist:get(PERSIST_COORD, ""))
  local learnedOn = tonumber(persist:get(PERSIST_COORD_ZSERVER, ""))
  local now = eui and learnedOn and self:controller()
  if now and now ~= learnedOn then
    return nil
  end
  return eui
end

--- After a sync every unicast record is a listed entry, so the one node the records of
--- the driver's own entries point at is the coordinator.
--- @param records table[]
function ZBind:learnCoordinator(records)
  local only, n, seen = nil, 0, {}
  for _, r in ipairs(records or {}) do
    local dst = validEui(r.dst)
    local key = r.srcEp and r.cluster and bindKey(r.srcEp, r.cluster)
    if dst and dst ~= self.eui and key and listed(self.applied, key) and not seen[dst] then
      seen[dst] = true
      only, n = dst, n + 1
    end
  end
  if n ~= 1 then
    return
  end
  log:debug("ZBind: coordinator %s, read from the device's table", only)
  self:keepCoordinator(only)
end

--- Keep `eui` as this device's coordinator, on the controller it is on now.
--- @param eui string|nil
function ZBind:keepCoordinator(eui)
  persist:set(PERSIST_COORD, eui)
  local zs = self:controller()
  if zs then
    persist:set(PERSIST_COORD_ZSERVER, zs)
  end
end

--- Stop the timers and the walk, and hear no more states (driver teardown).
function ZBind:close()
  CancelTimer(TIMER_APPLY)
  CancelTimer(TIMER_CHECK)
  CancelTimer(TIMER_SETTLE)
  self.walking = nil
  self.retrySince = nil
  ZV2:onState(nil)
end

return ZBind
