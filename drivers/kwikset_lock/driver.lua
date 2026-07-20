--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "kwikset_lock.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-zigbee3-kwikset"
DRIVER_FILENAMES = { "kwikset_lock.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

local UPDATE_CHECK_INTERVAL = 30 * ONE_MINUTE

local PROXY_BINDING = 5001
local ZIGBEE_BINDING = 6001

local EVENT_LOCKED = 1
local EVENT_UNLOCKED = 2
local EVENT_JAMMED = 3
local EVENT_BATTERY_LOW = 4

-- ZCL profile + clusters
local PROFILE_HA = 0x0104
local CLUSTER_BASIC = 0x0000
local CLUSTER_POWER = 0x0001
local CLUSTER_DOORLOCK = 0x0101

-- ZCL global command ids
local ZCL_READ_ATTR = 0x00
local ZCL_READ_ATTR_RSP = 0x01
local ZCL_WRITE_ATTR = 0x02
local ZCL_REPORT_ATTR = 0x0a

-- DoorLock cluster-specific command ids (client -> server)
local DL_LOCK = 0x00 -- <pin:octstr>
local DL_UNLOCK = 0x01 -- <pin:octstr>
local DL_SET_PIN = 0x05 -- <userId:u16> <userStatus:u8> <userType:u8> <pin:octstr>
local DL_CLEAR_PIN = 0x07 -- <userId:u16>
-- DoorLock server -> client
local DL_OPER_EVENT = 0x20 -- Operating Event Notification

-- DoorLock attributes
local ATTR_LOCK_STATE = 0x0000 -- 0 not-fully / 1 locked / 2 unlocked
local ATTR_AUTO_RELOCK = 0x0023 -- AutoRelockTime (u32 seconds)
-- PowerConfig attributes
local ATTR_BATT_PCT = 0x0021 -- BatteryPercentageRemaining (0.5%/step)

-- Control4 lock proxy status strings
local STATUS_LOCKED = "Locked"
local STATUS_UNLOCKED = "Unlocked"
local STATUS_FAULT = "Jammed"
local STATUS_UNKNOWN = "Unknown"

local MAX_USERS = 30
local HISTORY_MAX = 50

gInitialized = false

local State = {
  seq = 0,
  srcEndpoint = 1,
  dstEndpoint = 1,
  lockStatus = STATUS_UNKNOWN,
  battery = nil,
  online = nil,
  autoLockSeconds = 0,
  adminCode = "",
  logItemCount = 5,
  users = {}, -- id -> { name, code, active, sched } (persisted)
  history = {}, -- array of { date, time, message, source }, newest last (persisted)
}

-- ---------------------------------------------------------------------------
-- ZCL transport
-- ---------------------------------------------------------------------------

local function nextSeq()
  State.seq = (State.seq + 1) % 256
  return State.seq
end

local function u16le(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

--- Build a ZCL header. clusterSpecific = false is a global command.
local function zclHeader(cmd, clusterSpecific)
  local fc = clusterSpecific and 0x01 or 0x00
  return string.char(fc, nextSeq(), cmd)
end

--- Send a global Read Attributes request.
local function readAttributes(clusterId, attrIds, dstEp)
  log:trace("readAttributes(0x%04x)", clusterId)
  local pkt = zclHeader(ZCL_READ_ATTR, false)
  for _, id in ipairs(attrIds) do
    pkt = pkt .. u16le(id)
  end
  C4:SendZigbeePacket(pkt, PROFILE_HA, clusterId, 0, State.srcEndpoint, dstEp or State.dstEndpoint)
end

--- Send a cluster-specific command with a raw payload.
local function sendCommand(clusterId, cmd, payload, dstEp)
  log:trace("sendCommand(0x%04x, 0x%02x)", clusterId, cmd)
  local pkt = zclHeader(cmd, true) .. (payload or "")
  C4:SendZigbeePacket(pkt, PROFILE_HA, clusterId, 0, State.srcEndpoint, dstEp or State.dstEndpoint)
end

--- Encode a ZCL octet string (1-byte length + bytes). Empty for no PIN.
local function octstr(s)
  s = (type(s) == "string") and s or ""
  return string.char(#s) .. s
end

local function u8(data, pos)
  local np, v = string.unpack(data, "b", pos)
  if v < 0 then
    v = v + 256
  end
  return np, v
end

-- Minimal attribute-report decoder -> { [attrId] = { type, value } }.
local TYPE_FMT = {
  [0x10] = "b",
  [0x18] = "b",
  [0x19] = "<H",
  [0x20] = "b",
  [0x21] = "<H",
  [0x23] = "<L",
  [0x28] = "b",
  [0x29] = "<h",
  [0x2b] = "<l",
  [0x30] = "b",
  [0x39] = "f",
}
local UNSIGNED8 = { [0x10] = true, [0x18] = true, [0x20] = true, [0x30] = true }

local function decodeAttributes(payload, cmdId)
  local attrs, pos, n = {}, 1, #payload
  while pos + 2 <= n + 1 do
    local attrId
    pos, attrId = string.unpack(payload, "<H", pos)
    if cmdId == ZCL_READ_ATTR_RSP then
      local status
      pos, status = u8(payload, pos)
      if status ~= 0 then
        break
      end
    end
    local dtype
    pos, dtype = u8(payload, pos)
    local fmt = TYPE_FMT[dtype]
    if not fmt then
      break
    end
    local np, v = string.unpack(payload, fmt, pos)
    if UNSIGNED8[dtype] and v < 0 then
      v = v + 256
    end
    attrs[attrId] = { type = dtype, value = v }
    pos = np
  end
  return attrs
end

-- ---------------------------------------------------------------------------
-- Lock proxy notifications (driver -> proxy)
-- ---------------------------------------------------------------------------

local function notify(strCommand, tParams)
  SendToProxy(PROXY_BINDING, strCommand, tParams or {}, "NOTIFY")
end

local XML_ESCAPE = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }

--- Escape XML special characters so free-text values (e.g. user names) can't
--- produce malformed markup in the proxy notify payloads.
local function xmlEscape(s)
  return (tostring(s):gsub("[&<>\"']", XML_ESCAPE))
end

--- Leaf element: escapes its text value.
local function xmlNode(tag, value)
  return string.format("<%s>%s</%s>", tag, xmlEscape(value), tag)
end

--- Container element: wraps already-built child markup verbatim (no escaping).
local function xmlWrap(tag, inner)
  return string.format("<%s>%s</%s>", tag, inner, tag)
end

local function notifyLockInitialize()
  log:trace("notifyLockInitialize()")
  notify("LOCK_STATUS_INITIALIZE", { LOCK_STATUS = tostring(State.lockStatus) })
end

local function notifyLockChanged(lastAction, source, manual)
  notify("LOCK_STATUS_CHANGED", {
    LOCK_STATUS = tostring(State.lockStatus),
    LAST_ACTION_DESCRIPTION = tostring(lastAction or ""),
    SOURCE = tostring(source or "Control4"),
    MANUAL = manual and true or false,
  })
end

local function notifyBattery()
  if State.battery ~= nil then
    notify("BATTERY_STATUS_CHANGED", { BATTERY_STATUS = State.battery })
  end
end

local function notifySettings()
  log:trace("notifySettings()")
  local body = xmlNode("admin_code", State.adminCode)
    .. xmlNode("auto_lock_time", State.autoLockSeconds)
    .. xmlNode("log_item_count", State.logItemCount)
    .. xmlNode("schedule_lockout_enabled", "false")
    .. xmlNode("lock_mode", "normal")
    .. xmlNode("log_failed_attempts", "false")
    .. xmlNode("wrong_code_attempts", "0")
    .. xmlNode("shutout_timer", "0")
    .. xmlNode("language", "English")
    .. xmlNode("volume", "0")
    .. xmlNode("one_touch_locking", "false")
  notify("SETTINGS", xmlWrap("lock_settings", body))
end

-- Proxy user-schedule field <-> stored user.sched key mapping (numeric fields).
local SCHED_FIELDS = {
  days = "SCHEDULED_DAYS",
  startDay = "START_DAY",
  startMonth = "START_MONTH",
  startYear = "START_YEAR",
  endDay = "END_DAY",
  endMonth = "END_MONTH",
  endYear = "END_YEAR",
  startTime = "START_TIME",
  endTime = "END_TIME",
  type = "SCHEDULE_TYPE",
}

local function userFields(id, u)
  local s = u.sched or {}
  return {
    USER_ID = id,
    USER_NAME = u.name or ("User " .. id),
    PASSCODE = u.code or "",
    IS_ACTIVE = u.active and true or false,
    SCHEDULED_DAYS = s.days or 0,
    START_DAY = s.startDay or 0,
    START_MONTH = s.startMonth or 0,
    START_YEAR = s.startYear or 0,
    END_DAY = s.endDay or 0,
    END_MONTH = s.endMonth or 0,
    END_YEAR = s.endYear or 0,
    START_TIME = s.startTime or 0,
    END_TIME = s.endTime or 0,
    SCHEDULE_TYPE = s.type or 0,
    IS_RESTRICTED_SCHEDULE = s.restricted and true or false,
  }
end

--- Copy any schedule fields present in a proxy ADD/EDIT_USER param table onto
--- the stored user, preserving existing values for fields that are absent.
local function captureSchedule(u, tParams)
  local s = u.sched or {}
  for field, param in pairs(SCHED_FIELDS) do
    local v = tointeger(Select(tParams, param))
    if v ~= nil then
      s[field] = v
    end
  end
  local restricted = Select(tParams, "IS_RESTRICTED_SCHEDULE")
  if restricted ~= nil then
    s.restricted = toboolean(restricted)
  end
  u.sched = s
end

--- Users are handed to the proxy as an XML list.
local function notifyUsers()
  log:trace("notifyUsers()")
  local body = ""
  for id = 1, MAX_USERS do
    local u = State.users[id]
    if u then
      body = body
        .. "<user>"
        .. xmlNode("user_id", id)
        .. xmlNode("user_name", u.name or ("User " .. id))
        .. xmlNode("passcode", u.code or "")
        .. xmlNode("is_active", u.active and "true" or "false")
        .. "</user>"
    end
  end
  notify("USERS", xmlWrap("users", body))
end

-- ---------------------------------------------------------------------------
-- History (built locally from lock + user events)
-- ---------------------------------------------------------------------------

--- Format an os.time timestamp the way the Control4 lock History tab renders it:
--- date mm/dd/yyyy, time 12-hour with AM/PM.
local function historyStamp(t)
  local dt = os.date("*t", t or os.time())
  local hr, ampm = dt.hour, "AM"
  if hr >= 12 then
    ampm = "PM"
    if hr > 12 then
      hr = hr - 12
    end
  elseif hr == 0 then
    hr = 12
  end
  return string.format("%02d/%02d/%04d", dt.month, dt.day, dt.year), string.format("%d:%02d %s", hr, dt.min, ampm)
end

--- Record a history event (newest appended last, capped to HISTORY_MAX).
local function addHistory(message, source)
  log:trace("addHistory('%s', '%s')", message, source)
  local date, time = historyStamp()
  State.history[#State.history + 1] = {
    date = date,
    time = time,
    message = tostring(message or ""),
    source = tostring(source or "Control4"),
  }
  while #State.history > HISTORY_MAX do
    table.remove(State.history, 1)
  end
  persist:set("history", State.history)
end

--- Build the <lock_history> XML the lock proxy expects, newest first, limited to
--- the configured Log Item Count.
local function historyXml()
  local limit = State.logItemCount or 5
  local body, id = "", 0
  for i = #State.history, 1, -1 do
    if id >= limit then
      break
    end
    id = id + 1
    local h = State.history[i]
    body = body
      .. "<history_item>"
      .. xmlNode("history_id", id)
      .. xmlNode("date", h.date)
      .. xmlNode("time", h.time)
      .. xmlNode("message", h.message)
      .. xmlNode("source", h.source)
      .. "</history_item>"
  end
  return xmlWrap("lock_history", body)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function saveUsers()
  persist:set("users", State.users)
end

local function loadState()
  log:trace("loadState()")
  State.users = persist:get("users", {}) or {}
  State.autoLockSeconds = tonumber(persist:get("autoLockSeconds", 0)) or 0
  State.adminCode = persist:get("adminCode", "") or ""
  State.logItemCount = tointeger(persist:get("logItemCount", 5)) or 5
  State.history = persist:get("history", {}) or {}
end

-- ---------------------------------------------------------------------------
-- Lock control + decode
-- ---------------------------------------------------------------------------

--- Map a ZCL LockState value to a proxy status string.
local function zclLockStatus(v)
  if v == 1 then
    return STATUS_LOCKED
  elseif v == 2 then
    return STATUS_UNLOCKED
  elseif v == 0 then
    return STATUS_FAULT
  end
  return STATUS_UNKNOWN
end

--- Apply a new lock status, firing the proxy notify + programming events.
local function applyLockStatus(status, lastAction, source, manual)
  log:trace("applyLockStatus('%s', '%s', '%s')", status, lastAction, source)
  local prev = State.lockStatus
  local changed = status ~= prev
  State.lockStatus = status
  notifyLockChanged(lastAction, source, manual)
  if changed then
    -- Log real transitions to history, but not the initial sync out of UNKNOWN.
    if prev ~= STATUS_UNKNOWN and status ~= STATUS_UNKNOWN then
      addHistory(status, source or "Control4")
    end
    if status == STATUS_LOCKED then
      C4:FireEvent(EVENT_LOCKED)
    elseif status == STATUS_UNLOCKED then
      C4:FireEvent(EVENT_UNLOCKED)
    elseif status == STATUS_FAULT then
      C4:FireEvent(EVENT_JAMMED)
    end
  end
  log:info("lock is %s (%s)", status, tostring(lastAction or ""))
end

local function pollLockState()
  SetTimer("PollLock", 1500, function()
    readAttributes(CLUSTER_DOORLOCK, { ATTR_LOCK_STATE })
  end)
end

local function lock()
  log:trace("lock()")
  sendCommand(CLUSTER_DOORLOCK, DL_LOCK, octstr(State.adminCode))
  pollLockState()
end

local function unlock()
  log:trace("unlock()")
  sendCommand(CLUSTER_DOORLOCK, DL_UNLOCK, octstr(State.adminCode))
  pollLockState()
end

local function toggle()
  log:trace("toggle()")
  if State.lockStatus == STATUS_LOCKED then
    unlock()
  else
    lock()
  end
end

-- DoorLock operation-event code -> ZCL lock state (manual/keypad/key operations).
local DOORLOCK_EVENT = {
  [0x01] = 1,
  [0x07] = 1,
  [0x08] = 1,
  [0x0a] = 1,
  [0x0b] = 1,
  [0x0d] = 1,
  [0x02] = 2,
  [0x09] = 2,
  [0x0c] = 2,
  [0x0e] = 2,
}
local DOORLOCK_EVENT_SOURCE = {
  [0x07] = "One Touch",
  [0x08] = "Key",
  [0x09] = "Key",
  [0x0a] = "Auto",
  [0x0d] = "Manual",
  [0x0e] = "Manual",
}

--- Set or clear a user's PIN on the lock, per ZCL DoorLock.
local function writeUserPin(id, code)
  log:trace("writeUserPin(%s)", id)
  if code and #code >= 4 then
    -- status Occupied (1), type Unrestricted (0)
    local payload = u16le(id) .. string.char(1) .. string.char(0) .. octstr(code)
    sendCommand(CLUSTER_DOORLOCK, DL_SET_PIN, payload)
  else
    sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(id))
  end
end

--- Add or edit a user code. tParams carries USER_ID/USER_NAME/PASSCODE/IS_ACTIVE
--- and optional schedule fields.
local function upsertUser(tParams, isEdit)
  local id = tointeger(Select(tParams, "USER_ID"))
  if id == nil then
    for i = 1, MAX_USERS do
      if State.users[i] == nil then
        id = i
        break
      end
    end
  end
  if id == nil then
    log:warn("no free user slot (max %d)", MAX_USERS)
    return
  end
  local u = State.users[id] or {}
  u.name = Select(tParams, "USER_NAME") or u.name or ("User " .. id)
  local code = Select(tParams, "PASSCODE")
  if code ~= nil and code ~= "" then
    u.code = tostring(code)
  end
  local active = Select(tParams, "IS_ACTIVE")
  u.active = (active == nil) and true or toboolean(active)
  captureSchedule(u, tParams)
  State.users[id] = u
  saveUsers()
  writeUserPin(id, u.active and u.code or nil)
  notify(isEdit and "USER_CHANGED" or "USER_ADDED", userFields(id, u))
  addHistory(string.format("%s User %d (%s)", isEdit and "Updated" or "Added", id, u.name), "Control4")
end

-- ---------------------------------------------------------------------------
-- Lock proxy commands (proxy -> driver)
-- ---------------------------------------------------------------------------

function RFP.LOCK(idBinding, strCommand)
  log:trace("RFP.LOCK(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lock()
end

function RFP.UNLOCK(idBinding, strCommand)
  log:trace("RFP.UNLOCK(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  unlock()
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  toggle()
end

function RFP.REQUEST_CAPABILITIES(idBinding, strCommand)
  log:trace("RFP.REQUEST_CAPABILITIES(%s, %s)", idBinding, strCommand)
  -- Static capabilities are declared in driver.xml; nothing dynamic to send.
end

function RFP.REQUEST_SETTINGS(idBinding, strCommand)
  log:trace("RFP.REQUEST_SETTINGS(%s, %s)", idBinding, strCommand)
  notifySettings()
end

function RFP.REQUEST_CUSTOM_SETTINGS(idBinding, strCommand)
  log:trace("RFP.REQUEST_CUSTOM_SETTINGS(%s, %s)", idBinding, strCommand)
end

function RFP.REQUEST_USERS(idBinding, strCommand)
  log:trace("RFP.REQUEST_USERS(%s, %s)", idBinding, strCommand)
  notifyUsers()
end

function RFP.REQUEST_HISTORY(idBinding, strCommand)
  log:trace("RFP.REQUEST_HISTORY(%s, %s)", idBinding, strCommand)
  notify("HISTORY", historyXml())
end

function RFP.ADD_USER(idBinding, strCommand, tParams)
  log:trace("RFP.ADD_USER(%s, %s, %s)", idBinding, strCommand, tParams)
  upsertUser(tParams, false)
end

function RFP.EDIT_USER(idBinding, strCommand, tParams)
  log:trace("RFP.EDIT_USER(%s, %s, %s)", idBinding, strCommand, tParams)
  upsertUser(tParams, true)
end

function RFP.DELETE_USER(idBinding, strCommand, tParams)
  log:trace("RFP.DELETE_USER(%s, %s, %s)", idBinding, strCommand, tParams)
  local id = tointeger(Select(tParams, "USER_ID"))
  if id == nil or State.users[id] == nil then
    return
  end
  local name = State.users[id].name
  State.users[id] = nil
  saveUsers()
  sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(id))
  notify("USER_DELETED", { USER_ID = id, USER_NAME = name })
  addHistory(string.format("Deleted User %d (%s)", id, name or ""), "Control4")
end

function RFP.SET_AUTO_LOCK_SECONDS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_AUTO_LOCK_SECONDS(%s, %s, %s)", idBinding, strCommand, tParams)
  local secs = tointeger(Select(tParams, "AUTO_LOCK_SECONDS")) or tointeger(Select(tParams, "VALUE")) or 0
  State.autoLockSeconds = secs
  persist:set("autoLockSeconds", secs)
  -- ZCL AutoRelockTime is a u32 seconds attribute (0 = disabled).
  local payload = u16le(ATTR_AUTO_RELOCK)
    .. string.char(0x23)
    .. string.char(
      secs % 256,
      math.floor(secs / 256) % 256,
      math.floor(secs / 65536) % 256,
      math.floor(secs / 16777216) % 256
    )
  sendCommand(CLUSTER_DOORLOCK, ZCL_WRITE_ATTR, payload)
  notify("SETTING_CHANGED", { NAME = "auto_lock_time", VALUE = tostring(secs) })
end

function RFP.SET_ADMIN_CODE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_ADMIN_CODE(%s, %s)", idBinding, strCommand)
  State.adminCode = tostring(Select(tParams, "ADMIN_CODE") or Select(tParams, "VALUE") or "")
  persist:set("adminCode", State.adminCode)
  notify("SETTING_CHANGED", { NAME = "admin_code", VALUE = State.adminCode })
  addHistory("Changed Admin Code", "Control4")
end

function RFP.SET_NUMBER_LOG_ITEMS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_NUMBER_LOG_ITEMS(%s, %s, %s)", idBinding, strCommand, tParams)
  State.logItemCount = tointeger(Select(tParams, "VALUE")) or 5
  persist:set("logItemCount", State.logItemCount)
  notify("SETTING_CHANGED", { NAME = "log_item_count", VALUE = tostring(State.logItemCount) })
end

-- Settings the proxy may send that have no ZCL mapping yet (kept for parity).
local function noopSetting(idBinding, strCommand)
  log:trace("noopSetting(%s, %s)", idBinding, strCommand)
end
RFP.SET_SCHEDULE_LOCKOUT_ENABLED = noopSetting
RFP.SET_LOCK_MODE = noopSetting
RFP.SET_LOG_FAILED_ATTEMPTS = noopSetting
RFP.SET_WRONG_CODE_ATTEMPTS = noopSetting
RFP.SET_SHUTOUT_TIMER = noopSetting
RFP.SET_LANGUAGE = noopSetting
RFP.SET_VOLUME = noopSetting
RFP.SET_ONE_TOUCH_LOCKING = noopSetting
RFP.SET_CUSTOM_SETTING = noopSetting

-- ---------------------------------------------------------------------------
-- Composer actions (Actions tab)
-- ---------------------------------------------------------------------------

function EC.LOCK(tParams)
  log:trace("EC.LOCK(%s)", tParams)
  lock()
end

function EC.UNLOCK(tParams)
  log:trace("EC.UNLOCK(%s)", tParams)
  unlock()
end

function EC.TOGGLE(tParams)
  log:trace("EC.TOGGLE(%s)", tParams)
  toggle()
end

function EC.SYNC_USERS(tParams)
  log:trace("EC.SYNC_USERS(%s)", tParams)
  for id, u in pairs(State.users) do
    writeUserPin(id, u.active and u.code or nil)
  end
  notifyUsers()
end

function EC.BATTERY_STATUS(tParams)
  log:trace("EC.BATTERY_STATUS(%s)", tParams)
  readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers(tParams)
  log:trace("EC.Update_Drivers(%s)", tParams)
  UpdateDrivers(true)
end
--#endif

-- ---------------------------------------------------------------------------
-- Zigbee callbacks
-- ---------------------------------------------------------------------------

function OnZigbeePacketIn(packet, profileId, clusterId, groupId, srcEndpoint, dstEndpoint)
  if not gInitialized then
    return
  end
  State.dstEndpoint = srcEndpoint or State.dstEndpoint
  local ok, err = pcall(function()
    local pos, fc = u8(packet, 1)
    local seq, cmd
    if (math.floor(fc / 4) % 2) == 1 then -- manufacturer-specific: skip 2-byte code
      pos = pos + 2
    end
    pos, seq = u8(packet, pos)
    pos, cmd = u8(packet, pos)
    local payload = string.sub(packet, pos)
    local clusterSpecific = (fc % 2) == 1

    if clusterId == CLUSTER_BASIC then
      return -- model/basic handled by Director's interview
    elseif clusterId == CLUSTER_DOORLOCK then
      if not clusterSpecific and (cmd == ZCL_REPORT_ATTR or cmd == ZCL_READ_ATTR_RSP) then
        local attrs = decodeAttributes(payload, cmd)
        if attrs[ATTR_LOCK_STATE] then
          applyLockStatus(zclLockStatus(attrs[ATTR_LOCK_STATE].value), "Status", "Control4", false)
        end
      elseif clusterSpecific and cmd == DL_OPER_EVENT and #payload >= 2 then
        local code = payload:byte(2)
        local ls = DOORLOCK_EVENT[code]
        if ls then
          applyLockStatus(zclLockStatus(ls), "Operation", DOORLOCK_EVENT_SOURCE[code] or "Lock", true)
        end
      end
    elseif
      clusterId == CLUSTER_POWER
      and not clusterSpecific
      and (cmd == ZCL_REPORT_ATTR or cmd == ZCL_READ_ATTR_RSP)
    then
      local attrs = decodeAttributes(payload, cmd)
      if attrs[ATTR_BATT_PCT] then
        local pct = math.floor(attrs[ATTR_BATT_PCT].value / 2 + 0.5)
        State.battery = pct
        UpdateProperty("Battery Status", pct .. "%")
        notifyBattery()
        if pct <= 15 then
          C4:FireEvent(EVENT_BATTERY_LOW)
        end
      end
    end
  end)
  if not ok then
    log:error("OnZigbeePacketIn: %s", tostring(err))
  end
end

function OnZigbeePacketSuccess() end

function OnZigbeePacketFailed(packet, profileId, clusterId)
  log:debug("Zigbee send failed on cluster 0x%04x", clusterId or 0)
end

function OnZigbeeOnlineStatusChanged(strStatus, strVersion, strSKU)
  log:trace("OnZigbeeOnlineStatusChanged('%s', '%s', '%s')", strStatus, strVersion, strSKU)
  local online = strStatus ~= "OFFLINE"
  State.online = online
  UpdateProperty("Driver Status", online and "Online" or "Offline")
  if online then
    -- Seed state from the lock (awake on join/report).
    readAttributes(CLUSTER_DOORLOCK, { ATTR_LOCK_STATE })
    readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
  end
end

function OnNetworkBindingChanged(idBinding, bIsBound)
  log:trace("OnNetworkBindingChanged(%s, %s)", idBinding, bIsBound)
  if idBinding == ZIGBEE_BINDING and bIsBound then
    notifyLockInitialize()
  end
end

-- ---------------------------------------------------------------------------
-- Property change handlers
-- ---------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end

-- ---------------------------------------------------------------------------
-- Driver updates
-- ---------------------------------------------------------------------------

--#ifndef DRIVERCENTRAL
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updated)
      if not IsEmpty(updated) then
        log:info("updated driver(s): %s", table.concat(updated, ", "))
      end
    end, function(err)
      log:warn("update check failed: %s", tostring(err))
    end)
end
--#endif

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  loadState()
  for p in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err)
    end
  end
  gInitialized = true
  notifyLockInitialize()
  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", UPDATE_CHECK_INTERVAL, function()
    if toboolean(Properties["Automatic Updates"]) then
      UpdateDrivers(false)
    end
  end, true)
  --#endif
  log:info("driver initialized")
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
end
