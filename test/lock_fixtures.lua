-- Domain fixtures for kwikset_zigbee3_lock, per CONTRIBUTING "Driver-local test
-- support": the driver loaded as Director loads it over a store a suite seeds, the
-- frames the lock answers with, and what the driver sent the lock and told the proxy.
--
-- local F = require("lock_fixtures")
-- F.start({ dstEndpoint = 2, supportsUserCodes = true, keypadKnown = true })

require("c4_shim")
require("c4_local") -- the recorded Zigbee sends, the landing store, the ZigbeeV2 shim
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
local persist = require("lib.persist")

local F = {}

F.DOORLOCK = 0x0101
F.BASIC = 0x0000
F.PROXY = 5001

-- ZCL command ids the suites build and look for.
F.READ_RSP = 0x01
F.WRITE_ATTR = 0x02
F.WRITE_RSP = 0x04
F.DEFAULT_RSP = 0x0b
F.SET_PIN = 0x05
F.GET_PIN = 0x06
F.CLEAR_PIN = 0x07
F.SET_YEARDAY = 0x0e
F.OPER_EVENT = 0x20

-- A keypad lock on its endpoint 2, as a joined Kwikset is stored.
F.KEYPAD = { dstEndpoint = 2, supportsUserCodes = true, keypadKnown = true }

-- The lock's address and controller, as the binder looks them up.
function C4:FindEuidBasedOnNodeId()
  return "00124B0001AABBCC"
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

--- @param v integer
--- @return string bytes v as a little-endian u16.
function F.u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

--- @param v integer
--- @return string bytes v as a little-endian u32.
function F.u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- Each earlier load's zv2, kept: collecting its ZigbeeV2 object would unregister the
-- callbacks of the next, where a controller gives each load a Lua state of its own.
local loads = {}
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
--- Load the driver as Director does after a driver update, over a store holding
--- `seed` (lib.persist keys and values).
--- @param seed table
function F.start(seed)
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
  ShimInstallZigbeeV2()
  load("DIT_UPDATING")
end

--- Load the driver again after a driver update, over what the last load stored.
function F.reload()
  KillAllTimers()
  ShimPersistLand()
  for k in pairs(persist._persist) do
    seeded[k] = true
  end
  persist._persist = {}
  load("DIT_UPDATING")
end

--- What the store holds under a key, as lib.persist decodes it.
--- @param key string
function F.stored(key)
  ShimPersistLand()
  return Deserialize(C4:PersistGetValue(key, false))
end

--- The frames the driver sent the lock since the last call, decoded.
--- @return table[] frames { cluster, specific, seq, cmd, payload }, in order.
function F.sent()
  local out = {}
  for _, p in ipairs(ShimZigbeePackets()) do
    local fc, seq, cmd = p.payload:byte(1, 3)
    out[#out + 1] = {
      cluster = p.clusterId,
      specific = fc % 2 == 1,
      seq = seq,
      cmd = cmd,
      payload = p.payload:sub(4),
    }
  end
  ShimResetZigbeePackets()
  return out
end

--- The DoorLock commands among `frames` with command id `cmd` and the frame type.
--- @param frames table[] From F.sent().
--- @param cmd integer
--- @param specific boolean|nil Cluster-specific (default) or global.
function F.only(frames, cmd, specific)
  local out = {}
  for _, f in ipairs(frames) do
    if f.cluster == F.DOORLOCK and f.cmd == cmd and f.specific == (specific ~= false) then
      out[#out + 1] = f
    end
  end
  return out
end

--- The user id a PIN or schedule command names (its first u16; a schedule's after its id).
--- @param f table A frame from F.sent().
function F.userId(f)
  local at = (f.cmd == F.SET_YEARDAY or f.cmd == 0x0b or f.cmd == 0x0d or f.cmd == 0x10) and 2 or 1
  return f.payload:byte(at) + f.payload:byte(at + 1) * 256
end

--- A frame from the lock arrives on `cluster`, server to client, from its endpoint 2.
--- @param cluster integer
--- @param specific boolean Cluster-specific, else a global command.
--- @param seq integer The sequence it echoes.
--- @param cmd integer
--- @param payload string
function F.receive(cluster, specific, seq, cmd, payload)
  ShimPersistLand()
  local fc = (specific and 0x01 or 0x00) + 0x08
  OnZigbeePacketIn(string.char(fc, seq, cmd) .. payload, 0x0104, cluster, 0, 2, 1)
  ShimPersistLand()
end

--- The lock answers a Read Attributes on DoorLock with `records` (see F.attr).
--- @param records string[]
function F.readResponse(records)
  F.receive(F.DOORLOCK, false, 0x70, F.READ_RSP, table.concat(records))
end

--- A Read Attributes Response record: the attribute's value, or `status` alone.
--- @param id integer
--- @param dtype integer|nil ZCL type, or nil for a status record.
--- @param value integer|nil
--- @param status integer|nil
function F.attr(id, dtype, value, status)
  if dtype == nil then
    return F.u16(id) .. string.char(status)
  end
  local bytes = dtype == 0x21 and F.u16(value) or dtype == 0x23 and F.u32(value) or string.char(value)
  return F.u16(id) .. string.char(0, dtype) .. bytes
end

--- The lock answers a Get PIN for `id`: status 0 available, 1 occupied; no code.
--- @param seq integer
--- @param id integer
--- @param status integer
function F.getPinResponse(seq, id, status)
  F.receive(F.DOORLOCK, true, seq, F.GET_PIN, F.u16(id) .. string.char(status, status == 0 and 0xFF or 0, 0))
end

--- The lock refuses command `cmd` (sent with `seq`) with a Default Response.
function F.defaultResponse(seq, cmd, status)
  F.receive(F.DOORLOCK, false, seq, F.DEFAULT_RSP, string.char(cmd, status))
end

--- Run a lock proxy command as the proxy sends it.
--- @param command string
--- @param params table|nil
function F.proxy(command, params)
  ShimPersistLand()
  RFP[command](F.PROXY, command, params or {})
  ShimPersistLand()
end

--- Everything the proxy was told since the last call, as { command, params }.
function F.told()
  local out = proxied
  proxied = {}
  return out
end

--- The params of the last `command` among notifies from F.told(), or nil.
function F.last(told, command)
  for i = #told, 1, -1 do
    if told[i].command == command then
      return told[i].params
    end
  end
  return nil
end

--- The value the last CAPABILITY_CHANGED for `name` among `told` carried, or nil.
function F.capability(told, name)
  for i = #told, 1, -1 do
    local n = told[i]
    if n.command == "CAPABILITY_CHANGED" and n.params.NAME == name then
      return n.params.VALUE
    end
  end
  return nil
end

--- Fire one named timer now, as its expiry would.
function F.fire(name)
  local h = Timer[name]
  local fn = h and TimerFunctions[h]
  CancelTimer(name)
  ShimPersistLand()
  fn(h, 0)
  ShimPersistLand()
end

return F
