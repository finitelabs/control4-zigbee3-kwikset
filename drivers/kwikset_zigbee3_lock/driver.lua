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
DC_FILENAME = "kwikset_zigbee3_lock.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-zigbee3-kwikset"
DRIVER_FILENAMES = { "kwikset_zigbee3_lock.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local ZBind = require("zigbee3.zbind")
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
local CLUSTER_POLL_CONTROL = 0x0020
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
local ZCL_STATUS_INVALID_VALUE = 0x87 -- INVALID_VALUE

-- DoorLock cluster-specific command ids (client -> server)
local DL_LOCK = 0x00 -- <pin:octstr>
local DL_UNLOCK = 0x01 -- <pin:octstr>
local DL_GET_LOG_RECORD = 0x04 -- <logIndex:u16> (0 = most recent); response mirrors id
local DL_SET_PIN = 0x05 -- <userId:u16> <userStatus:u8> <userType:u8> <pin:octstr>
local DL_GET_PIN = 0x06 -- <userId:u16> (read-only; used to probe keypad support)
local DL_CLEAR_PIN = 0x07 -- <userId:u16>
local DL_SET_WEEKDAY_SCHED = 0x0b -- <schedId:u8> <userId:u16> <days:u8> <sH> <sM> <eH> <eM>
local DL_CLEAR_WEEKDAY_SCHED = 0x0d -- <schedId:u8> <userId:u16>
local DL_SET_YEARDAY_SCHED = 0x0e -- <schedId:u8> <userId:u16> <startZcl:u32> <endZcl:u32>
local DL_CLEAR_YEARDAY_SCHED = 0x10 -- <schedId:u8> <userId:u16>
-- DoorLock server -> client
local DL_OPER_EVENT = 0x20 -- Operating Event Notification

-- No Set User Type (0x14): Kwikset firmware rejects it (status 0x01) and
-- derives the user type from the schedule commands themselves.

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

-- DoorLock attributes
local ATTR_LOCK_STATE = 0x0000 -- 0 not-fully / 1 locked / 2 unlocked
local ATTR_NUM_LOG_RECORDS = 0x0010 -- NumberOfLogRecordsSupported (0 = no event log)
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
-- Basic cluster attributes
local ATTR_SW_BUILD = 0x4000 -- SWBuildID (char string, the firmware build, e.g. "v004.010.052")

-- Proxy volume strings <-> ZCL SoundVolume values (dialect per the native
-- Kwikset driver: ST_VOLUME is "high" | "low" | "silent").
local VOLUME_TO_ZCL = { silent = 0, low = 1, high = 2 }
local ZCL_TO_VOLUME = { [0] = "silent", [1] = "low", [2] = "high" }

-- Control4 lock proxy status strings
-- LOCK_STATUS values are the lock proxy's contract: it only recognizes these
-- exact lowercase strings and silently ignores anything else (which is why a
-- capitalized value leaves the proxy stuck on "unknown"). Not display labels.
local STATUS_LOCKED = "locked"
local STATUS_UNLOCKED = "unlocked"
local STATUS_FAULT = "fault"
local STATUS_UNKNOWN = "unknown"

-- Human-readable labels for the history log, where "Jammed" reads better than
-- the proxy's "fault". The proxy status value and the history text are two
-- different things.
local STATUS_LABEL = {
  [STATUS_LOCKED] = "Locked",
  [STATUS_UNLOCKED] = "Unlocked",
  [STATUS_FAULT] = "Jammed",
  [STATUS_UNKNOWN] = "Unknown",
}

-- Control4 lock proxy battery status values (drives the proxy's Status panel)
local BATTERY_NORMAL = "normal"
local BATTERY_WARNING = "warning"
local BATTERY_CRITICAL = "critical"

local MAX_USERS = 30
local HISTORY_MAX = 50
-- A status change within this many seconds of a driver lock/unlock is our own
-- doing (source "Control4"); an unsolicited change is a physical operation at
-- the lock (source "Manual") until the lock's report of the operation names it.
local CMD_ORIGIN_SECS = 8
-- An operation can name a status change that arrived from MATCH_EARLY_SECS before
-- its time on the lock's clock (both clocks count whole seconds) to MATCH_LATE_SECS after.
local MATCH_EARLY_SECS = 2
local MATCH_LATE_SECS = 30

gInitialized = false

local state = {
  seq = 0,
  srcEndpoint = 1,
  dstEndpoint = 1,
  dstEndpointLearned = false, -- true once the DoorLock cluster itself has spoken
  lockStatus = STATUS_UNKNOWN,
  -- The last operation LOCK_STATUS_CHANGED described: { desc, source, manual }.
  told = { desc = "", source = "Control4", manual = false },
  battery = nil,
  online = nil,
  cmdSentAt = 0, -- os.time() of the last RF lock/unlock, for the jam debounce
  faultRecheck = false, -- one silent re-poll consumed for a mid-throw "fault"
  -- Recent status changes in the order they arrived, each { status, at, source,
  -- manual, entry, op }, and the lock's reports of its operations, each { status,
  -- at, timed, desc, source, manual, live, seq }, `at` on the lock's clock (transient).
  changes = {},
  ops = {},
  logSupported = nil, -- true if the lock has an event log (attr 0x0010 > 0)
  -- Lock-side config settings, nil until the lock reports a value. The lock's
  -- value is adopted; a Control4 change goes to the lock as an owed write.
  autoLockSeconds = nil,
  volume = nil, -- "silent" | "low" | "high"
  oneTouchLocking = nil,
  wrongCodeAttempts = nil,
  shutoutTimer = nil,
  adminCode = "",
  logItemCount = 5,
  scheduleLockoutEnabled = false,
  -- Restrictive default: assume no keypad until the join probe confirms one, so
  -- user management is not exposed before it is proven. Re-probed on every
  -- online, so a module swap is picked up on the next reload.
  supportsUserCodes = false,
  -- Whether a definitive keypad verdict has been received; gates the probe retry.
  keypadKnown = false,
  users = {}, -- id -> { name, code, active, sched, slot } (persisted); slot is the user's id on the lock
  -- The lock's user ids, { first, last }, once its answers to the edge probe
  -- settle them (persisted); nil until then.
  userIds = nil,
  history = {}, -- array of { date, time, message, source }, newest last (persisted)
  pending = {}, -- owed lock writes: key -> { kind, id, msg, group, attempts, ts } (persisted)
  pendingSeq = {}, -- ZCL seq -> pending key (transient; rebuilt as sends go out)
  -- Deleted users' clears the lock refused or never confirmed, by owed-write key ->
  -- { id = slot, msg }; the old code may still open the door (persisted).
  uncleared = {},
  -- Per-setting support verdicts learned from the lock's per-attribute ZCL
  -- statuses; absent = assumed unsupported until the lock answers, matching the
  -- restrictive driver.xml defaults. false hides the setting via
  -- CAPABILITY_CHANGED. (persisted)
  settingSupport = {},
  -- Setting values the lock refused, by setting key and ZCL value, and the
  -- firmware build that refused them (persisted).
  refused = { values = {} },
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

--- The little-endian u32 at `pos` in `data`, or nil past its end.
--- @param data string
--- @param pos integer
--- @return integer|nil
local function u32At(data, pos)
  local a, b, c, d = data:byte(pos, pos + 3)
  return d and a + b * 256 + c * 65536 + d * 16777216 or nil
end

--- ZCL LocalTime for a date and a minute of that day: seconds since 2000-01-01
--- 00:00 on the lock's clock, which keeps local wall-clock time (DST included),
--- so it is counted on the calendar alone, with no time zone.
--- @param year integer
--- @param month integer
--- @param day integer
--- @param minutes integer Minutes from midnight.
--- @return integer
local function zclLocalTime(year, month, day, minutes)
  -- Days from 1970-01-01 (Hinnant's days_from_civil), less the 10957 to 2000-01-01.
  local y = month <= 2 and year - 1 or year
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468 - 10957) * 86400 + minutes * 60
end

--- The time now on the lock's clock, in the same form.
--- @return integer
local function lockNow()
  local dt = os.date("*t", os.time())
  return zclLocalTime(dt.year, dt.month, dt.day, dt.hour * 60 + dt.min) + dt.sec
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

--- Pull a string attribute out of a Read Attributes Response. decodeAttributes
--- only knows fixed-width numeric types and stops at the ZCL char-string type
--- (0x42, a length byte then bytes), so the SWBuildID needs its own read.
local function decodeStringAttr(payload, cmdId, wantAttr)
  local pos, n = 1, #payload
  while pos + 2 <= n + 1 do
    local attrId
    pos, attrId = string.unpack(payload, "<H", pos)
    local status = 0
    if cmdId == ZCL_READ_ATTR_RSP then
      pos, status = u8(payload, pos)
    end
    if status ~= 0 then
      return nil -- a failed record has no width; can't safely skip past it
    end
    local dtype
    pos, dtype = u8(payload, pos)
    if dtype == 0x41 or dtype == 0x42 then -- octet / character string
      local len
      pos, len = u8(payload, pos)
      local s = string.sub(payload, pos, pos + len - 1)
      if attrId == wantAttr then
        return s
      end
      pos = pos + len
    else
      local fmt = TYPE_FMT[dtype]
      if not fmt then
        return nil
      end
      pos = string.unpack(payload, fmt, pos)
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Lock proxy notifications (driver -> proxy)
-- ---------------------------------------------------------------------------

local function notify(strCommand, tParams)
  SendToProxy(PROXY_BINDING, strCommand, tParams or {}, "NOTIFY")
end

-- What a log line shows in place of a lock code.
local REDACTED = "***REDACTED***"

--- Tell the proxy something that carries a lock code. SendToProxy's trace would log
--- it whole, so it goes to C4 directly and is traced with each code redacted.
--- @param strCommand string
--- @param tParams table|string What the proxy is sent.
--- @param shown table|string The same, as the trace shows it.
local function notifySecret(strCommand, tParams, shown)
  log:trace("C4:SendToProxy(%s, %s, %s, NOTIFY)", PROXY_BINDING, strCommand, shown)
  C4:SendToProxy(PROXY_BINDING, strCommand, tParams, "NOTIFY")
end

--- `xml` with the text of every `tag` element redacted.
--- @param xml string
--- @param tag string
--- @return string
local function redactXml(xml, tag)
  return (xml:gsub("<" .. tag .. ">.-</" .. tag .. ">", "<" .. tag .. ">" .. REDACTED .. "</" .. tag .. ">"))
end

-- The vendored proxy handler prints a command's params at Ultra; these carry a code.
RFP.suppressDebug[PROXY_BINDING] = { ADD_USER = true, EDIT_USER = true, SET_ADMIN_CODE = true }

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

--- The lock's user ids: what its answers to the edge probe settled, else 1 to
--- N-1, which a lock numbering from 0 and one numbering from 1 both allow.
--- @return integer first
--- @return integer last
local function userIdRange()
  if state.userIds then
    return state.userIds.first, state.userIds.last
  end
  return 1, state.limits.maxUsers - 1
end

--- Push the capability set that matches state.supportsUserCodes to the proxy.
--- Called on init to assert the persisted verdict (correcting any stale value the
--- proxy kept across a driver update) and whenever the verdict changes.
--- Lock/unlock, status, battery, auto-lock, and history are never touched.
local function applyUserCodeCapabilities()
  local value = state.supportsUserCodes and "true" or "false"
  for _, name in ipairs(USER_CODE_CAPABILITIES) do
    notify("CAPABILITY_CHANGED", { NAME = name, VALUE = value })
  end
  local first, last = userIdRange()
  notify("CAPABILITY_CHANGED", {
    NAME = "max_users",
    VALUE = tostring(state.supportsUserCodes and last - first + 1 or 0),
  })
  notify("LOCK_CAPABILITIES_CHANGED", {})
end

-- Forward-declared: defined after SETTING_ATTRS but referenced by the verdict
-- setters above it (the capability re-probe, and the keypad-gated setting
-- re-apply used when the keypad verdict flips).
local capsResolved, stopCapProbe, applySettingCapabilities

--- Record whether the lock supports user codes and push the matching capability
--- set. A keypadless lock (e.g. a SmartCode Convert retrofit) rejects credential
--- commands, which hides user codes, schedules, and the admin code; a keypad lock
--- accepts them and gets full user management. Persisted, because these battery
--- locks sleep and may not answer a probe until well after the driver starts.
local function setUserCodeSupport(supported)
  -- Any call here is a definitive keypad verdict (a GetPIN reply or a credential
  -- rejection); record it so the capability probe can stop retrying.
  state.keypadKnown = true
  persist:set("keypadKnown", true)
  if state.supportsUserCodes ~= supported then
    state.supportsUserCodes = supported
    persist:set("supportsUserCodes", supported)
    log:info(
      "Lock %s user codes; %s user management",
      supported and "supports" or "does not support",
      supported and "restoring" or "dropping"
    )
    applyUserCodeCapabilities()
    -- Keypad-only settings (wrong-code, shutout, one-touch) also hinge on the
    -- keypad verdict, so re-evaluate them now that it changed.
    applySettingCapabilities()
  end
  if capsResolved() then
    stopCapProbe()
  end
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
  local xml = XMLTag("lock_users", body, nil, false)
  notifySecret("USERS", xml, redactXml(xml, "passcode"))
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

--- Store the history and send it to the proxy. The proxy asks for it only when the
--- driver loads and shows what it was last sent, so each change is sent as it happens.
local function saveHistory()
  persist:set("history", state.history)
  notify("HISTORY", historyXml())
end

--- Record a history event (newest appended last, capped to HISTORY_MAX).
--- @return table entry The entry, held by reference: the cap shifts indexes.
local function addHistory(message, source)
  log:trace("addHistory('%s', '%s')", message, source)
  local date, time = historyStamp()
  state.history[#state.history + 1] = {
    date = date,
    time = time,
    message = tostring(message or ""),
    source = tostring(source or "Control4"),
  }
  local entry = state.history[#state.history]
  while #state.history > HISTORY_MAX do
    table.remove(state.history, 1)
  end
  saveHistory()
  return entry
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function saveUsers()
  -- User PINs are door credentials; they only ever persist encrypted.
  persist:set("users", state.users, true)
end

local function loadState()
  log:trace("loadState()")
  -- The lock's learned application endpoint (see OnZigbeePacketIn); without it
  -- the first post-reload sends target the default endpoint and go unanswered.
  local dstEndpoint = tointeger(persist:get("dstEndpoint", nil))
  if dstEndpoint then
    state.dstEndpoint = dstEndpoint
    state.dstEndpointLearned = true
  end
  state.users = persist:get("users", {}, true) or {}
  local userIds = persist:get("userIds", nil)
  state.userIds = type(userIds) == "table" and userIds or nil
  -- Lock-side settings: absent means "never configured" (adopt from the lock).
  -- Every load type-checks its value, so one stored as another type also
  -- reads as never configured.
  state.autoLockSeconds = tonumber(persist:get("autoLockSeconds", nil))
  local volume = persist:get("volume", nil)
  state.volume = type(volume) == "string" and volume or nil
  local oneTouch = persist:get("oneTouchLocking", nil)
  if type(oneTouch) ~= "boolean" then
    oneTouch = nil
  end
  state.oneTouchLocking = oneTouch
  state.wrongCodeAttempts = tointeger(persist:get("wrongCodeAttempts", nil))
  state.shutoutTimer = tointeger(persist:get("shutoutTimer", nil))
  state.adminCode = persist:get("adminCode", "", true) or ""
  state.logItemCount = tointeger(persist:get("logItemCount", 5)) or 5
  state.scheduleLockoutEnabled = toboolean(persist:get("scheduleLockoutEnabled", false)) or false
  state.history = persist:get("history", {}) or {}
  -- Writes owed to the lock from a previous run; re-armed (not re-sent) in
  -- OnDriverLateInit and flushed when the lock next speaks.
  state.pending = persist:get("pendingWrites", {}) or {}
  local uncleared = persist:get("unclearedSlots", nil)
  state.uncleared = type(uncleared) == "table" and uncleared or {}
  state.settingSupport = persist:get("settingSupport", {}) or {}
  local refused = persist:get("settingRefused", nil)
  state.refused = type(refused) == "table" and type(refused.values) == "table" and refused or { values = {} }
  -- A stored value is the last verdict; unknown defaults to no keypad, so user
  -- management stays hidden until the lock proves it (restrictive default).
  state.supportsUserCodes = toboolean(persist:get("supportsUserCodes", false))
  state.keypadKnown = toboolean(persist:get("keypadKnown", false))
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
local refuseSettingValue
-- OnZigbeePacketIn hands the binder the endpoint the moment it learns it, above
-- where the binder is made.
local binder
local establishEventBinds

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

-- Until zserver has bound DoorLock, or if the lock refuses the bind, a modest
-- LockState poll is the only way to see physical operations, so it always runs.
-- Deliberate deviation from the event-driven polling convention.
local STATE_POLL_INTERVAL = 30 * ONE_SECOND
local BATTERY_POLL_INTERVAL = ONE_HOUR

local function startStatePolling()
  SetTimer("StatePoll", STATE_POLL_INTERVAL, function()
    readAttributes(CLUSTER_DOORLOCK, { ATTR_LOCK_STATE })
  end, true)
  SetTimer("BatteryPoll", BATTERY_POLL_INTERVAL, function()
    readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
  end, true)
end

local function stopStatePolling()
  CancelTimer("StatePoll")
  CancelTimer("BatteryPoll")
end

--- Update online state, Driver Status, and the proxy's ONLINE_CHANGED notify.
local function applyOnline(online)
  local changed = state.online ~= online
  state.online = online
  updateDriverStatus()
  if changed then
    notify("ONLINE_CHANGED", { STATE = online and true or false })
    if online then
      startStatePolling()
    else
      stopStatePolling()
    end
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
    e.seq = seq
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
  if e.kind == "clear" then
    -- Its slot is not reused while the old code may still open the door.
    state.uncleared[key] = { id = e.id, msg = e.msg }
    persist:set("unclearedSlots", state.uncleared)
  end
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
  local e = state.pending[key]
  if status == 0 then
    confirmPending(key)
  elseif e and e.kind == "attr" and status == ZCL_STATUS_INVALID_VALUE then
    -- A setting the lock has, refusing the value (low volume on a 916).
    refuseSettingValue(key, seq)
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

--- Ask the lock for its newest event-log record, to attribute a physical
--- operation the bare LOCK_STATE report could not. Deferred briefly so the lock
--- has committed the entry (it stays awake for a few seconds after operating),
--- and not asked once an operation event has named the change.
local function requestLogAttribution()
  if not state.logSupported then
    return
  end
  SetTimer("LogAttr", 400, function()
    local c = state.changes[#state.changes]
    if c and not c.op then
      sendCommand(CLUSTER_DOORLOCK, DL_GET_LOG_RECORD, u16le(0))
    end
  end)
end

--- Forget the changes and operations too old to pair again; a change keeps the
--- source it was given, and an operation that named one goes with it.
--- @param now integer The lock's clock.
local function pruneOperations(now)
  local horizon = now - 2 * MATCH_LATE_SECS
  local kept, gone = {}, {}
  for _, c in ipairs(state.changes) do
    if c.at >= horizon then
      kept[#kept + 1] = c
    elseif c.op then
      gone[c.op] = true
    end
  end
  state.changes = kept
  kept = {}
  for _, op in ipairs(state.ops) do
    if not gone[op] and op.at >= horizon - MATCH_LATE_SECS then
      kept[#kept + 1] = op
    end
  end
  state.ops = kept
end

--- Pair the lock's operations with the status changes they describe, in the order of
--- the lock's own clock: each names the first change of its status after the change
--- the operation before it named, among those that arrived within its bounds. A name
--- given before an earlier operation's report arrived so moves to its own change.
--- @return boolean moved Whether a history entry's source changed.
local function matchOperations()
  table.sort(state.ops, function(a, b)
    return a.at < b.at or (a.at == b.at and a.seq < b.seq)
  end)
  for _, c in ipairs(state.changes) do
    c.op = nil
  end
  local from = 1
  for _, op in ipairs(state.ops) do
    for i = from, #state.changes do
      local c = state.changes[i]
      if c.status == op.status and c.at >= op.at - MATCH_EARLY_SECS and c.at <= op.at + MATCH_LATE_SECS then
        c.op, from = op, i + 1
        break
      end
    end
  end
  local moved = false
  for _, c in ipairs(state.changes) do
    local source = c.op and c.op.source or c.source
    if c.entry and c.entry.source ~= source then
      c.entry.source, moved = source, true
    end
  end
  return moved
end

local opSeq = 0

--- Apply a lock status to the proxy, history, and events.
--- @param status string one of the STATUS_* proxy values
--- @param op table|nil the lock's report of the operation, from an operation event
---   (live) or the event log: { at, timed, desc, source, manual, live }; nil for a bare
---   LOCK_STATE report, whose actor is inferred
local function applyLockStatus(status, op)
  log:trace("applyLockStatus('%s', '%s')", status, tostring(op and op.desc))
  local now = lockNow()
  if op then
    for _, o in ipairs(state.ops) do
      if op.timed and o.timed and o.at == op.at and o.status == status then
        return -- the same operation again: its event and its log record
      end
    end
    opSeq = opSeq + 1
    op.status, op.seq = status, opSeq
    state.ops[#state.ops + 1] = op
  end
  local prev = state.lockStatus
  -- A log record tells what the lock did, not what it is now.
  local changed = status ~= prev and (op == nil or op.live)
  if changed then
    state.lockStatus = status
  end
  -- Real transitions log to history and fire the alert event; the initial sync
  -- out of UNKNOWN (a reload seeding current state) must do neither, so a reload
  -- never announces a lock that did not actually move. A change we just
  -- commanded is ours; an otherwise-unsolicited one was a physical operation.
  local c
  if changed and prev ~= STATUS_UNKNOWN and status ~= STATUS_UNKNOWN then
    local ours = (os.time() - (state.cmdSentAt or 0)) <= CMD_ORIGIN_SECS
    c = { status = status, at = now, source = ours and "Control4" or "Manual", manual = not ours }
    state.changes[#state.changes + 1] = c
  end
  pruneOperations(now)
  local moved = matchOperations()
  if op then
    -- One that names no change as it arrives (the reading after a reload, a lock or
    -- unlock of a lock already there, an old log record) is not kept to name a later one.
    local named = false
    for _, ch in ipairs(state.changes) do
      named = named or ch.op == op
    end
    for i, o in ipairs(state.ops) do
      if o == op and not named then
        table.remove(state.ops, i)
        break
      end
    end
  end
  if c then
    c.entry = addHistory(STATUS_LABEL[status] or status, c.op and c.op.source or c.source)
  elseif moved then
    saveHistory()
  end

  -- The proxy is told the newest change as the lock's report named it, or the
  -- operation that set a status out of UNKNOWN; a reading that set one names none.
  local told = state.told
  local newest = state.changes[#state.changes]
  if newest and newest.status == state.lockStatus then
    told = newest.op or { desc = STATUS_LABEL[newest.status] or "", source = newest.source, manual = newest.manual }
  elseif changed then
    told = op or { desc = told.desc, source = "Control4", manual = false }
  end
  state.told = told
  notifyLockChanged(told.desc, told.source, told.manual)
  log:info("Lock is %s (%s)", status, tostring(told.desc))
  if c then
    if c.manual and not c.op then
      -- A physical operation with no actor in the packet: the event log has it.
      requestLogAttribution()
    end
    if status == STATUS_LOCKED then
      C4:FireEvent(EVENT_LOCKED)
    elseif status == STATUS_UNLOCKED then
      C4:FireEvent(EVENT_UNLOCKED)
    elseif status == STATUS_FAULT then
      C4:FireEvent(EVENT_JAMMED)
    end
  end
end

local function pollLockState()
  SetTimer("PollLock", 1.5 * ONE_SECOND, function()
    readAttributes(CLUSTER_DOORLOCK, { ATTR_LOCK_STATE })
  end)
end

local function lock()
  log:trace("lock()")
  state.cmdSentAt = os.time()
  state.faultRecheck = false
  sendCommand(CLUSTER_DOORLOCK, DL_LOCK, octstr(state.adminCode))
  pollLockState()
end

local function unlock()
  log:trace("unlock()")
  state.cmdSentAt = os.time()
  state.faultRecheck = false
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
-- Operation-event code -> the manner of the operation, when the code names one
-- (one-touch, key, auto, schedule, manual). The plain lock/unlock codes
-- (0x01/0x02) carry no manner; their attribution comes from the source field.
local DOORLOCK_EVENT_MANNER = {
  [0x07] = "One Touch",
  [0x08] = "Key",
  [0x09] = "Key",
  [0x0a] = "Auto",
  [0x0b] = "Schedule",
  [0x0c] = "Schedule",
  [0x0d] = "Manual",
  [0x0e] = "Manual",
}
-- ZCL DoorLock OperationEventSource (the first payload byte) -> who acted; a
-- distinct field from the event code.
local OP_EVENT_SOURCE = {
  [0x00] = "Keypad",
  [0x01] = "RF",
  [0x02] = "Manual",
  [0x03] = "RFID",
  [0xFF] = "Indeterminate",
}

--- The user an operation names by its user id on the lock: the stored user at
--- that slot, else "User <id>" for one of the lock's ids; nil for none (0xFFFF).
--- @param uid integer
--- @return string|nil
local function operationUser(uid)
  for id, u in pairs(state.users) do
    if u.slot == uid then
      return u.name or ("User " .. id)
    end
  end
  local first, last = userIdRange()
  if uid >= first and uid <= last then
    return "User " .. uid
  end
  return nil
end

--- Attribute an operation, from an operation event (cmd 0x20) or an event-log
--- record (cmd 0x04): derive the source, user, and manual flag from the ZCL
--- event code, source byte, and user id, then apply. RF right after our own
--- command is the driver's doing. Only a keypad or RFID operation names a user.
--- @param st string resolved STATUS_* value
--- @param code integer ZCL OperationEvent code
--- @param src integer ZCL OperationEventSource byte
--- @param uid integer user id on the lock (0xFFFF = none)
--- @param at integer when it happened, on the lock's clock
--- @param live boolean an operation event, not a log record
--- @param timed boolean `at` is the lock's own time, not the arrival
local function attributeOperation(st, code, src, uid, at, live, timed)
  local rf = src == 0x01
  local ours = rf and (os.time() - (state.cmdSentAt or 0)) <= CMD_ORIGIN_SECS
  local manner = ours and "Control4" or (DOORLOCK_EVENT_MANNER[code] or OP_EVENT_SOURCE[src] or "Lock")
  -- The proxy source (and history) names the user when the operation carries
  -- one, otherwise the manner; the manner is always kept in the description.
  local who = manner
  local desc = STATUS_LABEL[st] or st
  -- A user's code is entered at the lock; Control4's RF lock and unlock carry the
  -- admin code, so an RF or manual operation's user id names no user.
  local user = (src == 0x00 or src == 0x03) and operationUser(uid) or nil
  if user then
    who = user
    desc = desc .. " by " .. who
  end
  desc = desc .. " (" .. manner .. ")"
  applyLockStatus(st, { at = at, timed = timed, desc = desc, source = who, manual = not rf, live = live })
end

--- Set or clear a user's PIN on the lock, per ZCL DoorLock, at the user's slot.
--- The send is tied to its owed-write entry so the lock's response settles it.
local function writeUserPin(id, code)
  log:trace("writeUserPin(%s)", id)
  local slot = state.users[id].slot
  local seq
  if code and #code >= 4 then
    -- status Occupied (1), type Unrestricted (0)
    local payload = u16le(slot) .. string.char(1) .. string.char(0) .. octstr(code)
    seq = sendCommand(CLUSTER_DOORLOCK, DL_SET_PIN, payload)
  else
    seq = sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(slot))
  end
  markPendingSent("pin:" .. id, seq)
end

-- Weekday bit values; SCHEDULED_DAYS[1]=Sunday .. [7]=Saturday and the ZCL
-- weekday DaysMask has bit0=Sunday .. bit6=Saturday.
local WEEKDAY_BITS = { 1, 2, 4, 8, 16, 32, 64 }

--- Push a user's schedule to the lock (ZCL DoorLock) at the user's slot. A
--- restricted user gets a weekday or yearday schedule; an unrestricted user has
--- both cleared. The lock derives the user type from the schedule itself and
--- enforces the window on its own keypad. Each branch's final command settles
--- the owed write.
local function writeUserSchedule(id, u)
  log:trace("writeUserSchedule(%s)", id)
  local s = u.sched or {}
  if not s.restricted then
    sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_WEEKDAY_SCHED, string.char(0) .. u16le(u.slot))
    markPendingSent(
      "sched:" .. id,
      sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_YEARDAY_SCHED, string.char(0) .. u16le(u.slot))
    )
    return
  end
  if s.type == "date_range" then
    local startT = zclLocalTime(s.startYear or 2000, s.startMonth or 1, s.startDay or 1, s.startTime or 0)
    local endT = zclLocalTime(s.endYear or 2000, s.endMonth or 1, s.endDay or 1, s.endTime or 0)
    markPendingSent(
      "sched:" .. id,
      sendCommand(
        CLUSTER_DOORLOCK,
        DL_SET_YEARDAY_SCHED,
        string.char(0) .. u16le(u.slot) .. u32le(startT) .. u32le(endT)
      )
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
      .. u16le(u.slot)
      .. string.char(days, math.floor(st / 60), st % 60, math.floor(et / 60), et % 60)
    markPendingSent("sched:" .. id, sendCommand(CLUSTER_DOORLOCK, DL_SET_WEEKDAY_SCHED, payload))
  end
end

--- Seconds as the proxy's auto-lock and shutout lists show them.
--- @param v integer
local function secondsText(v)
  if v >= 60 and v % 60 == 0 then
    return string.format("%d min", v / 60)
  end
  return string.format("%d sec", v)
end

local function identity(v)
  return v
end

-- ZCL-backed lock settings, keyed by their owed-write key. Each entry knows its
-- attribute and ZCL type, its state field (also its persist key), its proxy
-- setting name, how its value maps to the ZCL value, and how history names it.
-- A setting with a value list offers the driver.xml list less what the lock
-- refused, plus the lock's own value when the list lacks it.
local SETTING_ATTRS = {
  ["attr:autolock"] = {
    attr = ATTR_AUTO_RELOCK,
    cap = "has_auto_lock_time",
    type = 0x23, -- u32 seconds, 0 = off
    field = "autoLockSeconds",
    name = "auto_lock_time",
    label = "Auto lock",
    toZcl = identity,
    fromZcl = identity,
    text = function(v)
      return v == 0 and "OFF" or secondsText(v)
    end,
    list = {
      cap = "auto_lock_time_values",
      displayCap = "auto_lock_time_display_values",
      values = { 0, 15, 30, 60, 120, 180, 300, 600, 1200, 1800 },
    },
  },
  ["attr:volume"] = {
    attr = ATTR_SOUND_VOLUME,
    cap = "has_volume",
    type = 0x20, -- u8
    field = "volume",
    name = "volume",
    label = "Keypad volume",
    toZcl = function(v)
      return VOLUME_TO_ZCL[v]
    end,
    fromZcl = function(z)
      return ZCL_TO_VOLUME[z]
    end,
    text = tostring,
  },
  ["attr:onetouch"] = {
    attr = ATTR_ONE_TOUCH_LOCKING,
    cap = "has_one_touch_locking",
    keypadOnly = true,
    type = 0x10, -- bool
    field = "oneTouchLocking",
    name = "one_touch_locking",
    label = "One touch locking",
    toZcl = function(v)
      return v and 1 or 0
    end,
    fromZcl = function(z)
      return z ~= 0
    end,
    text = function(v)
      return v and "on" or "off"
    end,
  },
  ["attr:wrongcode"] = {
    attr = ATTR_WRONG_CODE_LIMIT,
    cap = "has_wrong_code_attempts",
    keypadOnly = true,
    type = 0x20, -- u8
    field = "wrongCodeAttempts",
    name = "wrong_code_attempts",
    label = "Wrong code attempts",
    toZcl = identity,
    fromZcl = identity,
    text = tostring,
    list = { cap = "wrong_code_attempts_values", values = { 1, 2, 3, 4, 5, 6, 7 } },
  },
  ["attr:shutout"] = {
    attr = ATTR_SHUTOUT_TIME,
    cap = "has_shutout_timer",
    keypadOnly = true,
    type = 0x20, -- u8 seconds
    field = "shutoutTimer",
    name = "shutout_timer",
    label = "Shutout timer",
    toZcl = identity,
    fromZcl = identity,
    text = secondsText,
    list = {
      cap = "shutout_timer_values",
      displayCap = "shutout_timer_display_values",
      values = { 5, 10, 30, 60, 120 },
    },
  },
}

--- Whether the lock refused a setting's ZCL value (on its current firmware).
local function isRefused(key, z)
  local values = state.refused.values[key]
  return values ~= nil and values[tostring(z)] == true
end

--- Tell the proxy the values a list-backed setting offers.
local function notifySettingValues(key)
  local s = SETTING_ATTRS[key]
  local current = state[s.field]
  local values = {}
  for _, v in ipairs(s.list.values) do
    if v ~= current and not isRefused(key, v) then
      values[#values + 1] = v
    end
  end
  if current ~= nil then
    values[#values + 1] = current
    table.sort(values)
  end
  local texts = {}
  for i, v in ipairs(values) do
    texts[i] = s.text(v)
  end
  notify("CAPABILITY_CHANGED", { NAME = s.list.cap, VALUE = table.concat(values, ", ") })
  if s.list.displayCap then
    notify("CAPABILITY_CHANGED", { NAME = s.list.displayCap, VALUE = table.concat(texts, ",") })
  end
end

--- Write a ZCL-backed setting's desired value to the lock via a global Write
--- Attributes frame, tied to its owed-write entry.
local function writeSettingAttr(key)
  log:trace("writeSettingAttr(%s)", key)
  local s = SETTING_ATTRS[key]
  local v = s.toZcl(state[s.field])
  local payload
  if s.type == 0x23 then
    payload = u16le(s.attr) .. string.char(s.type) .. u32le(v)
  else
    payload = u16le(s.attr) .. string.char(s.type) .. string.char(v % 256)
  end
  markPendingSent(key, writeAttributes(CLUSTER_DOORLOCK, payload))
end

--- Take a value the lock holds as the setting's, and tell the proxy.
local function adoptSetting(key, z)
  local s = SETTING_ATTRS[key]
  local v = s.fromZcl(z)
  if v == nil then
    return
  end
  state[s.field] = v
  persist:set(s.field, v)
  notify("SETTING_CHANGED", { NAME = s.name, VALUE = tostring(v) })
  if s.list then
    notifySettingValues(key)
    notify("LOCK_CAPABILITIES_CHANGED", {})
  end
end

--- Reconcile a lock-reported setting: the lock is the source of truth. A
--- device-side change (DIP switch, body menu, factory reset) is adopted and
--- echoed to the proxy; re-asserting a stored value would fight it. Control4-side
--- sets still write through as owed writes; while one is in flight the report is
--- left alone.
local function reconcileSetting(key, reported)
  local s = SETTING_ATTRS[key]
  if state.pending[key] ~= nil then
    return
  end
  local current = state[s.field]
  if current == nil or s.toZcl(current) ~= reported then
    adoptSetting(key, reported)
  end
end

--- Effective capability for a ZCL-backed setting: the attribute must be
--- supported, and keypad-only settings (wrong-code, shutout, one-touch) also
--- require a keypad. Auto-lock and volume apply to keypadless locks too, so they
--- are gated on the attribute alone.
local function settingCapEnabled(key)
  if state.settingSupport[key] ~= true then
    return false
  end
  if SETTING_ATTRS[key].keypadOnly and not state.supportsUserCodes then
    return false
  end
  return true
end

--- The lock's settings for the proxy. A lock setting is listed only when the
--- lock offers it, with the value it holds; none is made up for one it lacks.
local function notifySettings()
  log:trace("notifySettings()")
  local function setting(key)
    local s = SETTING_ATTRS[key]
    local v = state[s.field]
    if v == nil or not settingCapEnabled(key) then
      return ""
    end
    return XMLTag(s.name, tostring(v))
  end
  local body = XMLTag("admin_code", state.adminCode)
    .. setting("attr:autolock")
    .. XMLTag("log_item_count", state.logItemCount)
    .. XMLTag("schedule_lockout_enabled", tostring(state.scheduleLockoutEnabled))
    .. XMLTag("lock_mode", "normal")
    .. XMLTag("log_failed_attempts", "false")
    .. setting("attr:wrongcode")
    .. setting("attr:shutout")
    .. XMLTag("language", "English")
    .. setting("attr:volume")
    .. setting("attr:onetouch")
  local xml = XMLTag("lock_settings", body, nil, false)
  notifySecret("SETTINGS", xml, redactXml(xml, "admin_code"))
end

--- Take a Control4 change to a lock setting. It is written, as an owed write,
--- only when the lock offers the setting and has not refused the value.
--- @param key string
--- @param v any The value in the proxy's terms; nil for none it can take.
local function takeSetting(key, v)
  local s = SETTING_ATTRS[key]
  local current = state[s.field]
  if v ~= nil and v ~= current and settingCapEnabled(key) then
    if isRefused(key, s.toZcl(v)) then
      notifyLockChanged(string.format("%s %s - Not supported by this device", s.label, s.text(v)), "Control4", false)
    else
      current = v
      state[s.field] = v
      persist:set(s.field, v)
      registerPending(key, "attr", s.attr, nil, nil)
      writeSettingAttr(key)
    end
  end
  -- The echo releases the proxy's settings UI, with the value that stands; for a
  -- setting the lock does not offer that is SETTINGS, which leaves it out.
  if current ~= nil and settingCapEnabled(key) then
    notify("SETTING_CHANGED", { NAME = s.name, VALUE = tostring(current) })
  else
    notifySettings()
  end
end

--- The lock refused the value written for a setting: say so, write it no more,
--- and read back the value the lock kept. A refusal of a write a newer one has
--- replaced is left to that one's answer.
refuseSettingValue = function(key, seq)
  local e = state.pending[key]
  if e == nil or e.seq ~= seq then
    return
  end
  local s = SETTING_ATTRS[key]
  local v = state[s.field]
  local refused = state.refused.values
  refused[key] = refused[key] or {}
  refused[key][tostring(s.toZcl(v))] = true
  persist:set("settingRefused", state.refused)
  cancelPending(key)
  local msg = string.format("%s %s - Not supported by this device", s.label, s.text(v))
  log:info("Lock refused %s", msg)
  addHistory(msg, "Control4")
  notifyLockChanged(msg, "Control4", false)
  readAttributes(CLUSTER_DOORLOCK, { s.attr })
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
  local enabled = settingCapEnabled(key)
  log:info(
    "Lock %s %s; %s its setting",
    supported and "supports" or "does not support",
    s.cap,
    enabled and "showing" or "hiding"
  )
  notify("CAPABILITY_CHANGED", { NAME = s.cap, VALUE = enabled and "true" or "false" })
  notify("LOCK_CAPABILITIES_CHANGED", {})
  if not supported then
    cancelPending(key)
  end
  if capsResolved() then
    stopCapProbe()
  end
end

--- Replay every ZCL-backed setting's effective capability, and the values each
--- list-backed one offers, to the proxy. Unknown attributes count as unsupported
--- (matching the restrictive driver.xml defaults), and keypad-only settings stay
--- hidden until a keypad is confirmed.
applySettingCapabilities = function()
  for key, s in pairs(SETTING_ATTRS) do
    notify("CAPABILITY_CHANGED", { NAME = s.cap, VALUE = settingCapEnabled(key) and "true" or "false" })
    if s.list then
      notifySettingValues(key)
    end
  end
  notify("LOCK_CAPABILITIES_CHANGED", {})
end

--- Refusals hold for the firmware that made them: other firmware is offered
--- every value again.
--- @param build string The lock's SWBuildID.
local function noteFirmware(build)
  local r = state.refused
  if r.build == build then
    return
  end
  if r.build ~= nil and next(r.values) ~= nil then
    log:info("Lock firmware is now %s; offering again what %s refused", build, r.build)
    r.values = {}
    applySettingCapabilities()
  end
  r.build = build
  persist:set("settingRefused", r)
end

-- ---------------------------------------------------------------------------
-- Capability probe (reliable)
-- ---------------------------------------------------------------------------
-- Support verdicts come from reads a sleepy lock can miss on a fresh join: the
-- online event may fire before the device's ZCL is ready, and the reads are not
-- otherwise retried. Re-issue them on a bounded timer until every verdict
-- resolves, so the restrictive defaults are corrected to the lock's real
-- capabilities instead of staying off.

local TIMER_CAP_PROBE = "CapProbe"
local CAP_PROBE_INTERVAL = 5 * ONE_SECOND
local CAP_PROBE_MAX_TRIES = 12
local capProbeTries = 0

-- Edge probe of the lock's user ids. ZCL allows 0 to N-1 or 1 to N for N PIN
-- users, so Get PIN goes to ids 0 and N and the lock's answers settle which.
local idProbe -- { n, seqs = { [seq] = id }, answers = { [id] = answered } } (transient)

--- True once every ZCL-backed setting has a verdict, the keypad has answered,
--- and a keypad lock has answered or refused both probed user ids.
capsResolved = function()
  for key in pairs(SETTING_ATTRS) do
    if state.settingSupport[key] == nil then
      return false
    end
  end
  if not state.keypadKnown then
    return false
  end
  local p = idProbe
  if not state.supportsUserCodes or (p and p.n < 1) then
    return true
  end
  return p ~= nil and p.answers[0] ~= nil and p.answers[p.n] ~= nil
end

--- Issue the capability reads and the keypad probe once.
local function probeCapabilities()
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
    ATTR_NUM_LOG_RECORDS,
  })
  sendCommand(CLUSTER_DOORLOCK, DL_GET_PIN, u16le(1))
end

stopCapProbe = function()
  CancelTimer(TIMER_CAP_PROBE)
end

--- Ask the lock for ids 0 and N, each until it answers. Each capability probe
--- reads N again, so an answer the lock missed is asked for on the next round.
--- @param n integer NumberOfPINUsersSupported
local function probeUserIds(n)
  if not idProbe or idProbe.n ~= n then
    idProbe = { n = n, seqs = {}, answers = {} }
  end
  if n < 1 then
    return
  end
  for _, id in ipairs({ 0, n }) do
    if idProbe.answers[id] == nil then
      idProbe.seqs[sendCommand(CLUSTER_DOORLOCK, DL_GET_PIN, u16le(id))] = id
    end
  end
end

--- Take the lock's answer to a probed id: a Get PIN response (answered) or an
--- error status (refused). Both edges in, the ids are 0 to N-1 if only 0 was
--- answered, 1 to N if only N was, and unsettled otherwise.
--- @param id integer|nil
--- @param answered boolean
local function noteUserIdAnswer(id, answered)
  local p = idProbe
  if not p or (id ~= 0 and id ~= p.n) or p.answers[id] ~= nil then
    return
  end
  p.answers[id] = answered
  local zero, top = p.answers[0], p.answers[p.n]
  if zero == nil or top == nil then
    return
  end
  if capsResolved() then
    stopCapProbe()
  end
  local ids
  if zero and not top then
    ids = { first = 0, last = p.n - 1 }
  elseif top and not zero then
    ids = { first = 1, last = p.n }
  end
  local old = state.userIds
  if (old and old.first) == (ids and ids.first) and (old and old.last) == (ids and ids.last) then
    return
  end
  state.userIds = ids
  persist:set("userIds", ids)
  local first, last = userIdRange()
  log:info("Lock user ids are %d to %d%s", first, last, ids and "" or " (unsettled by the lock's answers)")
  applyUserCodeCapabilities()
end

--- Probe now, then retry on a bounded timer until the verdicts resolve. Run on
--- every online transition, so a module swap is re-probed too.
local function startCapProbe()
  idProbe = nil
  probeCapabilities()
  capProbeTries = 0
  if capsResolved() then
    return
  end
  SetTimer(TIMER_CAP_PROBE, CAP_PROBE_INTERVAL, function()
    if capsResolved() then
      stopCapProbe()
      return
    end
    capProbeTries = capProbeTries + 1
    if capProbeTries > CAP_PROBE_MAX_TRIES then
      stopCapProbe()
      log:debug("capabilities unresolved after %d probes; retrying on next online", capProbeTries)
      return
    end
    probeCapabilities()
  end, true)
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

--- The lowest of the lock's user ids that no stored user holds and no owed or
--- uncleared clear is still emptying; nil when the lock is full.
--- @return integer|nil
local function freeSlot()
  local taken = {}
  for _, u in pairs(state.users) do
    taken[u.slot] = true
  end
  for _, e in pairs(state.pending) do
    if e.kind == "clear" then
      taken[e.id] = true
    end
  end
  for _, e in pairs(state.uncleared) do
    taken[e.id] = true
  end
  local first, last = userIdRange()
  for slot = first, last do
    if not taken[slot] then
      return slot
    end
  end
  return nil
end

--- Add or edit a user code. tParams carries USER_ID/USER_NAME/PASSCODE/IS_ACTIVE
--- and optional schedule fields. The lock proxy has no reject-with-message path,
--- so when a save would trip a lock limit we refuse it and surface the reason in
--- the Last Action Description (notifyLockChanged), the only free-text channel.
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
    id = 1
    while state.users[id] ~= nil do
      id = id + 1
    end
  end
  -- A stored user keeps its slot; a new one takes the lowest free of the lock's ids.
  local prev = state.users[id]
  local slot
  if prev then
    slot = prev.slot
  else
    slot = freeSlot()
  end
  if slot == nil then
    local first, last = userIdRange()
    log:warn("No free user slot (lock ids %d to %d)", first, last)
    notifyLockChanged(string.format("Cannot add user: lock supports %d codes", last - first + 1), "Control4", false)
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
  local prevCode = prev and prev.code or nil
  local prevActive = prev and toboolean(prev.active)
  local u = prev or {}
  u.slot = slot
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
  -- The lock rejects re-writing an occupied slot with its own PIN (duplicate
  -- check), so the PIN write only goes out when the code or active state
  -- actually changed; the schedule is idempotent and always re-pushed.
  local pinChanged = prevCode ~= u.code or prevActive ~= u.active
  if pinChanged then
    registerPending("pin:" .. id, "pin", id, msg, "user:" .. id)
  end
  registerPending("sched:" .. id, "sched", id, msg, "user:" .. id)
  if pinChanged then
    writeUserPin(id, u.active and u.code or nil)
  end
  writeUserSchedule(id, u)
  local fields, shown = userFields(id, u), userFields(id, u)
  shown.PASSCODE = REDACTED
  notifySecret(isEdit and "USER_CHANGED" or "USER_ADDED", fields, shown)
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
  if idBinding ~= PROXY_BINDING then
    return
  end
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
  -- tParams is deliberately omitted from the trace: it carries PASSCODE.
  log:trace("RFP.ADD_USER(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  upsertUser(tParams, false)
end

function RFP.EDIT_USER(idBinding, strCommand, tParams)
  -- tParams is deliberately omitted from the trace: it carries PASSCODE.
  log:trace("RFP.EDIT_USER(%s, %s)", idBinding, strCommand)
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
  local name, slot = state.users[id].name, state.users[id].slot
  state.users[id] = nil
  saveUsers()
  -- Any owed writes for the user are superseded by the revocation; the clear
  -- itself stays owed until the lock confirms it (a missed clear would leave a
  -- revoked PIN working while the UI says it is gone). It is keyed by the slot,
  -- which stays taken until then.
  cancelPending("pin:" .. id)
  cancelPending("sched:" .. id)
  registerPending("clear:" .. slot, "clear", slot, string.format("Deleted User %d (%s)", id, name or ""), nil)
  markPendingSent("clear:" .. slot, sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(slot)))
  notify("USER_DELETED", { USER_ID = id, USER_NAME = name })
end

function RFP.SET_AUTO_LOCK_SECONDS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_AUTO_LOCK_SECONDS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  takeSetting("attr:autolock", tointeger(Select(tParams, "SECONDS")))
end

function RFP.SET_ADMIN_CODE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_ADMIN_CODE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local code = tostring(Select(tParams, "PASSCODE") or "")
  local shown = { NAME = "admin_code", VALUE = REDACTED }
  if code == state.adminCode then
    notifySecret("SETTING_CHANGED", { NAME = "admin_code", VALUE = code }, shown)
    return
  end
  state.adminCode = code
  -- The admin code is a secret; it only ever persists encrypted.
  persist:set("adminCode", state.adminCode, true)
  notifySecret("SETTING_CHANGED", { NAME = "admin_code", VALUE = state.adminCode }, shown)
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
  local volume = tostring(Select(tParams, "VOLUME"))
  takeSetting("attr:volume", VOLUME_TO_ZCL[volume] and volume or nil)
end

function RFP.SET_ONE_TOUCH_LOCKING(idBinding, strCommand, tParams)
  log:trace("RFP.SET_ONE_TOUCH_LOCKING(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local enabled = Select(tParams, "ENABLED")
  if enabled ~= nil then
    enabled = toboolean(enabled)
  end
  takeSetting("attr:onetouch", enabled)
end

function RFP.SET_WRONG_CODE_ATTEMPTS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_WRONG_CODE_ATTEMPTS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  takeSetting("attr:wrongcode", tointeger(Select(tParams, "COUNT")))
end

function RFP.SET_SHUTOUT_TIMER(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SHUTOUT_TIMER(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  takeSetting("attr:shutout", tointeger(Select(tParams, "SECONDS")))
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

function EC.Sync_Users(tParams)
  log:trace("EC.Sync_Users(%s)", tParams)
  -- Re-send every user's full intent - PIN and schedule - so a replay
  -- reconverges the lock. Clear each occupied slot first: the lock's
  -- duplicate-PIN check would otherwise reject re-writing a PIN that is
  -- already present.
  for id, u in pairs(state.users) do
    registerPending("pin:" .. id, "pin", id, nil, nil)
    registerPending("sched:" .. id, "sched", id, nil, nil)
    if u.active and u.code then
      sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(u.slot))
    end
    writeUserPin(id, u.active and u.code or nil)
    writeUserSchedule(id, u)
  end
  -- A deleted user's clear the lock did not take is owed again.
  for key, e in pairs(state.uncleared) do
    registerPending(key, "clear", e.id, e.msg, nil)
    markPendingSent(key, sendCommand(CLUSTER_DOORLOCK, DL_CLEAR_PIN, u16le(e.id)))
  end
  state.uncleared = {}
  persist:set("unclearedSlots", state.uncleared)
  notifyUsers()
end

function EC.Get_Battery_Status(tParams)
  log:trace("EC.Get_Battery_Status(%s)", tParams)
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
  -- Learn the lock's application endpoint. Any cluster's traffic is a
  -- bootstrap guess, but only the DoorLock cluster's own endpoint is
  -- authoritative - and it persists, because a reload otherwise resets to
  -- endpoint 1 and the init-probe reads go unanswered until the lock happens
  -- to speak first.
  if srcEndpoint then
    if clusterId == CLUSTER_DOORLOCK then
      if srcEndpoint ~= state.dstEndpoint or not state.dstEndpointLearned then
        state.dstEndpoint = srcEndpoint
        state.dstEndpointLearned = true
        persist:set("dstEndpoint", srcEndpoint)
      end
    elseif not state.dstEndpointLearned then
      state.dstEndpoint = srcEndpoint
    end
  end
  -- Any packet from the lock proves it is reachable. Recover Online here in case
  -- a driver reload missed the one-shot OnZigbeeOnlineStatusChanged callback.
  if not state.online then
    applyOnline(true)
  end
  -- With the endpoint known, hand zserver the event bind (a repeat costs nothing);
  -- the lock is awake, so the binder asks what an earlier read left open.
  establishEventBinds()
  if binder then
    binder:wake()
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
      -- Model/manufacturer are handled by Director's interview; we only want the
      -- firmware build. The online callback's version arg comes through empty on
      -- this hardware, so read SWBuildID directly.
      if not clusterSpecific and (cmd == ZCL_REPORT_ATTR or cmd == ZCL_READ_ATTR_RSP) then
        local swBuild = decodeStringAttr(payload, cmd, ATTR_SW_BUILD)
        if not IsEmpty(swBuild) then
          UpdateProperty("Firmware Version", swBuild)
          noteFirmware(swBuild)
        end
      end
    elseif clusterId == CLUSTER_DOORLOCK then
      if not clusterSpecific and (cmd == ZCL_REPORT_ATTR or cmd == ZCL_READ_ATTR_RSP) then
        local attrs = decodeAttributes(payload, cmd)
        if attrs[ATTR_LOCK_STATE] and attrs[ATTR_LOCK_STATE].value ~= nil then
          local ls = zclLockStatus(attrs[ATTR_LOCK_STATE].value)
          -- A verify poll can land while the bolt is still moving, which reads
          -- as "not fully locked". Within the post-command window, give that
          -- one silent re-check instead of surfacing a transient Jam.
          if
            ls == STATUS_FAULT
            and state.lockStatus ~= STATUS_FAULT
            and os.time() - (state.cmdSentAt or 0) <= 6
            and not state.faultRecheck
          then
            state.faultRecheck = true
            pollLockState()
          else
            state.faultRecheck = false
            -- Bare LOCK_STATE report: no actor in the packet. applyLockStatus
            -- infers it (our recent command vs a physical operation) and keeps
            -- the prior description on an unchanged read.
            applyLockStatus(ls)
          end
        end
        -- Capability limits reported by the lock; use them for validation.
        if attrs[ATTR_NUM_PIN_USERS] and attrs[ATTR_NUM_PIN_USERS].value then
          state.limits.maxUsers = attrs[ATTR_NUM_PIN_USERS].value
          probeUserIds(state.limits.maxUsers)
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
        -- Event-log support: gates GetLogRecord-based actor attribution. A lock
        -- reporting 0 (or lacking the attribute) has no log, so operations stay
        -- attributed by origin only.
        if attrs[ATTR_NUM_LOG_RECORDS] and attrs[ATTR_NUM_LOG_RECORDS].value ~= nil then
          state.logSupported = attrs[ATTR_NUM_LOG_RECORDS].value > 0
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
        -- OperationEventNotification: source(u8) code(u8) userId(u16) pin(octstr)
        -- localTime(u32) data(octstr). The bound lock pushes one for each operation;
        -- the PIN is skipped, never read.
        local src = payload:byte(1)
        local code = payload:byte(2)
        local uid = (#payload >= 4) and (payload:byte(3) + payload:byte(4) * 256) or 0xFFFF
        local at = payload:byte(5) and u32At(payload, 6 + payload:byte(5))
        -- Its time pairs it only when the lock's clock agrees with the controller's;
        -- one with none (or a clock that is off) is taken as just done.
        local now = lockNow()
        local timed = at ~= nil and at >= now - MATCH_LATE_SECS and at <= now + MATCH_EARLY_SECS
        local ls = DOORLOCK_EVENT[code]
        if ls then
          attributeOperation(zclLockStatus(ls), code, src, uid, timed and at or now, true, timed)
        end
      elseif clusterSpecific and cmd == DL_GET_LOG_RECORD and #payload >= 11 then
        -- GetLogRecordResponse: logEntryId(u16) timestamp(u32) eventType(u8)
        -- source(u8) eventCode(u8) userId(u16) pin(octstr). The trailing PIN is
        -- cleartext and is deliberately never read. Only operation records
        -- (eventType 0) attribute a lock action, by their time on the lock's clock.
        local eventType = payload:byte(7)
        local src = payload:byte(8)
        local code = payload:byte(9)
        local uid = payload:byte(10) + payload:byte(11) * 256
        local ls = DOORLOCK_EVENT[code]
        if eventType == 0 and ls then
          attributeOperation(zclLockStatus(ls), code, src, uid, u32At(payload, 3), false, true)
        end
      elseif clusterSpecific and cmd == DL_GET_PIN then
        -- The lock understood GetPINCode, so it has a keypad. Restore user
        -- management in case this driver was moved onto a keypad lock.
        setUserCodeSupport(true)
        if #payload >= 2 then
          noteUserIdAnswer(payload:byte(1) + payload:byte(2) * 256, true)
        end
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
        elseif respCmd == DL_GET_PIN then
          -- An id outside the lock's range is refused with an error (0x85 on a 916).
          if status ~= 0 and idProbe then
            noteUserIdAnswer(idProbe.seqs[seq], false)
          end
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

-- ---------------------------------------------------------------------------
-- Real-time event bindings (Zigbee 3.0)
-- ---------------------------------------------------------------------------

-- A lock joins with no DoorLock bind, so it answers polls but never pushes a
-- keypad or thumbturn event. zbind has zserver keep the DoorLock bind through the
-- controller's Zigbee API; the status poll stays the fallback.
local eventBound = false

--- Make the binder, at late init: Director keeps the lock's bind list across a
--- driver update only, so any other load starts it stale.
--- @param driverInitType string|nil
local function makeBinder(driverInitType)
  binder = ZBind:new(driverInitType ~= "DIT_UPDATING")
  binder.address = function()
    return C4:FindEuidBasedOnNodeId(C4:GetDeviceID())
  end
  binder.zserverId = function()
    return C4:FindZserverIDBasedOnNodeId(C4:GetDeviceID())
  end
end

--- Give zserver the lock's bind list: DoorLock on its application endpoint, bound
--- to the coordinator so keypad and thumbturn actions arrive in real time, then
--- Poll Control. Waits for the endpoint, since an entry on one the lock lacks
--- disables the list.
function establishEventBinds()
  if not binder or not state.dstEndpointLearned then
    return
  end
  -- PowerConfig is not listed: the lock refuses its bind, so battery stays on the hourly poll.
  binder:apply({
    { srcEp = state.dstEndpoint, cluster = CLUSTER_DOORLOCK },
    -- zserver unbinds what the list leaves out, so the check-in bind the lock joined with
    -- (to the coordinator's ep1) is listed too: last, so a refusal of it comes after DoorLock is bound.
    { srcEp = state.dstEndpoint, cluster = CLUSTER_POLL_CONTROL, dstEp = 1 },
  }, function(settled)
    if settled and not eventBound then
      log:info("Real-time event binding in place (endpoint %d)", state.dstEndpoint)
    end
    eventBound = settled
  end)
end

function OnZigbeeOnlineStatusChanged(strStatus, strVersion, _strSKU)
  log:trace("OnZigbeeOnlineStatusChanged('%s', '%s')", strStatus, strVersion)
  local online = strStatus ~= "OFFLINE"
  -- zserver does not sync a rejoined lock again, so one that lost its table is found here.
  local rejoined = strStatus == "REBOOT" or (online and state.online == false)
  applyOnline(online)
  if rejoined and binder then
    binder:check()
  end
  if online then
    if not IsEmpty(strVersion) then
      UpdateProperty("Firmware Version", strVersion)
    end
    -- Seed and resolve the capability verdicts. The reads a fresh, sleepy lock
    -- can miss are retried on a bounded timer until they answer, so the
    -- restrictive defaults become the lock's real capability set.
    startCapProbe()
    readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
    -- Firmware build from the device itself; the callback's version arg is empty.
    readAttributes(CLUSTER_BASIC, { ATTR_SW_BUILD })
    -- A list refused before Director added the lock goes now; on a first join the
    -- endpoint comes from the reads above, at packet-in.
    establishEventBinds()
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

function OnDriverLateInit(driverInitType)
  log:trace("OnDriverLateInit(%s)", tostring(driverInitType))
  if not CheckMinimumVersion("Driver Status") then
    return
  end
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
  -- Assert both capability verdicts from persistence on every init, mirroring the
  -- REQUEST_CAPABILITIES handler. The proxy persists capability values and a
  -- driver update resets them toward the restrictive driver.xml defaults, so a
  -- keypad lock (supportsUserCodes true, only ever set by a definitive keypad
  -- verdict) must re-assert here or user management stays hidden until something
  -- happens to re-request. A keypadless or not-yet-probed lock asserts the
  -- restricted set, which is correct.
  applyUserCodeCapabilities()
  applySettingCapabilities()
  -- A persisted endpoint gives zserver the event bind now, or after one table read
  -- when it is the lock's first list; Director skips an unchanged one.
  makeBinder(driverInitType)
  establishEventBinds()
  -- Writes owed from before the reload: re-arm the retry window but don't blast
  -- the sleeping lock now - its next inbound packet flushes them.
  armPendingTimer()
  -- A driver reload may not re-fire OnZigbeeOnlineStatusChanged for a lock that
  -- is already joined and online, which would leave the driver stuck Offline.
  -- Probe after init through the same bounded retry, so a reload mid-commission
  -- (before the endpoint is persisted) still resolves the capability verdicts
  -- once the lock's next packet teaches the endpoint; a response also recovers
  -- Online and seeds lock state.
  SetTimer("InitProbe", 3 * ONE_SECOND, function()
    startCapProbe()
    readAttributes(CLUSTER_POWER, { ATTR_BATT_PCT })
    readAttributes(CLUSTER_BASIC, { ATTR_SW_BUILD })
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
  if binder then
    binder:close()
  end
end
