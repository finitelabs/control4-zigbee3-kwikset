-- Zigbee 3.0 Kwikset SmartCode lock driver.
--
-- Speaks standard ZCL DoorLock (0x0101) + PowerConfig (0x0001) directly to a
-- joined lock over the controller's Zigbee mesh - no cloud, no hub. Presents
-- the Control4 LOCK proxy (binding 5001; ZIGBEE transport on 6001) with user
-- codes, schedules, auto-lock, and history mirroring the native Kwikset driver.
-- The lock is a sleepy battery device: config writes are tracked as owed until
-- the lock's ZCL responses confirm them (see "Owed writes"), and keypad support
-- is probed at runtime so keypadless models (SmartCode Convert) drop user
-- management dynamically.

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
local ZCL_WRITE_ATTR_RSP = 0x04 -- <status:u8> [...]
local ZCL_REPORT_ATTR = 0x0a
local ZCL_DEFAULT_RESPONSE = 0x0b -- <cmdId:u8> <status:u8>
local ZCL_STATUS_UNSUP_CMD = 0x81 -- UNSUP_CLUSTER_COMMAND
local ZCL_STATUS_UNSUP_ATTR = 0x86 -- UNSUPPORTED_ATTRIBUTE

-- DoorLock cluster-specific command ids (client -> server)
local DL_LOCK = 0x00 -- <pin:octstr>
local DL_UNLOCK = 0x01 -- <pin:octstr>
local DL_SET_PIN = 0x05 -- <userId:u16> <userStatus:u8> <userType:u8> <pin:octstr>
local DL_GET_PIN = 0x06 -- <userId:u16> (read-only; used to probe keypad support)
local DL_CLEAR_PIN = 0x07 -- <userId:u16>
local DL_SET_WEEKDAY_SCHED = 0x0b -- <schedId:u8> <userId:u16> <days:u8> <sH> <sM> <eH> <eM>
local DL_CLEAR_WEEKDAY_SCHED = 0x0d -- <schedId:u8> <userId:u16>
local DL_SET_YEARDAY_SCHED = 0x0e -- <schedId:u8> <userId:u16> <startZcl:u32> <endZcl:u32>
local DL_CLEAR_YEARDAY_SCHED = 0x10 -- <schedId:u8> <userId:u16>
local DL_SET_USER_TYPE = 0x14 -- <userId:u16> <userType:u8>
-- DoorLock server -> client
local DL_OPER_EVENT = 0x20 -- Operating Event Notification

-- ZCL DoorLock user types
local USER_TYPE_UNRESTRICTED = 0x00
local USER_TYPE_YEARDAY = 0x01
local USER_TYPE_WEEKDAY = 0x02

-- DoorLock commands that manage user codes or schedules. A lock that rejects one
-- of these as unsupported (0x81) has no keypad, e.g. a SmartCode Convert module
-- fitted to a plain deadbolt. We use that to drop user management dynamically.
local CREDENTIAL_CMDS = {
  [DL_SET_PIN] = true,
  [DL_GET_PIN] = true,
  [DL_CLEAR_PIN] = true,
  [DL_SET_WEEKDAY_SCHED] = true,
  [DL_CLEAR_WEEKDAY_SCHED] = true,
  [DL_SET_YEARDAY_SCHED] = true,
  [DL_CLEAR_YEARDAY_SCHED] = true,
  [DL_SET_USER_TYPE] = true,
}

-- DoorLock cluster-specific responses that settle an owed write. Response ids
-- mirror the request ids; the payload's first byte is the ZCL status.
local DL_RESPONSE_CMDS = {
  [DL_SET_PIN] = true,
  [DL_CLEAR_PIN] = true,
  [DL_SET_WEEKDAY_SCHED] = true,
  [DL_CLEAR_WEEKDAY_SCHED] = true,
  [DL_SET_YEARDAY_SCHED] = true,
  [DL_CLEAR_YEARDAY_SCHED] = true,
  [DL_SET_USER_TYPE] = true,
}

-- LOCK proxy capabilities that only make sense on a lock with a keypad. They are
-- turned off together when the lock proves it has none (rejects credential
-- commands) and back on when it proves it has one, via CAPABILITY_CHANGED.
-- max_users is pushed alongside these (0 when unsupported).
local USER_CODE_CAPABILITIES = {
  "can_add_remove_user",
  "can_edit_user",
  "can_edit_user_pin",
  "has_daily_schedule",
  "has_date_range_schedule",
  "has_schedule_lockout",
  "has_admin_code",
}

-- Seconds between the Unix epoch (1970) and the ZCL epoch (2000-01-01 UTC).
local ZCL_EPOCH_OFFSET = 946684800

-- DoorLock attributes
local ATTR_LOCK_STATE = 0x0000 -- 0 not-fully / 1 locked / 2 unlocked
local ATTR_NUM_PIN_USERS = 0x0012 -- NumberOfPINUsersSupported
local ATTR_NUM_WEEKDAY_SCHED = 0x0014 -- NumberOfWeekDaySchedulesSupportedPerUser
local ATTR_NUM_YEARDAY_SCHED = 0x0015 -- NumberOfYearDaySchedulesSupportedPerUser
local ATTR_MAX_PIN_LEN = 0x0017 -- MaxPINCodeLength
local ATTR_MIN_PIN_LEN = 0x0018 -- MinPINCodeLength
local ATTR_AUTO_RELOCK = 0x0023 -- AutoRelockTime (u32 seconds, 0 = disabled)
local ATTR_SOUND_VOLUME = 0x0024 -- SoundVolume (u8: 0 silent / 1 low / 2 high)
local ATTR_ONE_TOUCH_LOCKING = 0x0029 -- EnableOneTouchLocking (bool)
local ATTR_WRONG_CODE_LIMIT = 0x0030 -- WrongCodeEntryLimit (u8 attempts)
local ATTR_SHUTOUT_TIME = 0x0031 -- UserCodeTemporaryDisableTime (u8 seconds)
-- PowerConfig attributes
local ATTR_BATT_PCT = 0x0021 -- BatteryPercentageRemaining (0.5%/step)

-- Proxy volume strings <-> ZCL SoundVolume values (dialect per the native
-- Kwikset driver: ST_VOLUME is "high" | "low" | "silent").
local VOLUME_TO_ZCL = { silent = 0, low = 1, high = 2 }
local ZCL_TO_VOLUME = { [0] = "silent", [1] = "low", [2] = "high" }

-- Control4 lock proxy status strings
local STATUS_LOCKED = "Locked"
local STATUS_UNLOCKED = "Unlocked"
local STATUS_FAULT = "Jammed"
local STATUS_UNKNOWN = "Unknown"

-- Control4 lock proxy battery status values (drives the proxy's Status panel)
local BATTERY_NORMAL = "normal"
local BATTERY_WARNING = "warning"
local BATTERY_CRITICAL = "critical"

local MAX_USERS = 30
local HISTORY_MAX = 50

gInitialized = false

local state = {
  seq = 0,
  srcEndpoint = 1,
  dstEndpoint = 1,
  lockStatus = STATUS_UNKNOWN,
  battery = nil,
  online = nil,
  -- Lock-side config settings. nil = never configured here: the first value the
  -- lock reports is adopted as desired; once set from Control4, desired wins
  -- and drift on the lock is re-asserted.
  autoLockSeconds = nil,
  volume = nil, -- "silent" | "low" | "high"
  oneTouchLocking = nil,
  wrongCodeAttempts = nil,
  shutoutTimer = nil,
  adminCode = "",
  logItemCount = 5,
  scheduleLockoutEnabled = false,
  -- Assume the lock has a keypad until it rejects a user-code command. Re-probed
  -- on every online, so a module swap is picked up on the next reload.
  supportsUserCodes = true,
  users = {}, -- id -> { name, code, active, sched } (persisted)
  history = {}, -- array of { date, time, message, source }, newest last (persisted)
  pending = {}, -- owed lock writes: key -> { kind, id, msg, group, attempts, ts } (persisted)
  pendingSeq = {}, -- ZCL seq -> pending key (transient; rebuilt as sends go out)
  -- Per-setting support verdicts learned from the lock's per-attribute ZCL
  -- statuses; absent = assumed supported (per driver.xml). false hides the
  -- setting via CAPABILITY_CHANGED. (persisted)
  settingSupport = {},
  -- Lock capability limits, read from the DoorLock cluster at online. Seeded
  -- with the SmartCode Convert's known values so validation works before the
  -- lock reports.
  limits = { maxUsers = MAX_USERS, minPin = 4, maxPin = 8, weekDaySched = 7, yearDaySched = 1 },
}

-- ---------------------------------------------------------------------------
-- ZCL transport
-- ---------------------------------------------------------------------------

local function nextSeq()
  state.seq = (state.seq + 1) % 256
  return state.seq
end

local function u16le(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32le(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

--- Build a ZCL header. clusterSpecific = false is a global command. Also
--- returns the transaction sequence, which responses echo back - the owed-write
--- layer uses it to match confirmations to sends.
local function zclHeader(cmd, clusterSpecific)
  local seq = nextSeq()
  local fc = clusterSpecific and 0x01 or 0x00
  return string.char(fc, seq, cmd), seq
end

--- Send a global Read Attributes request. Returns the ZCL sequence.
local function readAttributes(clusterId, attrIds, dstEp)
  log:trace("readAttributes(0x%04x)", clusterId)
  local pkt, seq = zclHeader(ZCL_READ_ATTR, false)
  for _, id in ipairs(attrIds) do
    pkt = pkt .. u16le(id)
  end
  C4:SendZigbeePacket(pkt, PROFILE_HA, clusterId, 0, state.srcEndpoint, dstEp or state.dstEndpoint)
  return seq
end

--- Send a cluster-specific command with a raw payload. Returns the ZCL sequence.
local function sendCommand(clusterId, cmd, payload, dstEp)
  log:trace("sendCommand(0x%04x, 0x%02x)", clusterId, cmd)
  local hdr, seq = zclHeader(cmd, true)
  C4:SendZigbeePacket(hdr .. (payload or ""), PROFILE_HA, clusterId, 0, state.srcEndpoint, dstEp or state.dstEndpoint)
  return seq
end

--- Send a global Write Attributes request. Returns the ZCL sequence. This must
--- be a global frame: a cluster-specific 0x02 on DoorLock would be Unlock with
--- Timeout, not a write.
local function writeAttributes(clusterId, payload, dstEp)
  log:trace("writeAttributes(0x%04x)", clusterId)
  local hdr, seq = zclHeader(ZCL_WRITE_ATTR, false)
  C4:SendZigbeePacket(hdr .. payload, PROFILE_HA, clusterId, 0, state.srcEndpoint, dstEp or state.dstEndpoint)
  return seq
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

--- Decode attribute records into { [attrId] = { status, type, value } }. A Read
--- Attributes Response carries a per-attribute status; a failed record (e.g.
--- UNSUPPORTED_ATTRIBUTE) has no type/value but must not stop the parse - the
--- records behind it in the same response are still good. value is nil for
--- failed records, so consumers check it, not just the attribute's presence.
local function decodeAttributes(payload, cmdId)
  local attrs, pos, n = {}, 1, #payload
  while pos + 2 <= n + 1 do
    local attrId
    pos, attrId = string.unpack(payload, "<H", pos)
    local status = 0
    if cmdId == ZCL_READ_ATTR_RSP then
      pos, status = u8(payload, pos)
    end
    if status ~= 0 then
      attrs[attrId] = { status = status }
    else
      local dtype
      pos, dtype = u8(payload, pos)
      local fmt = TYPE_FMT[dtype]
      if not fmt then
        break -- unknown type: record length unknowable, cannot continue safely
      end
      local np, v = string.unpack(payload, fmt, pos)
      if UNSIGNED8[dtype] and v < 0 then
        v = v + 256
      end
      attrs[attrId] = { status = 0, type = dtype, value = v }
      pos = np
    end
  end
  return attrs
end

-- ---------------------------------------------------------------------------
-- Lock proxy notifications (driver -> proxy)
-- ---------------------------------------------------------------------------

local function notify(strCommand, tParams)
  SendToProxy(PROXY_BINDING, strCommand, tParams or {}, "NOTIFY")
end

-- Proxy XML payloads are built with the vendored XMLTag (drivers-common-public):
-- XMLTag(tag, value) escapes the text value; XMLTag(tag, inner, nil, false)
-- wraps already-built child markup verbatim.

local function notifyLockInitialize()
  log:trace("notifyLockInitialize()")
  notify("LOCK_STATUS_INITIALIZE", { LOCK_STATUS = tostring(state.lockStatus) })
end

local function notifyLockChanged(lastAction, source, manual)
  notify("LOCK_STATUS_CHANGED", {
    LOCK_STATUS = tostring(state.lockStatus),
    LAST_ACTION_DESCRIPTION = tostring(lastAction or ""),
    SOURCE = tostring(source or "Control4"),
    MANUAL = manual and true or false,
  })
end

--- Map a battery percentage to the proxy's battery status value.
local function batteryStatus(pct)
  if pct <= 10 then
    return BATTERY_CRITICAL
  elseif pct <= 25 then
    return BATTERY_WARNING
  end
  return BATTERY_NORMAL
end

local function notifyBattery()
  if state.battery ~= nil then
    notify("BATTERY_STATUS_CHANGED", { BATTERY_STATUS = batteryStatus(state.battery) })
  end
end

local function notifySettings()
  log:trace("notifySettings()")
  local oneTouch = state.oneTouchLocking
  if oneTouch == nil then
    oneTouch = true
  end
  local body = XMLTag("admin_code", state.adminCode)
    .. XMLTag("auto_lock_time", state.autoLockSeconds or 0)
    .. XMLTag("log_item_count", state.logItemCount)
    .. XMLTag("schedule_lockout_enabled", tostring(state.scheduleLockoutEnabled))
    .. XMLTag("lock_mode", "normal")
    .. XMLTag("log_failed_attempts", "false")
    .. XMLTag("wrong_code_attempts", state.wrongCodeAttempts or 3)
    .. XMLTag("shutout_timer", state.shutoutTimer or 60)
    .. XMLTag("language", "English")
    .. XMLTag("volume", state.volume or "high")
    .. XMLTag("one_touch_locking", tostring(oneTouch))
  notify("SETTINGS", XMLTag("lock_settings", body, nil, false))
end

--- Push the capability set that matches state.supportsUserCodes to the proxy.
--- Called on init from the persisted verdict (so a reload does not briefly
--- re-expose user management before the sleepy lock answers a probe) and whenever
--- the verdict changes. Lock/unlock, status, battery, auto-lock, and history are
--- never touched.
local function applyUserCodeCapabilities()
  local value = state.supportsUserCodes and "true" or "false"
  for _, name in ipairs(USER_CODE_CAPABILITIES) do
    notify("CAPABILITY_CHANGED", { NAME = name, VALUE = value })
  end
  notify("CAPABILITY_CHANGED", {
    NAME = "max_users",
    VALUE = tostring(state.supportsUserCodes and state.limits.maxUsers or 0),
  })
  notify("LOCK_CAPABILITIES_CHANGED", {})
end

--- Record whether the lock supports user codes and push the matching capability
--- set. A keypadless lock (e.g. a SmartCode Convert retrofit) rejects credential
--- commands, which hides user codes, schedules, and the admin code; a keypad lock
--- accepts them and gets full user management. Persisted, because these battery
--- locks sleep and may not answer a probe until well after the driver starts.
local function setUserCodeSupport(supported)
  if state.supportsUserCodes == supported then
    return
  end
  state.supportsUserCodes = supported
  persist:set("supportsUserCodes", supported)
  log:info(
    "Lock %s user codes; %s user management",
    supported and "supports" or "does not support",
    supported and "restoring" or "dropping"
  )
  applyUserCodeCapabilities()
end

-- Proxy user-schedule fields <-> stored user.sched keys. The proxy sends (and
-- expects back) SCHEDULE_TYPE as a string ("daily"/"date_range") and
-- SCHEDULED_DAYS as a comma-separated list of 7 booleans; the date/time fields
-- are integers. Echoing the wrong types back leaves the Navigator's "Saving"
-- dialog spinning.
local SCHED_INT_FIELDS = {
  startDay = "START_DAY",
  startMonth = "START_MONTH",
  startYear = "START_YEAR",
  endDay = "END_DAY",
  endMonth = "END_MONTH",
  endYear = "END_YEAR",
  startTime = "START_TIME",
  endTime = "END_TIME",
}
local SCHED_STR_FIELDS = {
  days = "SCHEDULED_DAYS",
  type = "SCHEDULE_TYPE",
}
local DEFAULT_SCHEDULED_DAYS = "false,false,false,false,false,false,false"
local DEFAULT_SCHEDULE_TYPE = "daily"

local function userFields(id, u)
  local s = u.sched or {}
  return {
    USER_ID = id,
    USER_NAME = u.name or ("User " .. id),
    PASSCODE = u.code or "",
    IS_ACTIVE = u.active and true or false,
    SCHEDULED_DAYS = s.days or DEFAULT_SCHEDULED_DAYS,
    START_DAY = s.startDay or 0,
    START_MONTH = s.startMonth or 0,
    START_YEAR = s.startYear or 0,
    END_DAY = s.endDay or 0,
    END_MONTH = s.endMonth or 0,
    END_YEAR = s.endYear or 0,
    START_TIME = s.startTime or 0,
    END_TIME = s.endTime or 0,
    SCHEDULE_TYPE = s.type or DEFAULT_SCHEDULE_TYPE,
    IS_RESTRICTED_SCHEDULE = s.restricted and true or false,
  }
end

--- Copy any schedule fields present in a proxy ADD/EDIT_USER param table onto
--- the stored user, preserving existing values for fields that are absent.
local function captureSchedule(u, tParams)
  local s = u.sched or {}
  for field, param in pairs(SCHED_INT_FIELDS) do
    local v = tointeger(Select(tParams, param))
    if v ~= nil then
      s[field] = v
    end
  end
  for field, param in pairs(SCHED_STR_FIELDS) do
    local v = Select(tParams, param)
    if v ~= nil then
      s[field] = tostring(v)
    end
  end
  local restricted = Select(tParams, "IS_RESTRICTED_SCHEDULE")
  if restricted ~= nil then
    s.restricted = toboolean(restricted)
  end
  u.sched = s
end

--- Users are handed to the proxy as an XML list. Root element and per-user
--- fields must match what the lock proxy expects (see the native driver).
local function notifyUsers()
  log:trace("notifyUsers()")
  -- Iterate stored ids in order rather than 1..MAX_USERS: the learned limit
  -- from the lock can exceed the compile-time default, and every stored slot
  -- must reach the proxy.
  local ids = {}
  for id in pairs(state.users) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local body = ""
  for _, id in ipairs(ids) do
    local u = state.users[id]
    local s = u.sched or {}
    body = body
      .. "<user>"
      .. XMLTag("user_id", id)
      .. XMLTag("user_name", u.name or ("User " .. id))
      .. XMLTag("passcode", u.code or "")
      .. XMLTag("is_active", u.active and "true" or "false")
      .. XMLTag("is_restricted_schedule", s.restricted and "true" or "false")
      .. XMLTag("start_time", s.startTime or 0)
      .. XMLTag("end_time", s.endTime or 0)
      .. XMLTag("schedule_type", s.type or DEFAULT_SCHEDULE_TYPE)
      .. XMLTag("start_day", s.startDay or 0)
      .. XMLTag("start_month", s.startMonth or 0)
      .. XMLTag("start_year", s.startYear or 0)
      .. XMLTag("end_day", s.endDay or 0)
      .. XMLTag("end_month", s.endMonth or 0)
      .. XMLTag("end_year", s.endYear or 0)
      .. XMLTag("scheduled_days", s.days or DEFAULT_SCHEDULED_DAYS)
      .. "</user>"
  end
  notify("USERS", XMLTag("lock_users", body, nil, false))
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
  state.history[#state.history + 1] = {
    date = date,
    time = time,
    message = tostring(message or ""),
    source = tostring(source or "Control4"),
  }
  while #state.history > HISTORY_MAX do
    table.remove(state.history, 1)
  end
  persist:set("history", state.history)
end

--- Build the <lock_history> XML the lock proxy expects, newest first, limited to
--- the configured Log Item Count.
local function historyXml()
  local limit = state.logItemCount or 5
  local body, id = "", 0
  for i = #state.history, 1, -1 do
    if id >= limit then
      break
    end
    id = id + 1
    local h = state.history[i]
    body = body
      .. "<history_item>"
      .. XMLTag("history_id", id)
      .. XMLTag("date", h.date)
      .. XMLTag("time", h.time)
      .. XMLTag("message", h.message)
      .. XMLTag("source", h.source)
      .. "</history_item>"
  end
  return XMLTag("lock_history", body, nil, false)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function saveUsers()
  -- User PINs are door credentials; they only ever persist encrypted.
  persist:set("users", state.users, true)
end

--- One-shot migration: user PINs and the admin code moved to encrypted
--- persistence. Read the legacy plaintext values once, re-store them encrypted
--- under the same keys, and stamp a schema version so this never runs again.
--- A fresh install has nothing stored and skips straight to the stamp.
local function migrateSecrets()
  if (tointeger(persist:get("persistVersion", 1)) or 1) >= 2 then
    return
  end
  local users = persist:get("users", nil)
  if users ~= nil then
    persist:set("users", users, true)
  end
  local adminCode = persist:get("adminCode", nil)
  if adminCode ~= nil then
    persist:set("adminCode", adminCode, true)
  end
  persist:set("persistVersion", 2)
end

local function loadState()
  log:trace("loadState()")
  migrateSecrets()
  state.users = persist:get("users", {}, true) or {}
  -- Lock-side settings: absent means "never configured" (adopt from the lock).
  -- persist:get(key, nil) returns an internal sentinel table for absent keys,
  -- so every load type-checks its value to keep "never configured" nil.
  state.autoLockSeconds = tonumber(persist:get("autoLockSeconds", nil))
  local volume = persist:get("volume", nil)
  state.volume = type(volume) == "string" and volume or nil
  local oneTouch = persist:get("oneTouchLocking", nil)
  state.oneTouchLocking = type(oneTouch) == "boolean" and oneTouch or nil
  state.wrongCodeAttempts = tointeger(persist:get("wrongCodeAttempts", nil))
  state.shutoutTimer = tointeger(persist:get("shutoutTimer", nil))
  state.adminCode = persist:get("adminCode", "", true) or ""
  state.logItemCount = tointeger(persist:get("logItemCount", 5)) or 5
  state.scheduleLockoutEnabled = toboolean(persist:get("scheduleLockoutEnabled", false)) or false
  state.history = persist:get("history", {}) or {}
  -- Writes owed to the lock from a previous run; re-armed (not re-sent) in
  -- OnDriverLateInit and flushed when the lock next speaks.
  state.pending = persist:get("pendingWrites", {}) or {}
  state.settingSupport = persist:get("settingSupport", {}) or {}
  -- A stored false (in any form) means "no keypad"; unknown defaults to yes.
  state.supportsUserCodes = toboolean(persist:get("supportsUserCodes", true))
end

-- ---------------------------------------------------------------------------
-- Owed writes (pending confirmation)
-- ---------------------------------------------------------------------------
-- The lock is a sleepy battery device: a command that got a send-level ack may
-- still never reach it. Every config write (PINs, schedules, deletes, auto-lock
-- time) is recorded here as owed intent until the lock's ZCL response confirms
-- it. Owed writes persist across reloads, retry on a bounded timer, flush when
-- any inbound packet proves the lock awake, and surface via Driver Status
-- ("Applying lock changes...") and, on failure, the proxy's Last Action
-- Description - the lock proxy's only free-text channel.

local PENDING_RETRY_INTERVAL = 30 * ONE_SECOND
local PENDING_MAX_ATTEMPTS = 10 -- ~5 minutes of retries before an owed write is declared failed
local PENDING_RESEND_HOLDOFF = 5 -- seconds; don't re-spam a write that just went out

-- Forward declarations: the resend dispatcher needs the user/schedule senders
-- defined below, and the mutators need the timer.
local resendPendingEntry
local armPendingTimer

local function savePending()
  persist:set("pendingWrites", state.pending)
end

--- Reflect online + owed-write state in the Driver Status property.
local function updateDriverStatus()
  if not gInitialized then
    return
  end
  if not state.online then
    UpdateProperty("Driver Status", "Offline")
  elseif next(state.pending) ~= nil then
    UpdateProperty("Driver Status", "Applying lock changes...")
  else
    UpdateProperty("Driver Status", "Online")
  end
end

--- Update online state, Driver Status, and the proxy's ONLINE_CHANGED notify.
local function applyOnline(online)
  local changed = state.online ~= online
  state.online = online
  updateDriverStatus()
  if changed then
    notify("ONLINE_CHANGED", { STATE = online and true or false })
  end
end

--- Track a config write owed to the lock. msg/group defer the history entry to
--- confirmation time: the group's message logs once when its last write lands.
local function registerPending(key, kind, id, msg, group)
  state.pending[key] = { kind = kind, id = id, msg = msg, group = group, attempts = 0, ts = os.time() }
  savePending()
  armPendingTimer()
  updateDriverStatus()
end

--- Map a just-sent ZCL sequence to its owed write so the response can settle it.
local function markPendingSent(key, seq)
  local e = state.pending[key]
  if e then
    e.lastSent = os.time()
    state.pendingSeq[seq] = key
  end
end

--- Drop an owed write without comment (superseded or no longer applicable).
local function cancelPending(key)
  if state.pending[key] == nil then
    return
  end
  state.pending[key] = nil
  savePending()
  armPendingTimer()
  updateDriverStatus()
end

--- The lock confirmed an owed write; log its deferred history entry once the
--- whole group (e.g. a user's PIN + schedule) has landed.
local function confirmPending(key)
  local e = state.pending[key]
  if e == nil then
    return
  end
  state.pending[key] = nil
  savePending()
  if e.msg then
    local outstanding = false
    if e.group then
      for _, other in pairs(state.pending) do
        if other.group == e.group then
          outstanding = true
          break
        end
      end
    end
    if not outstanding then
      addHistory(e.msg, "Control4")
    end
  end
  armPendingTimer()
  updateDriverStatus()
end

--- Declare an owed write failed: drop it and surface the reason in history and
--- the Last Action Description (the proxy has no reject-with-message path).
local function failPending(key, reason)
  local e = state.pending[key]
  if e == nil then
    return
  end
  state.pending[key] = nil
  savePending()
  local what = e.msg or ("Lock write " .. key)
  addHistory(string.format("%s - %s", what, reason), "Control4")
  notifyLockChanged(string.format("%s - %s", what, reason), "Control4", false)
  armPendingTimer()
  updateDriverStatus()
end

--- Settle the owed write matching a response's echoed sequence, if any.
local function confirmSeq(seq, status)
  local key = state.pendingSeq[seq]
  if key == nil then
    return
  end
  state.pendingSeq[seq] = nil
  if status == 0 then
    confirmPending(key)
  else
    failPending(key, string.format("rejected by lock (status 0x%02x)", status))
  end
end

--- Drop owed credential writes (a keypadless lock will never confirm them).
local function cancelCredentialPending()
  for key, e in pairs(state.pending) do
    if e.kind == "pin" or e.kind == "sched" or e.kind == "clear" then
      state.pending[key] = nil
    end
  end
  savePending()
  armPendingTimer()
  updateDriverStatus()
end

armPendingTimer = function()
  if next(state.pending) == nil then
    CancelTimer("PendingWrites")
    return
  end
  SetTimer("PendingWrites", PENDING_RETRY_INTERVAL, function()
    for key, e in pairs(state.pending) do
      e.attempts = (e.attempts or 0) + 1
      if e.attempts > PENDING_MAX_ATTEMPTS then
        failPending(key, "not confirmed by lock")
      else
        resendPendingEntry(key, e)
      end
    end
    savePending()
  end, true)
end

--- Any packet from the lock proves it is awake: push owed writes now instead of
--- waiting out the retry timer (with a short holdoff so a burst of responses
--- does not re-spam sends).
local function flushPendingOnAwake()
  local now = os.time()
  for key, e in pairs(state.pending) do
    if now - (e.lastSent or 0) >= PENDING_RESEND_HOLDOFF then
      resendPendingEntry(key, e)
    end
  end
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
  local prev = state.lockStatus
  local changed = status ~= prev
  state.lockStatus = status
  -- Unconditional: the notify carries last-action/source metadata the proxy
  -- must see even when the lock state itself did not change.
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
  log:info("Lock is %s (%s)", status, tostring(lastAction or ""))
end

local function pollLockState()
  SetTimer("PollLock", 1500, function()
    readAttributes(CLUSTER_DOORLOCK, { ATTR_LOCK_STATE })
  end)
end

local function lock()
  log:trace("lock()")
  sendCommand(CLUSTER_DOORLOCK, DL_LOCK, octstr(state.adminCode))
  pollLockState()
end

local function unlock()
  log:trace("unlock()")
  sendCommand(CLUSTER_DOORLOCK, DL_UNLOCK, octstr(state.adminCode))
  pollLockState()
end

local function toggle()
  log:trace("toggle()")
  if state.lockStatus == STATUS_LOCKED then
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

--- Set or clear a user's PIN on the lock, per ZCL DoorLock. The send is tied to
--- its owed-write entry so the lock's response settles it.
local function writeUserPin(id, code)
  log:trace("writeUserPin(%s)", id)
  local seq
  if code and #code >= 4 then
    -- status Occupied (1), type Unrestricted (0)
    local payload = u16le(id) .. string.char(1) .. string.char(0) .. octstr(code)
    seq = sendCommand(CLUSTER_DOORLOCK, DL_SET_PIN, payload)
  else
    seq = sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(id))
  end
  markPendingSent("pin:" .. id, seq)
end

-- Weekday bit values; SCHEDULED_DAYS[1]=Sunday .. [7]=Saturday and the ZCL
-- weekday DaysMask has bit0=Sunday .. bit6=Saturday.
local WEEKDAY_BITS = { 1, 2, 4, 8, 16, 32, 64 }

--- Push a user's schedule to the lock (ZCL DoorLock). A restricted user gets a
--- weekday or yearday schedule plus the matching user type; an unrestricted user
--- has its schedules cleared and is set back to Unrestricted. The lock enforces
--- the window itself.
local function writeUserSchedule(id, u)
  log:trace("writeUserSchedule(%s)", id)
  local s = u.sched or {}
  if not s.restricted then
    sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_WEEKDAY_SCHED, string.char(0) .. u16le(id))
    sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_YEARDAY_SCHED, string.char(0) .. u16le(id))
    -- The trailing Set User Type is the sequence that settles the owed write.
    markPendingSent(
      "sched:" .. id,
      sendCommand(CLUSTER_DOORLOCK, DL_SET_USER_TYPE, u16le(id) .. string.char(USER_TYPE_UNRESTRICTED))
    )
    return
  end
  if s.type == "date_range" then
    local startT = os.time({
      year = s.startYear or 2000,
      month = s.startMonth or 1,
      day = s.startDay or 1,
      hour = math.floor((s.startTime or 0) / 60),
      min = (s.startTime or 0) % 60,
      sec = 0,
    }) - ZCL_EPOCH_OFFSET
    local endT = os.time({
      year = s.endYear or 2000,
      month = s.endMonth or 1,
      day = s.endDay or 1,
      hour = math.floor((s.endTime or 0) / 60),
      min = (s.endTime or 0) % 60,
      sec = 0,
    }) - ZCL_EPOCH_OFFSET
    sendCommand(CLUSTER_DOORLOCK, DL_SET_YEARDAY_SCHED, string.char(0) .. u16le(id) .. u32le(startT) .. u32le(endT))
    markPendingSent(
      "sched:" .. id,
      sendCommand(CLUSTER_DOORLOCK, DL_SET_USER_TYPE, u16le(id) .. string.char(USER_TYPE_YEARDAY))
    )
  else
    local days, idx = 0, 1
    for w in tostring(s.days or ""):gmatch("[^,]+") do
      if idx <= 7 and toboolean(w) then
        days = days + WEEKDAY_BITS[idx]
      end
      idx = idx + 1
    end
    local st, et = s.startTime or 0, s.endTime or 1439
    local payload = string.char(0)
      .. u16le(id)
      .. string.char(days, math.floor(st / 60), st % 60, math.floor(et / 60), et % 60)
    sendCommand(CLUSTER_DOORLOCK, DL_SET_WEEKDAY_SCHED, payload)
    markPendingSent(
      "sched:" .. id,
      sendCommand(CLUSTER_DOORLOCK, DL_SET_USER_TYPE, u16le(id) .. string.char(USER_TYPE_WEEKDAY))
    )
  end
end

-- ZCL-backed lock settings, keyed by their owed-write key. Each entry knows its
-- attribute, ZCL type, the desired value (with the pre-adoption default), and
-- how to adopt a lock-reported value as desired. rawGet() returning nil means
-- the installer never configured the setting here.
local SETTING_ATTRS = {
  ["attr:autolock"] = {
    attr = ATTR_AUTO_RELOCK,
    cap = "has_auto_lock_time",
    type = 0x23, -- u32
    rawGet = function()
      return state.autoLockSeconds
    end,
    get = function()
      return state.autoLockSeconds or 0
    end,
    adopt = function(v)
      state.autoLockSeconds = v
      persist:set("autoLockSeconds", v)
      notify("SETTING_CHANGED", { NAME = "auto_lock_time", VALUE = tostring(v) })
    end,
  },
  ["attr:volume"] = {
    attr = ATTR_SOUND_VOLUME,
    cap = "has_volume",
    type = 0x20, -- u8
    rawGet = function()
      return state.volume
    end,
    get = function()
      return VOLUME_TO_ZCL[state.volume or "high"] or 2
    end,
    adopt = function(v)
      state.volume = ZCL_TO_VOLUME[v] or "high"
      persist:set("volume", state.volume)
      notify("SETTING_CHANGED", { NAME = "volume", VALUE = state.volume })
    end,
  },
  ["attr:onetouch"] = {
    attr = ATTR_ONE_TOUCH_LOCKING,
    cap = "has_one_touch_locking",
    type = 0x10, -- bool
    rawGet = function()
      return state.oneTouchLocking
    end,
    get = function()
      local enabled = state.oneTouchLocking
      if enabled == nil then
        enabled = true
      end
      return enabled and 1 or 0
    end,
    adopt = function(v)
      state.oneTouchLocking = v ~= 0
      persist:set("oneTouchLocking", state.oneTouchLocking)
      notify("SETTING_CHANGED", { NAME = "one_touch_locking", VALUE = tostring(state.oneTouchLocking) })
    end,
  },
  ["attr:wrongcode"] = {
    attr = ATTR_WRONG_CODE_LIMIT,
    cap = "has_wrong_code_attempts",
    type = 0x20, -- u8
    rawGet = function()
      return state.wrongCodeAttempts
    end,
    get = function()
      return state.wrongCodeAttempts or 3
    end,
    adopt = function(v)
      state.wrongCodeAttempts = v
      persist:set("wrongCodeAttempts", v)
      notify("SETTING_CHANGED", { NAME = "wrong_code_attempts", VALUE = tostring(v) })
    end,
  },
  ["attr:shutout"] = {
    attr = ATTR_SHUTOUT_TIME,
    cap = "has_shutout_timer",
    type = 0x20, -- u8
    rawGet = function()
      return state.shutoutTimer
    end,
    get = function()
      return state.shutoutTimer or 60
    end,
    adopt = function(v)
      state.shutoutTimer = v
      persist:set("shutoutTimer", v)
      notify("SETTING_CHANGED", { NAME = "shutout_timer", VALUE = tostring(v) })
    end,
  },
}

--- Write a ZCL-backed setting's desired value to the lock via a global Write
--- Attributes frame, tied to its owed-write entry.
local function writeSettingAttr(key)
  log:trace("writeSettingAttr(%s)", key)
  local s = SETTING_ATTRS[key]
  local v = s.get()
  local payload
  if s.type == 0x23 then
    payload = u16le(s.attr) .. string.char(s.type) .. u32le(v)
  else
    payload = u16le(s.attr) .. string.char(s.type) .. string.char(v % 256)
  end
  markPendingSent(key, writeAttributes(CLUSTER_DOORLOCK, payload))
end

--- Reconcile a lock-reported setting with desired state: adopt the lock's
--- value when the installer never set one here; re-assert desired when they
--- differ and nothing is owed.
local function reconcileSetting(key, reported)
  local s = SETTING_ATTRS[key]
  if s.rawGet() == nil then
    s.adopt(reported)
  elseif state.pending[key] == nil and s.get() ~= reported then
    registerPending(key, "attr", s.attr, nil, nil)
    writeSettingAttr(key)
  end
end

--- Record whether the lock supports a ZCL-backed setting and show/hide its
--- control via the proxy's capability channel (the proxy persists capability
--- values, so verdicts are pushed on change and replayed on request). An
--- unsupported setting also drops any owed write - it can never confirm.
local function setSettingSupport(key, supported)
  if state.settingSupport[key] == supported then
    return
  end
  state.settingSupport[key] = supported
  persist:set("settingSupport", state.settingSupport)
  local s = SETTING_ATTRS[key]
  log:info(
    "Lock %s %s; %s its setting",
    supported and "supports" or "does not support",
    s.cap,
    supported and "showing" or "hiding"
  )
  notify("CAPABILITY_CHANGED", { NAME = s.cap, VALUE = supported and "true" or "false" })
  notify("LOCK_CAPABILITIES_CHANGED", {})
  if not supported then
    cancelPending(key)
  end
end

--- Replay every ZCL-backed setting's capability verdict to the proxy
--- (unknown counts as supported, matching the driver.xml defaults).
local function applySettingCapabilities()
  for key, s in pairs(SETTING_ATTRS) do
    local supported = state.settingSupport[key] ~= false
    notify("CAPABILITY_CHANGED", { NAME = s.cap, VALUE = supported and "true" or "false" })
  end
  notify("LOCK_CAPABILITIES_CHANGED", {})
end

--- Re-send an owed write's absolute intent, re-derived from current state so a
--- replay always carries the full desired end state.
resendPendingEntry = function(key, e)
  local u = e.id and state.users[e.id] or nil
  if e.kind == "pin" then
    if u then
      writeUserPin(e.id, u.active and u.code or nil)
    else
      cancelPending(key)
    end
  elseif e.kind == "sched" then
    if u then
      writeUserSchedule(e.id, u)
    else
      cancelPending(key)
    end
  elseif e.kind == "clear" then
    markPendingSent(key, sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(e.id)))
  elseif e.kind == "attr" then
    writeSettingAttr(key)
  end
end

--- Add or edit a user code. tParams carries USER_ID/USER_NAME/PASSCODE/IS_ACTIVE
--- and optional schedule fields. The lock proxy has no reject-with-message path,
--- so when a save would trip a lock limit we refuse it and surface the reason in
--- the Last Action Description (notifyLockChanged), the only free-text channel.
--- (Those refusal notifies deliberately reuse LOCK_STATUS_CHANGED outside
--- applyLockStatus: the status value is unchanged, only the text matters.)
--- The proxy echo (USER_ADDED/USER_CHANGED) stays immediate so Navigator's
--- Saving dialog releases; the history entry is deferred until the lock
--- confirms the owed PIN + schedule writes.
local function upsertUser(tParams, isEdit)
  if not state.supportsUserCodes then
    log:warn("Ignoring user save; lock does not support user codes")
    notifyLockChanged("This lock does not support user codes", "Control4", false)
    return
  end
  local id = tointeger(Select(tParams, "USER_ID"))
  if id == nil then
    for i = 1, state.limits.maxUsers do
      if state.users[i] == nil then
        id = i
        break
      end
    end
  end
  if id == nil or id > state.limits.maxUsers then
    log:warn("No free user slot (max %d)", state.limits.maxUsers)
    notifyLockChanged(
      string.format("Cannot add user: lock supports %d codes", state.limits.maxUsers),
      "Control4",
      false
    )
    return
  end
  local code = Select(tParams, "PASSCODE")
  if not IsEmpty(code) then
    local n = #tostring(code)
    if n < state.limits.minPin or n > state.limits.maxPin then
      log:warn("Rejecting user %d: code length %d not in %d-%d", id, n, state.limits.minPin, state.limits.maxPin)
      notifyLockChanged(
        string.format("Code must be %d-%d digits", state.limits.minPin, state.limits.maxPin),
        "Control4",
        false
      )
      return
    end
  end
  local u = state.users[id] or {}
  u.name = Select(tParams, "USER_NAME") or u.name or ("User " .. id)
  if not IsEmpty(code) then
    u.code = tostring(code)
  end
  local active = Select(tParams, "IS_ACTIVE")
  u.active = (active == nil) and true or toboolean(active)
  captureSchedule(u, tParams)
  state.users[id] = u
  saveUsers()
  local msg = string.format("%s User %d (%s)", isEdit and "Updated" or "Added", id, u.name)
  registerPending("pin:" .. id, "pin", id, msg, "user:" .. id)
  registerPending("sched:" .. id, "sched", id, msg, "user:" .. id)
  writeUserPin(id, u.active and u.code or nil)
  writeUserSchedule(id, u)
  notify(isEdit and "USER_CHANGED" or "USER_ADDED", userFields(id, u))
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
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- The proxy persists capability values, so a re-request must see current
  -- truth: replay both dynamic sets (user-code support and per-setting
  -- support), mirroring the native drivers' capability replay.
  applyUserCodeCapabilities()
  applySettingCapabilities()
end

function RFP.REQUEST_SETTINGS(idBinding, strCommand)
  log:trace("RFP.REQUEST_SETTINGS(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  notifySettings()
end

function RFP.REQUEST_CUSTOM_SETTINGS(idBinding, strCommand)
  log:trace("RFP.REQUEST_CUSTOM_SETTINGS(%s, %s)", idBinding, strCommand)
end

function RFP.REQUEST_USERS(idBinding, strCommand)
  log:trace("RFP.REQUEST_USERS(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  notifyUsers()
end

function RFP.REQUEST_HISTORY(idBinding, strCommand)
  log:trace("RFP.REQUEST_HISTORY(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  notify("HISTORY", historyXml())
end

function RFP.ADD_USER(idBinding, strCommand, tParams)
  log:trace("RFP.ADD_USER(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  upsertUser(tParams, false)
end

function RFP.EDIT_USER(idBinding, strCommand, tParams)
  log:trace("RFP.EDIT_USER(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  upsertUser(tParams, true)
end

function RFP.DELETE_USER(idBinding, strCommand, tParams)
  log:trace("RFP.DELETE_USER(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local id = tointeger(Select(tParams, "USER_ID"))
  if id == nil or state.users[id] == nil then
    return
  end
  local name = state.users[id].name
  state.users[id] = nil
  saveUsers()
  -- Any owed writes for the user are superseded by the revocation; the clear
  -- itself stays owed until the lock confirms it (a missed clear would leave a
  -- revoked PIN working while the UI says it is gone).
  cancelPending("pin:" .. id)
  cancelPending("sched:" .. id)
  registerPending("clear:" .. id, "clear", id, string.format("Deleted User %d (%s)", id, name or ""), nil)
  markPendingSent("clear:" .. id, sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(id)))
  notify("USER_DELETED", { USER_ID = id, USER_NAME = name })
end

function RFP.SET_AUTO_LOCK_SECONDS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_AUTO_LOCK_SECONDS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local secs = tointeger(Select(tParams, "SECONDS")) or 0
  if secs == state.autoLockSeconds then
    -- Nothing owed to the lock, but the echo still releases the settings UI.
    notify("SETTING_CHANGED", { NAME = "auto_lock_time", VALUE = tostring(secs) })
    return
  end
  state.autoLockSeconds = secs
  persist:set("autoLockSeconds", secs)
  registerPending("attr:autolock", "attr", ATTR_AUTO_RELOCK, nil, nil)
  writeSettingAttr("attr:autolock")
  notify("SETTING_CHANGED", { NAME = "auto_lock_time", VALUE = tostring(secs) })
end

function RFP.SET_ADMIN_CODE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_ADMIN_CODE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local code = tostring(Select(tParams, "PASSCODE") or "")
  if code == state.adminCode then
    notify("SETTING_CHANGED", { NAME = "admin_code", VALUE = code })
    return
  end
  state.adminCode = code
  -- The admin code is a secret; it only ever persists encrypted.
  persist:set("adminCode", state.adminCode, true)
  notify("SETTING_CHANGED", { NAME = "admin_code", VALUE = state.adminCode })
  addHistory("Changed Admin Code", "Control4")
end

function RFP.SET_NUMBER_LOG_ITEMS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_NUMBER_LOG_ITEMS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local count = tointeger(Select(tParams, "COUNT")) or 5
  if count == state.logItemCount then
    notify("SETTING_CHANGED", { NAME = "log_item_count", VALUE = tostring(count) })
    return
  end
  state.logItemCount = count
  persist:set("logItemCount", state.logItemCount)
  notify("SETTING_CHANGED", { NAME = "log_item_count", VALUE = tostring(state.logItemCount) })
end

function RFP.SET_SCHEDULE_LOCKOUT_ENABLED(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SCHEDULE_LOCKOUT_ENABLED(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local enabled = toboolean(Select(tParams, "ENABLED")) or false
  if enabled == state.scheduleLockoutEnabled then
    notify("SETTING_CHANGED", { NAME = "schedule_lockout_enabled", VALUE = tostring(enabled) })
    return
  end
  state.scheduleLockoutEnabled = enabled
  persist:set("scheduleLockoutEnabled", state.scheduleLockoutEnabled)
  notify("SETTING_CHANGED", { NAME = "schedule_lockout_enabled", VALUE = tostring(state.scheduleLockoutEnabled) })
end

function RFP.SET_VOLUME(idBinding, strCommand, tParams)
  log:trace("RFP.SET_VOLUME(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local volume = tostring(Select(tParams, "VOLUME") or "high")
  if VOLUME_TO_ZCL[volume] == nil then
    volume = "high"
  end
  if volume == state.volume then
    notify("SETTING_CHANGED", { NAME = "volume", VALUE = volume })
    return
  end
  state.volume = volume
  persist:set("volume", volume)
  registerPending("attr:volume", "attr", ATTR_SOUND_VOLUME, nil, nil)
  writeSettingAttr("attr:volume")
  notify("SETTING_CHANGED", { NAME = "volume", VALUE = volume })
end

function RFP.SET_ONE_TOUCH_LOCKING(idBinding, strCommand, tParams)
  log:trace("RFP.SET_ONE_TOUCH_LOCKING(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local enabled = toboolean(Select(tParams, "ENABLED")) or false
  if enabled == state.oneTouchLocking then
    notify("SETTING_CHANGED", { NAME = "one_touch_locking", VALUE = tostring(enabled) })
    return
  end
  state.oneTouchLocking = enabled
  persist:set("oneTouchLocking", enabled)
  registerPending("attr:onetouch", "attr", ATTR_ONE_TOUCH_LOCKING, nil, nil)
  writeSettingAttr("attr:onetouch")
  notify("SETTING_CHANGED", { NAME = "one_touch_locking", VALUE = tostring(enabled) })
end

function RFP.SET_WRONG_CODE_ATTEMPTS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_WRONG_CODE_ATTEMPTS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local count = tointeger(Select(tParams, "COUNT")) or 3
  if count == state.wrongCodeAttempts then
    notify("SETTING_CHANGED", { NAME = "wrong_code_attempts", VALUE = tostring(count) })
    return
  end
  state.wrongCodeAttempts = count
  persist:set("wrongCodeAttempts", count)
  registerPending("attr:wrongcode", "attr", ATTR_WRONG_CODE_LIMIT, nil, nil)
  writeSettingAttr("attr:wrongcode")
  notify("SETTING_CHANGED", { NAME = "wrong_code_attempts", VALUE = tostring(count) })
end

function RFP.SET_SHUTOUT_TIMER(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SHUTOUT_TIMER(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local secs = tointeger(Select(tParams, "SECONDS")) or 60
  if secs == state.shutoutTimer then
    notify("SETTING_CHANGED", { NAME = "shutout_timer", VALUE = tostring(secs) })
    return
  end
  state.shutoutTimer = secs
  persist:set("shutoutTimer", secs)
  registerPending("attr:shutout", "attr", ATTR_SHUTOUT_TIME, nil, nil)
  writeSettingAttr("attr:shutout")
  notify("SETTING_CHANGED", { NAME = "shutout_timer", VALUE = tostring(secs) })
end

-- Settings the proxy may send that have no ZCL mapping (kept for parity).
local function noopSetting(idBinding, strCommand)
  log:trace("noopSetting(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
end
RFP.SET_LOCK_MODE = noopSetting
RFP.SET_LOG_FAILED_ATTEMPTS = noopSetting
RFP.SET_LANGUAGE = noopSetting
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
  -- Re-send every user's full intent - PIN and schedule/user type - so a replay
  -- reconverges the lock (a PIN-only replay would reset restricted users to
  -- Unrestricted, silently removing their access windows).
  for id, u in pairs(state.users) do
    registerPending("pin:" .. id, "pin", id, nil, nil)
    registerPending("sched:" .. id, "sched", id, nil, nil)
    writeUserPin(id, u.active and u.code or nil)
    writeUserSchedule(id, u)
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

function OnZigbeePacketIn(packet, _profileId, clusterId, _groupId, srcEndpoint, _dstEndpoint)
  log:trace("OnZigbeePacketIn(<%d bytes>, 0x%04x)", #(packet or ""), clusterId or 0)
  if not gInitialized then
    return
  end
  state.dstEndpoint = srcEndpoint or state.dstEndpoint
  -- Any packet from the lock proves it is reachable. Recover Online here in case
  -- a driver reload missed the one-shot OnZigbeeOnlineStatusChanged callback.
  if not state.online then
    applyOnline(true)
  end
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
        if attrs[ATTR_LOCK_STATE] and attrs[ATTR_LOCK_STATE].value then
          applyLockStatus(zclLockStatus(attrs[ATTR_LOCK_STATE].value), "Status", "Control4", false)
        end
        -- Capability limits reported by the lock; use them for validation.
        if attrs[ATTR_NUM_PIN_USERS] and attrs[ATTR_NUM_PIN_USERS].value then
          state.limits.maxUsers = attrs[ATTR_NUM_PIN_USERS].value
        end
        if attrs[ATTR_MIN_PIN_LEN] and attrs[ATTR_MIN_PIN_LEN].value then
          state.limits.minPin = attrs[ATTR_MIN_PIN_LEN].value
        end
        if attrs[ATTR_MAX_PIN_LEN] and attrs[ATTR_MAX_PIN_LEN].value then
          state.limits.maxPin = attrs[ATTR_MAX_PIN_LEN].value
        end
        if attrs[ATTR_NUM_WEEKDAY_SCHED] and attrs[ATTR_NUM_WEEKDAY_SCHED].value then
          state.limits.weekDaySched = attrs[ATTR_NUM_WEEKDAY_SCHED].value
        end
        if attrs[ATTR_NUM_YEARDAY_SCHED] and attrs[ATTR_NUM_YEARDAY_SCHED].value then
          state.limits.yearDaySched = attrs[ATTR_NUM_YEARDAY_SCHED].value
        end
        -- ZCL-backed settings: the per-attribute status decides support (and
        -- shows/hides the control); good values adopt or re-assert desired.
        for key, s in pairs(SETTING_ATTRS) do
          local rec = attrs[s.attr]
          if rec then
            if rec.status == ZCL_STATUS_UNSUP_ATTR then
              setSettingSupport(key, false)
            elseif rec.value ~= nil then
              setSettingSupport(key, true)
              reconcileSetting(key, rec.value)
            end
          end
        end
      elseif not clusterSpecific and cmd == ZCL_WRITE_ATTR_RSP and #payload >= 1 then
        local status = payload:byte(1)
        -- A failed write response carries {status, attrId} records; an
        -- unsupported attribute hides its setting instead of raising an error.
        if status == ZCL_STATUS_UNSUP_ATTR and #payload >= 3 then
          local attrId = payload:byte(2) + payload:byte(3) * 256
          for key, s in pairs(SETTING_ATTRS) do
            if s.attr == attrId then
              setSettingSupport(key, false)
            end
          end
        end
        confirmSeq(seq, status)
      elseif clusterSpecific and cmd == DL_OPER_EVENT and #payload >= 2 then
        local code = payload:byte(2)
        local ls = DOORLOCK_EVENT[code]
        if ls then
          applyLockStatus(zclLockStatus(ls), "Operation", DOORLOCK_EVENT_SOURCE[code] or "Lock", true)
        end
      elseif clusterSpecific and cmd == DL_GET_PIN then
        -- The lock understood GetPINCode, so it has a keypad. Restore user
        -- management in case this driver was moved onto a keypad lock.
        setUserCodeSupport(true)
      elseif clusterSpecific and DL_RESPONSE_CMDS[cmd] and #payload >= 1 then
        -- Set/Clear PIN, schedule, and user-type responses echo our sequence
        -- with a status byte - they settle the matching owed write.
        confirmSeq(seq, payload:byte(1))
      elseif not clusterSpecific and cmd == ZCL_DEFAULT_RESPONSE and #payload >= 2 then
        local respCmd, status = payload:byte(1), payload:byte(2)
        -- A keypadless lock rejects user-code/schedule commands as unsupported;
        -- take that as the signal to drop user management.
        if status == ZCL_STATUS_UNSUP_CMD and CREDENTIAL_CMDS[respCmd] then
          setUserCodeSupport(false)
          cancelCredentialPending()
        else
          -- Some stacks ack global writes with a Default Response.
          confirmSeq(seq, status)
        end
      end
    elseif
      clusterId == CLUSTER_POWER
      and not clusterSpecific
      and (cmd == ZCL_REPORT_ATTR or cmd == ZCL_READ_ATTR_RSP)
    then
      local attrs = decodeAttributes(payload, cmd)
      if attrs[ATTR_BATT_PCT] and attrs[ATTR_BATT_PCT].value then
        local pct = math.floor(attrs[ATTR_BATT_PCT].value / 2 + 0.5)
        local prev = state.battery
        state.battery = pct
        -- Locks re-report the same level constantly; only a change reaches the
        -- proxy, and Battery Low fires on the crossing into low only (a first
        -- report seeds silently).
        if pct ~= prev then
          notifyBattery()
        end
        if pct <= 15 and prev ~= nil and prev > 15 then
          C4:FireEvent(EVENT_BATTERY_LOW)
        end
      end
    end
  end)
  if not ok then
    log:error("OnZigbeePacketIn: %s", tostring(err))
  end
  flushPendingOnAwake()
end

function OnZigbeePacketSuccess() end

function OnZigbeePacketFailed(_packet, _profileId, clusterId)
  log:debug("Zigbee send failed on cluster 0x%04x", clusterId or 0)
  -- A failed send while writes are owed just means the lock is asleep; make
  -- sure the retry window is armed to try again.
  armPendingTimer()
end

function OnZigbeeOnlineStatusChanged(strStatus, strVersion, _strSKU)
  log:trace("OnZigbeeOnlineStatusChanged('%s', '%s')", strStatus, strVersion)
  local online = strStatus ~= "OFFLINE"
  applyOnline(online)
  if online then
    if not IsEmpty(strVersion) then
      UpdateProperty("Firmware Version", strVersion)
    end
    -- Seed state from the lock (awake on join/report): status, the ZCL-backed
    -- settings, battery, and the capability limits we validate user saves
    -- against.
    readAttributes(CLUSTER_DOORLOCK, {
      ATTR_LOCK_STATE,
      ATTR_AUTO_RELOCK,
      ATTR_SOUND_VOLUME,
      ATTR_ONE_TOUCH_LOCKING,
      ATTR_WRONG_CODE_LIMIT,
      ATTR_SHUTOUT_TIME,
    })
    readAttributes(CLUSTER_DOORLOCK, {
      ATTR_NUM_PIN_USERS,
      ATTR_NUM_WEEKDAY_SCHED,
      ATTR_NUM_YEARDAY_SCHED,
      ATTR_MAX_PIN_LEN,
      ATTR_MIN_PIN_LEN,
    })
    -- Probe keypad support: a keypadless lock rejects this and we drop user mgmt.
    sendCommand(CLUSTER_DOORLOCK, DL_GET_PIN, u16le(1))
    readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
  else
    UpdateProperty("Firmware Version", "--")
  end
end

function OnNetworkBindingChanged(idBinding, bIsBound)
  log:trace("OnNetworkBindingChanged(%s, %s)", idBinding, bIsBound)
  if idBinding == ZIGBEE_BINDING and bIsBound then
    notifyLockInitialize()
  end
end

--#ifndef DRIVERCENTRAL
--- Sorted device ids of every instance of this driver. Multiple locks each run
--- their own copy; the lowest id acts as the update leader, and updater
--- property changes fan out so the instances stay consistent.
--- @return integer[]
local function getInstanceIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id in pairs(drivers) do
    ids[#ids + 1] = tonumber(id)
  end
  table.sort(ids)
  return ids
end

--- Mirror an updater property to the other instances so they stay consistent
--- (only the leader instance actually performs updates).
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(getInstanceIds()) do
    if deviceId ~= myId then
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end
--#endif

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
  -- At Ultra with printing on, also open up the drivers-common-public debugs.
  local ultra = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL, DEBUG_WEBSOCKET = ultra, ultra, ultra, ultra, ultra
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

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
        log:info("Updated driver(s): %s", table.concat(updated, ", "))
      end
    end, function(err)
      log:warn("Update check failed: %s", tostring(err))
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
  -- Unlock the File* APIs (the OSS GitHub updater downloads through them).
  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")
  loadState()
  for p in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err)
    end
  end
  gInitialized = true
  -- Settle Driver Status now that init is done; the property loop above left it
  -- at "Initializing" via the OPC.Driver_Status guard. Without this the driver
  -- stays "Initializing" until the lock reports online, which never happens
  -- before a lock is joined.
  updateDriverStatus()
  -- Tell the proxy our reachability up front, then let it initialize.
  notify("ONLINE_CHANGED", { STATE = state.online and true or false })
  notifyLockInitialize()
  -- Re-apply a known "no keypad" verdict from persistence right away, so a reload
  -- does not re-expose user management until the sleepy lock answers a probe.
  if not state.supportsUserCodes then
    applyUserCodeCapabilities()
  end
  -- Same for learned per-setting support verdicts.
  if next(state.settingSupport) ~= nil then
    applySettingCapabilities()
  end
  -- Writes owed from before the reload: re-arm the retry window but don't blast
  -- the sleeping lock now - its next inbound packet flushes them.
  armPendingTimer()
  -- A driver reload may not re-fire OnZigbeeOnlineStatusChanged for a lock that
  -- is already joined and online, which would leave the driver stuck Offline.
  -- Probe the lock once after init; if it is reachable it responds and
  -- OnZigbeePacketIn recovers Online and seeds lock state + battery.
  SetTimer("InitProbe", 3 * ONE_SECOND, function()
    readAttributes(CLUSTER_DOORLOCK, {
      ATTR_LOCK_STATE,
      ATTR_AUTO_RELOCK,
      ATTR_SOUND_VOLUME,
      ATTR_ONE_TOUCH_LOCKING,
      ATTR_WRONG_CODE_LIMIT,
      ATTR_SHUTOUT_TIME,
    })
    readAttributes(CLUSTER_DOORLOCK, {
      ATTR_NUM_PIN_USERS,
      ATTR_NUM_WEEKDAY_SCHED,
      ATTR_NUM_YEARDAY_SCHED,
      ATTR_MAX_PIN_LEN,
      ATTR_MIN_PIN_LEN,
    })
    sendCommand(CLUSTER_DOORLOCK, DL_GET_PIN, u16le(1))
    readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
  end)
  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", UPDATE_CHECK_INTERVAL, function()
    -- Only the leader (lowest-id) instance checks, so N locks don't all poll
    -- GitHub on the same controller.
    if Select(getInstanceIds(), 1) == C4:GetDeviceID() and toboolean(Properties["Automatic Updates"]) then
      UpdateDrivers(false)
    end
  end, true)
  --#endif
  log:info("Driver initialized")
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
end
