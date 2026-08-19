--- Establishes Zigbee 3.0 bindings from a joined device to the controller's
--- coordinator, so the device pushes unsolicited ZCL reports and operation
--- events over the mesh instead of only answering polls.
---
--- Zigbee delivers unsolicited traffic only to destinations in the device's own
--- binding table, and on this platform nothing populates that table: zserver
--- rejects driver-originated ZDO, and there is no documented API for it. The
--- one path that works is zserver's own (unreleased, versioned) public API,
--- reached over the controller's local MQTT broker on an anonymous unix socket.
--- This module speaks that API: it publishes a ZDO Bind request through it, the
--- daemon transmits the real over-the-air bind, and from then on the device's
--- events arrive through the ordinary OnZigbeePacketIn path.
---
--- The bind lives in the device and persists across driver reloads, so this only
--- needs to run at join/online. It is a best-effort enhancement: if any step
--- fails the driver keeps working on its state poll.
---
--- Fragility note: the transport, topic scheme, and protobuf field numbers here
--- are undocumented zserver internals and may change with a controller OS
--- update. When the official Zigbee 3.0 driver API ships, replace the transport
--- with the sanctioned client and keep the bind flow.

require("lib.utils") -- tointeger
require("drivers-common-public.global.timer") -- SetTimer/CancelTimer, ONE_SECOND
local log = require("lib.logging")
local persist = require("lib.persist")

local SOCK_PATH = "/var/run/mosquitto/mosquitto.sock"
local DRAIN_MS = 250
local DRAIN_MAX = 16
local STEP_TIMEOUT_MS = 6 * ONE_SECOND
local TIMER_DRAIN = "ZBindDrain"
local TIMER_STEP = "ZBindStep"
-- zserver rejects a ZDO sequence above 127 (ZSTATUS_INVALID_PARAMETER).
local ZDO_SEQ_MAX = 127
-- ZDO clusters.
local ZDO_MGMT_BIND_REQ = 0x0033
local ZDO_BIND_REQ = 0x0021
-- ExecStatus codes seen from zserver.
local EXEC_OK = 0
local EXEC_IN_PROGRESS = 5
local EXEC_QUEUE_RECEIVED = 61445
local EXEC_INCORRECT_GATEWAY_ENDPOINT = 61447
-- Coordinator endpoints to try for the bind destination, best first. zserver
-- reports INCORRECT_GATEWAY_ENDPOINT for a wrong one, which makes it probeable.
local GW_EP_CANDIDATES = { 2, 1, 3, 4 }

--- @class ZBind
local ZBind = {}
ZBind.__index = ZBind

--- @return ZBind
function ZBind:new()
  local instance = setmetatable({
    sock = nil,
    buf = "",
    seq = 0,
    pid = 0,
    state = "idle",
    awaiting = nil, -- function(topic, payload) for the current step
  }, self)
  return instance
end

-- ---------------------------------------------------------------------------
-- Protobuf encoding (hand-rolled; matches zserver's c4.z3pb wire format)
-- ---------------------------------------------------------------------------

local function pbVarint(n)
  local o = {}
  -- Clamp: a negative n would spin the repeat forever (floor(n/128) never
  -- reaches 0), and this runs on the single Lua thread the step timeout cannot
  -- preempt. All real inputs are non-negative field numbers/values.
  n = math.max(0, math.floor(n))
  repeat
    local b = n % 128
    n = math.floor(n / 128)
    if n > 0 then
      b = b + 128
    end
    o[#o + 1] = string.char(b)
  until n == 0
  return table.concat(o)
end

local function pbTag(field, wire)
  return pbVarint(field * 8 + wire)
end

local function pbVI(field, v)
  return pbTag(field, 0) .. pbVarint(v)
end

local function pbLD(field, data)
  return pbTag(field, 2) .. pbVarint(#data) .. data
end

-- EUI64 values exceed 2^53 and cannot be held exactly by a Lua number, so they
-- are never converted: a hex string becomes 8 little-endian bytes.
local function pbF64Hex(field, hex)
  hex = tostring(hex or ""):gsub("[^%x]", "")
  while #hex < 16 do
    hex = "0" .. hex
  end
  local b = {}
  for i = 1, 16, 2 do
    b[#b + 1] = tonumber(hex:sub(i, i + 1), 16) or 0
  end
  local o = {}
  for i = 8, 1, -1 do
    o[#o + 1] = string.char(b[i])
  end
  return pbTag(field, 1) .. table.concat(o)
end

local function w32(v)
  v = v % 4294967296
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- zserver validates this correlation id against its own clock and rejects one
-- outside the window. high32 = seconds since the c4 cid epoch, low32 = a
-- sub-second fraction plus the sequence.
local CID_EPOCH = 1733396428
local function pbCid(field, seq)
  local ms = 0
  local ok, t = pcall(function()
    return C4:GetTime()
  end)
  if ok and type(t) == "number" then
    ms = t
  elseif os and os.time then
    ms = os.time() * 1000
  end
  local secs = math.floor(ms / 1000) - CID_EPOCH
  local frac = (math.floor((ms % 1000) * 4294967) + seq) % 4294967296
  return pbTag(field, 1) .. w32(frac) .. w32(secs)
end

-- ---------------------------------------------------------------------------
-- Protobuf decoding (one level of fields; enough to read ZDO responses)
-- ---------------------------------------------------------------------------

--- Walk one level of protobuf fields into { [field] = value }. Length-delimited
--- and fixed64 values are returned as raw strings; varints as numbers.
local function pbFields(buf)
  local out, i = {}, 1
  while i <= #buf do
    local key, mult, k = 0, 1, i
    while k <= #buf do
      local b = string.byte(buf, k)
      key = key + (b % 128) * mult
      mult = mult * 128
      k = k + 1
      if b < 128 then
        break
      end
    end
    if k > #buf then
      break
    end
    local field, wire = math.floor(key / 8), key % 8
    i = k
    if wire == 2 then
      local n, m2 = 0, 1
      while i <= #buf do
        local b = string.byte(buf, i)
        n = n + (b % 128) * m2
        m2 = m2 * 128
        i = i + 1
        if b < 128 then
          break
        end
      end
      if n > #buf - i + 1 then
        break
      end
      out[field] = buf:sub(i, i + n - 1)
      i = i + n
    elseif wire == 0 then
      local v, m2 = 0, 1
      while i <= #buf do
        local b = string.byte(buf, i)
        v = v + (b % 128) * m2
        m2 = m2 * 128
        i = i + 1
        if b < 128 then
          break
        end
      end
      out[field] = v
    elseif wire == 1 then
      out[field] = buf:sub(i, i + 7)
      i = i + 8
    elseif wire == 5 then
      out[field] = buf:sub(i, i + 3)
      i = i + 4
    else
      break
    end
  end
  return out
end

--- Normalize a value to a 16-hex-digit EUI64 string, or nil if it is not one.
--- persist:get returns an empty-table sentinel (not nil) for a missing key, so a
--- cached coordinator must be validated as a real address before it is trusted.
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

--- 8 little-endian bytes -> a big-endian EUI64 hex string.
local function hexLE(s)
  if type(s) ~= "string" or #s < 8 then
    return nil
  end
  local o = {}
  for i = 8, 1, -1 do
    o[#o + 1] = string.format("%02X", string.byte(s, i))
  end
  return table.concat(o)
end

-- ---------------------------------------------------------------------------
-- MQTT 3.1.1 over the anonymous local unix socket
-- ---------------------------------------------------------------------------

local function mqLen(n)
  local o = {}
  repeat
    local b = n % 128
    n = math.floor(n / 128)
    if n > 0 then
      b = b + 128
    end
    o[#o + 1] = string.char(b)
  until n == 0
  return table.concat(o)
end

local function mqStr(s)
  return string.char(math.floor(#s / 256) % 256, #s % 256) .. s
end

function ZBind:rawSend(pkt)
  if not self.sock then
    return false
  end
  local ok = pcall(function()
    self.sock:send(pkt)
  end)
  return ok
end

function ZBind:publish(topic, payload)
  local body = mqStr(topic) .. payload
  return self:rawSend(string.char(0x30) .. mqLen(#body) .. body)
end

function ZBind:subscribe(topic)
  self.pid = (self.pid % 65535) + 1
  local body = string.char(math.floor(self.pid / 256), self.pid % 256) .. mqStr(topic) .. string.char(0x00)
  return self:rawSend(string.char(0x82) .. mqLen(#body) .. body)
end

--- Parse whatever MQTT packets have accumulated, dispatching PUBLISH payloads
--- and marking the CONNACK.
function ZBind:parse()
  while true do
    if #self.buf < 2 then
      return
    end
    local b1 = string.byte(self.buf, 1)
    local mult, val, i = 1, 0, 2
    while true do
      if i > #self.buf then
        return
      end
      local b = string.byte(self.buf, i)
      val = val + (b % 128) * mult
      mult = mult * 128
      i = i + 1
      if b < 128 then
        break
      end
      if mult > 2097152 then
        self.buf = ""
        return
      end
    end
    local total = (i - 1) + val
    if #self.buf < total then
      return
    end
    local body = self.buf:sub(i, total)
    self.buf = self.buf:sub(total + 1)
    local ptype = math.floor(b1 / 16)
    if ptype == 2 then
      self.connected = true
      self:onConnack()
    elseif ptype == 3 then
      if #body >= 2 then
        local tl = string.byte(body, 1) * 256 + string.byte(body, 2)
        local topic = body:sub(3, 2 + tl)
        local payload = body:sub(3 + tl)
        if self.awaiting then
          local ok, err = pcall(self.awaiting, self, topic, payload)
          if not ok then
            log:debug("zbind message handler: %s", tostring(err))
          end
        end
      end
    end
  end
end

function ZBind:drain()
  if not self.sock then
    return
  end
  for _ = 1, DRAIN_MAX do
    local ok, data, err, partial = pcall(function()
      return self.sock:receive(2048)
    end)
    if not ok then
      return
    end
    local chunk = data or partial
    if chunk == nil or #chunk == 0 then
      break
    end
    self.buf = self.buf .. chunk
    if err == "closed" then
      self:close()
      return
    end
  end
  pcall(function()
    self:parse()
  end)
end

function ZBind:connect()
  self:close()
  local ok, unix = pcall(require, "socket.unix")
  if not ok or unix == nil then
    log:warn("zbind: socket.unix unavailable; real-time events disabled")
    return false
  end
  local mk = (type(unix) == "table" and (unix.stream or unix.tcp)) or unix
  if type(mk) ~= "function" then
    return false
  end
  local s = mk()
  local okc = s:connect(SOCK_PATH)
  if not okc then
    log:warn("zbind: broker connect failed")
    pcall(function()
      s:close()
    end)
    return false
  end
  s:settimeout(0)
  self.sock = s
  self.buf = ""
  self.connected = false
  local clientId = "z3bind-" .. tostring(C4:GetDeviceID())
  local vh = mqStr("MQTT") .. string.char(0x04, 0x02, 0x00, 0x3C)
  local body = vh .. mqStr(clientId)
  self:rawSend(string.char(0x10) .. mqLen(#body) .. body)
  SetTimer(TIMER_DRAIN, DRAIN_MS, function()
    self:drain()
  end, true)
  return true
end

function ZBind:close()
  CancelTimer(TIMER_STEP)
  CancelTimer(TIMER_DRAIN)
  if self.sock then
    pcall(function()
      self.sock:close()
    end)
  end
  self.sock = nil
  self.buf = ""
  self.connected = false
  self.awaiting = nil
end

-- ---------------------------------------------------------------------------
-- ZDO over the public API
-- ---------------------------------------------------------------------------

function ZBind:nextSeq()
  self.seq = (self.seq % ZDO_SEQ_MAX) + 1
  return self.seq
end

function ZBind:topicBase()
  return "s1/c4/protected/zigbee3-public-api/v1/" .. self.mac .. "/device/" .. self.eui
end

--- Publish a ZDO command frame to the device via the public API.
function ZBind:sendZdo(zdoCluster, commandFrame)
  local seq = self:nextSeq()
  local aps = pbVI(1, 0) .. pbVI(2, zdoCluster) .. pbVI(3, 0) .. pbVI(4, 0) .. pbVI(5, 16448)
  local frame = pbVI(1, seq) .. pbLD(3, commandFrame)
  local msg = pbCid(1, seq) .. pbF64Hex(2, self.eui) .. pbVI(4, 0) .. pbLD(6, aps) .. pbLD(8, frame)
  local any = pbLD(1, "type.googleapis.com/c4.z3pb.CmdOutgoingZdo") .. pbLD(2, msg)
  self:publish(self:topicBase() .. "/command/send-zdo", any)
end

--- Read the exec-status code out of an exec-status/send-zdo payload, or nil if
--- absent. A missing status must not read as OK: nil leaves the probe handler
--- matching nothing, so it waits out the step timeout rather than treating an
--- unparseable response as a bind that was accepted.
local function execStatus(payload)
  local any = pbFields(payload)
  if type(any[2]) ~= "string" then
    return nil
  end
  return tonumber(pbFields(any[2])[2])
end

--- From an incoming-zdo payload, return the ZDO command frame's fields, or nil.
local function incomingCommandFrame(payload)
  local any = pbFields(payload)
  if type(any[2]) ~= "string" then
    return nil
  end
  local ev = pbFields(any[2])
  if type(ev[8]) ~= "string" then
    return nil
  end
  local frame = pbFields(ev[8])
  if type(frame[3]) ~= "string" then
    return nil
  end
  return pbFields(frame[3])
end

--- Walk a Mgmt_Bind_rsp buffer for the first binding record's destination
--- EUI64. Every binding on a commissioned device points at the coordinator, so
--- any record (typically the pre-existing Poll Control entry) yields its
--- address. Binding records are repeated field 5 (tag 0x2a).
local function coordinatorFromBindingTable(rsp, ownEui)
  local i = 1
  while i <= #rsp do
    if string.byte(rsp, i) == 0x2a then
      local n, m2, k = 0, 1, i + 1
      while k <= #rsp do
        local b = string.byte(rsp, k)
        n = n + (b % 128) * m2
        m2 = m2 * 128
        k = k + 1
        if b < 128 then
          break
        end
      end
      local rec = pbFields(rsp:sub(k, k + n - 1))
      local dst = hexLE(rec[5])
      if dst and dst ~= ownEui then
        return dst
      end
      i = k + n
    else
      i = i + 1
    end
  end
  return nil
end

--- Build a ZDO Bind_req command frame binding one cluster to the coordinator.
function ZBind:bindFrame(srcEp, cluster, gwEp)
  local rec = pbF64Hex(1, self.eui)
    .. pbVI(2, srcEp)
    .. pbVI(3, cluster)
    .. pbVI(4, 3) -- 64-bit extended destination addressing
    .. pbF64Hex(5, self.coordEui)
    .. pbVI(6, gwEp)
  return pbLD(3, rec)
end

-- ---------------------------------------------------------------------------
-- Bootstrap flow (a small state machine advanced by the drain)
-- ---------------------------------------------------------------------------

function ZBind:setStep(name, handler)
  self.state = name
  self.awaiting = handler
  SetTimer(TIMER_STEP, STEP_TIMEOUT_MS, function()
    log:debug("zbind: step '%s' timed out", name)
    self:finish(false)
  end)
end

function ZBind:finish(ok, note)
  CancelTimer(TIMER_STEP)
  self.awaiting = nil
  self.state = "idle"
  if ok then
    log:info(
      "zbind: bound %d cluster(s) to coordinator %s (gateway ep %s)",
      #self.clusters,
      self.coordEui,
      tostring(self.gwEp)
    )
    persist:set("zbindCoordEui", self.coordEui)
    persist:set("zbindGwEp", self.gwEp)
  else
    -- Drop the cached coordinator/endpoint so the next attempt re-discovers from
    -- scratch. A cached bind only probes the one cached endpoint, so a stale or
    -- wrong cached value would otherwise fail identically forever.
    persist:delete("zbindCoordEui")
    persist:delete("zbindGwEp")
    if note then
      log:debug("zbind: %s", note)
    end
  end
  local cb = self.cb
  self.cb = nil
  self:close()
  if cb then
    pcall(cb, ok)
  end
end

function ZBind:onConnack()
  if self.state ~= "connecting" then
    return
  end
  self:subscribe(self:topicBase() .. "/exec-status/send-zdo")
  self:subscribe(self:topicBase() .. "/event/incoming-zdo")
  if self.coordEui then
    self:beginProbe()
  else
    self:beginDiscover()
  end
end

--- DISCOVER: read the binding table to learn the coordinator EUID.
function ZBind:beginDiscover()
  self:setStep("discover", function(_, topic, payload)
    if not topic:find("event/incoming%-zdo") then
      return
    end
    local cf = incomingCommandFrame(payload)
    if not cf or type(cf[8]) ~= "string" then
      return
    end
    local coord = validEui(coordinatorFromBindingTable(cf[8], self.eui))
    if coord then
      self.coordEui = coord
      log:debug("zbind: coordinator discovered %s", coord)
      self:beginProbe()
    end
  end)
  self:sendZdo(ZDO_MGMT_BIND_REQ, pbLD(7, pbVI(1, 0)))
end

--- PROBE: find the coordinator endpoint that accepts a bind (or use the cached
--- one). Bind the first cluster; a wrong endpoint answers
--- INCORRECT_GATEWAY_ENDPOINT, anything else means the endpoint is right.
function ZBind:beginProbe()
  if not validEui(self.coordEui) then
    return self:finish(false, "no valid coordinator to bind to")
  end
  local first = self.clusters[1]
  local candidates = self.gwEp and { self.gwEp } or GW_EP_CANDIDATES
  self.probeIdx = 0
  local function tryNext()
    self.probeIdx = self.probeIdx + 1
    local ep = candidates[self.probeIdx]
    if ep == nil then
      return self:finish(false, "no gateway endpoint accepted the bind")
    end
    self:setStep("probe", function(_, topic, payload)
      if not topic:find("exec%-status/send%-zdo") then
        return
      end
      local st = execStatus(payload)
      if st == EXEC_INCORRECT_GATEWAY_ENDPOINT then
        tryNext()
      elseif st == EXEC_OK or st == EXEC_IN_PROGRESS or st == EXEC_QUEUE_RECEIVED then
        self.gwEp = ep
        self:beginBindRest()
      end
    end)
    self:sendZdo(ZDO_BIND_REQ, self:bindFrame(first.srcEp, first.cluster, ep))
  end
  tryNext()
end

--- BIND: the first cluster is already bound from the probe; fire the rest and
--- finish. These are best-effort; we do not gate success on each response.
function ZBind:beginBindRest()
  for idx = 2, #self.clusters do
    local c = self.clusters[idx]
    self:sendZdo(ZDO_BIND_REQ, self:bindFrame(c.srcEp, c.cluster, self.gwEp))
  end
  self:finish(true)
end

--- Establish real-time bindings for a joined device.
--- @param eui string device EUI64 (hex)
--- @param clusters table[] list of { cluster = int, srcEp = int }
--- @param cb fun(ok: boolean)? called when the flow settles
function ZBind:ensureBinds(eui, clusters, cb)
  if self.state ~= "idle" then
    log:debug("zbind: already running (%s); ignoring", self.state)
    if cb then
      pcall(cb, false)
    end
    return
  end
  if type(eui) ~= "string" or eui == "" or type(clusters) ~= "table" or #clusters == 0 then
    if cb then
      pcall(cb, false)
    end
    return
  end
  self.eui = eui:gsub("[^%x]", ""):upper()
  self.clusters = clusters
  self.cb = cb
  self.mac = tostring(C4:GetUniqueMAC()):gsub("[^%x]", ""):upper()
  self.coordEui = validEui(persist:get("zbindCoordEui", ""))
  local gw = tointeger(persist:get("zbindGwEp", 0))
  self.gwEp = (gw and gw > 0) and gw or nil
  if not self:connect() then
    return self:finish(false, "connect failed")
  end
  self:setStep("connecting", nil)
end

return ZBind
