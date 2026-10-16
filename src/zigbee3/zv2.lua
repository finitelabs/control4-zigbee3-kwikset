--- The controller's own Zigbee 3 driver API, C4:ZigbeeV2(), from OS 4.3.
---
--- The object acts on the calling driver's own device: the bind list zserver keeps
--- for it (SetZdoBindConfig) and a read of its binding table for zbind.lua, the
--- coordinator's interview of the device for deviceinfo.lua, and the device's online
--- status for device.lua. None of it is documented; every shape here was measured on
--- a 4.3.0 controller.
---
--- One object serves the driver, held for its life: collecting any ZigbeeV2 object
--- unregisters the device's callbacks, whichever object registered them. It is
--- Init()ed and given three callbacks when zbind.lua first needs it: the read's
--- status, the table page, and the bind list's state. No check-in or ZCL handler is
--- ever set on it.

require("drivers-common-public.global.timer") -- SetTimer / CancelTimer, ONE_SECOND
local log = require("lib.logging")
local deferred = require("deferred")

-- OnZdoSentStatus codes. Any other code ends the read.
local ST_OK = 0
local ST_IN_PROGRESS = 5
local ST_QUEUE_RECEIVED = 61445
local TIMER_READ = "ZV2Read"

--- @class ZV2
--- @field zb userdata|nil The driver's ZigbeeV2 object: nil until first asked, and a miss is tried again by the next call.
--- @field read { cid: integer, at: integer, taken: boolean?, page: Deferred }|nil The one table read out.
--- @field listener fun(state: string)|nil Who hears the bind list's state: zbind.lua's binder for the device.
--- @field unheard string|nil The last state no binder heard: a re-pair's binder is made only after the interview, and the pending of Director's list can come before it.
--- @field ready userdata|nil The object once Init() and the callbacks took; a failed Init() (the Zigbee manager not up yet) is tried again by the next call.
local ZV2 = {}
ZV2.__index = ZV2

-- zserver took a sleepy device's command up to 840 s after it was sent (622), then
-- ended it within 60 s: these bounds only end a read whose status was lost.
ZV2.CMD_TAKE_MS = 15 * ONE_MINUTE
-- Every page that followed its read's ok came within a second of it.
ZV2.CMD_WAIT_MS = 15 * ONE_SECOND

--- @return ZV2 zv2 The driver's one ZigbeeV2 service.
function ZV2:new()
  local instance = setmetatable({}, self)
  instance.zb = nil
  instance.read = nil
  instance.listener = nil
  instance.unheard = nil
  instance.ready = nil
  return instance
end

--- The driver's ZigbeeV2 object, or nil where C4:ZigbeeV2 is missing.
--- @return userdata|nil zb
function ZV2:object()
  if self.zb == nil then
    local ok, obj = pcall(function()
      return C4:ZigbeeV2()
    end)
    self.zb = (ok and obj) or nil
  end
  return self.zb
end

--- The device's status as the Zigbee server holds it, "ONLINE" or "OFFLINE"; false for a device
--- the Zigbee manager does not have, as before Director adds it; nil where none can be read.
--- @return string|false|nil status
function ZV2:status()
  local obj = self:object()
  local ok, st = pcall(function()
    return obj and obj:GetSysDeviceStatus()
  end)
  local status = ok and type(st) == "table" and st.status
  if status == "ONLINE" or status == "OFFLINE" then
    return status
  end
  if obj and ok and st == nil then
    return false
  end
  return nil
end

--- A 16-digit upper-case hex EUI64 from the API's hex string, or nil.
local function hexEui(v)
  if type(v) ~= "string" then
    return nil
  end
  local h = v:gsub("[^%x]", ""):upper()
  if h == "" or #h > 16 then
    return nil
  end
  return string.rep("0", 16 - #h) .. h
end

local function int(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function call(fn, ...)
  if fn then
    local ok, err = pcall(fn, ...)
    if not ok then
      log:warn("ZBind: a Zigbee API handler failed: %s", tostring(err))
    end
  end
end

--- End the read out: resolved with its page, or rejected with why none came.
--- @private
--- @param page table|nil
--- @param why? string
function ZV2:_finish(page, why)
  local r = self.read
  self.read = nil
  CancelTimer(TIMER_READ)
  if page then
    r.page:resolve(page)
  else
    r.page:reject(why or "no page came")
  end
end

--- A read's status from OnZdoSentStatus.
--- @private
--- @param cid integer The command it is for.
--- @param st integer
function ZV2:_onStatus(cid, st)
  if not (self.read and self.read.cid == cid) then
    return
  end
  if st == ST_OK then
    self.read.taken = true
    SetTimer(TIMER_READ, ZV2.CMD_WAIT_MS, function()
      self:_finish(nil, "no page after the read's ok")
    end)
  elseif st == ST_QUEUE_RECEIVED or st == ST_IN_PROGRESS then
    self.read.taken = true
  else
    log:debug("ZBind: the table read ended with status %s", tostring(st))
    self:_finish(nil, "the read ended with status " .. tostring(st))
  end
end

--- A page from OnZdoGetBindTableResponse.
--- @private
--- @param t table
function ZV2:_onTable(t)
  -- zserver's own sync pages reach this callback too: only the page for the read out,
  -- once zserver has taken it, is the read's (617's came between its in progress and ok).
  local at = type(t) == "table" and tonumber(t.startIndex)
  if not (self.read and self.read.taken and at == self.read.at) then
    return
  end
  if t.statusInt ~= 0 then
    log:debug("ZBind: the device answered the table read with %s", tostring(t.status or t.statusInt))
    return self:_finish(nil, "the device answered " .. tostring(t.status or t.statusInt))
  end
  local records = {}
  for _, b in ipairs(type(t.binds) == "table" and t.binds or {}) do
    records[#records + 1] =
      { srcEp = b.srcEndpoint, cluster = b.clusterId, dstEp = b.dstEndpoint, dst = hexEui(b.dstDeviceEuid) }
  end
  local total = tonumber(t.entries)
  self:_finish({
    records = records,
    count = #records,
    atEnd = #records == 0 or (total ~= nil and at + #records >= total),
  })
end

--- The object, Init()ed and given its callbacks, or nil where it will not take them.
--- @private
--- @return userdata|nil zb
function ZV2:_api()
  if self.ready then
    return self.ready
  end
  local obj = self:object()
  if not obj then
    return nil
  end
  local okInit, rc = pcall(function()
    return obj:Init()
  end)
  if not okInit or (rc ~= nil and rc ~= 0) then
    log:warn("ZBind: the Zigbee API did not initialise (%s)", tostring(rc))
    return nil
  end
  local function guard(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        log:debug("ZBind: Zigbee API callback: %s", tostring(err))
      end
    end
  end
  local okCb = pcall(function()
    obj:OnZdoSentStatus(guard(function(cid, st)
      self:_onStatus(cid, st)
    end))
    obj:OnZdoGetBindTableResponse(guard(function(t)
      self:_onTable(t)
    end))
    obj:OnZdoBindConfigStatusEvent(guard(function(t)
      if type(t) == "table" and type(t.state) == "string" then
        if self.listener then
          call(self.listener, t.state)
        else
          self.unheard = t.state
        end
      end
    end))
  end)
  if not okCb then
    return nil
  end
  self.ready = obj
  return self.ready
end

--- Hand the bind list's state (pending, synced, disabled, unknown) to `fn`, first the
--- last one no binder heard. nil stops it.
--- @param fn fun(state: string)|nil
function ZV2:onState(fn)
  self.listener = fn
  local state = fn and self.unheard
  if state then
    self.unheard = nil
    call(fn, state)
  end
end

--- Give zserver the device's whole list of unicast binds, each { clusterId,
--- srcEndpoint }, and optionally dstEndpoint and dstDeviceEuid; zserver fills in what
--- is left out, the coordinator's EUI64 and the coordinator endpoint it picks. Never
--- empty, since an empty list unbinds everything. Returns true, or false and why not.
--- @param entries table[]|nil
--- @return boolean ok
--- @return string|nil why
function ZV2:setList(entries)
  if type(entries) ~= "table" or #entries == 0 then
    return false, "an empty list would unbind everything"
  end
  -- The API refuses cluster 0 (measured); an endpoint is 1 to 240, and zserver reads
  -- an EUI64 as a hex number without checking it.
  for i, e in ipairs(entries) do
    if
      not int(e.clusterId, 1, 0xFFFF)
      or not int(e.srcEndpoint, 1, 240)
      or (e.dstEndpoint ~= nil and not int(e.dstEndpoint, 1, 240))
      or (
        e.dstDeviceEuid ~= nil
        and not (type(e.dstDeviceEuid) == "string" and e.dstDeviceEuid:match("^%x+$") and #e.dstDeviceEuid == 16)
      )
    then
      return false, "entry " .. i .. " cannot be listed"
    end
  end
  local obj = self:_api()
  if not obj then
    return false, "the Zigbee API is unavailable"
  end
  local ok, rc, msg = pcall(function()
    return obj:SetZdoBindConfig(entries)
  end)
  if ok and type(rc) == "number" and rc ~= 0 then
    return true
  end
  return false, tostring(ok and msg or rc)
end

--- Read a page of the device's binding table from `startIndex`: resolves with
--- { records = { {srcEp, cluster, dstEp, dst} }, count, atEnd }, or rejects with why none
--- came. A new read replaces one still out, which rejects. Nil when none went.
--- @param startIndex integer
--- @return Deferred<table, string>|nil page
function ZV2:readTable(startIndex)
  local obj = int(startIndex, 0, 255) and self:_api()
  if not obj then
    return nil
  end
  local ok, cid = pcall(function()
    return obj:SendZdoGetBindTable(startIndex)
  end)
  if not ok or type(cid) ~= "number" or cid == 0 then
    log:debug("ZBind: the Zigbee API did not send the table read: %s", tostring(cid))
    return nil
  end
  if self.read then
    self:_finish(nil, "a newer read replaced it")
  end
  local page = deferred.new()
  self.read = { cid = cid, at = startIndex, page = page }
  SetTimer(TIMER_READ, ZV2.CMD_TAKE_MS, function()
    self:_finish(nil, "zserver did not take the read")
  end)
  return page
end

return ZV2:new()
