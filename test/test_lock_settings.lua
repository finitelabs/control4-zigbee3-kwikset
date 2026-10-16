-- The lock settings kwikset_zigbee3_lock offers and writes. Front Porch's Kwikset 916
-- answered EnableOneTouchLocking (0x0029) with UNSUPPORTED_ATTRIBUTE, refused
-- SoundVolume 1 (low) with INVALID_VALUE while taking 0 and 2, and took AutoRelockTime
-- 60 (2026-10-16). The driver told the proxy one-touch locking was on when the lock
-- had not said, wrote settings the lock had not answered, folded low into high, and
-- offered a fixed auto-lock list. A setting is now offered only with a value the lock
-- gave; a value it refuses reads "Not supported by this device", is not written again
-- on that firmware, and drops out of the setting's list.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_settings.lua

local T = require("testlib")
local F = require("lock_fixtures")

local UNSUPPORTED_ATTRIBUTE = 0x86
local INVALID_VALUE = 0x87

-- The 916's answer to the settings read: locked, auto-lock off, volume high, no
-- one-touch attribute, 3 wrong codes, 60 s shutout.
local FRONT_PORCH = {
  F.attr(0x0000, 0x30, 1),
  F.attr(0x0023, 0x23, 0),
  F.attr(0x0024, 0x20, 2),
  F.attr(0x0029, nil, nil, UNSUPPORTED_ATTRIBUTE),
  F.attr(0x0030, 0x20, 3),
  F.attr(0x0031, 0x20, 60),
}

-- The driver.xml lists the proxy starts from.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local xml = io.open(root .. "/drivers/kwikset_zigbee3_lock/driver.xml"):read("*a")
local XML_VALUES = xml:match("<auto_lock_time_values>(.-)</auto_lock_time_values>")
local XML_DISPLAY = xml:match("<auto_lock_time_display_values>(.-)</auto_lock_time_display_values>")

--- The Write Attributes frames among `frames`, as { seq, attr, value }.
local function writes(frames)
  local out = {}
  for _, f in ipairs(F.only(frames, F.WRITE_ATTR, false)) do
    local p = f.payload
    local value = p:byte(4)
    if p:byte(3) == 0x23 then
      value = value + p:byte(5) * 256 + p:byte(6) * 65536 + p:byte(7) * 16777216
    end
    out[#out + 1] = { seq = f.seq, attr = p:byte(1) + p:byte(2) * 256, value = value }
  end
  return out
end

--- The attributes the read requests among `frames` ask for.
local function reads(frames)
  local out = {}
  for _, f in ipairs(F.only(frames, 0x00, false)) do
    for at = 1, #f.payload - 1, 2 do
      out[#out + 1] = f.payload:byte(at) + f.payload:byte(at + 1) * 256
    end
  end
  return out
end

--- Front Porch online, its settings read answered with `records`.
local function online(records)
  F.start(F.KEYPAD)
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  F.sent()
  F.readResponse(records)
  F.sent()
end

--- The lock answers a Write Attributes: success, or `status` for `attr`.
local function writeResponse(seq, status, attr)
  F.receive(F.DOORLOCK, false, seq, F.WRITE_RSP, status == 0 and "\0" or string.char(status) .. F.u16(attr))
end

--- A proxy SET_* command, and the writes it sent.
local function set(command, params)
  F.sent()
  F.proxy(command, params)
  return writes(F.sent())
end

--------------------------------------------------------------------------------
T.section("one-touch locking, which the 916 does not have, is not offered or written")
--------------------------------------------------------------------------------
do
  online(FRONT_PORCH)
  local told = F.told()
  T.eq("its control is hidden", F.capability(told, "has_one_touch_locking"), "false")
  T.eq("volume's is shown", F.capability(told, "has_volume"), "true")
  F.proxy("REQUEST_SETTINGS")
  local settings = F.last(F.told(), "SETTINGS")
  T.excludes("the settings do not claim it", settings, "one_touch_locking")
  T.contains("they give the lock's volume", settings, "<volume>high</volume>")
  T.contains("and its auto-lock time", settings, "<auto_lock_time>0</auto_lock_time>")
  T.eq("a change to it is not written", set("SET_ONE_TOUCH_LOCKING", { ENABLED = "true" }), {})
end

--------------------------------------------------------------------------------
T.section("a setting the lock has not answered is not offered or written")
--------------------------------------------------------------------------------
do
  F.start(F.KEYPAD)
  F.proxy("REQUEST_SETTINGS")
  local settings = F.last(F.told(), "SETTINGS")
  T.excludes("no volume is made up", settings, "<volume>")
  T.excludes("nor one-touch locking", settings, "one_touch_locking")
  T.eq("a volume change is not written", set("SET_VOLUME", { VOLUME = "silent" }), {})
end

--------------------------------------------------------------------------------
T.section("a volume the 916 refuses reads not supported and is not written again")
--------------------------------------------------------------------------------
do
  online(FRONT_PORCH)
  local sent = set("SET_VOLUME", { VOLUME = "low" })
  T.eq("low goes to the lock as 1", sent[1] and { sent[1].attr, sent[1].value }, { 0x0024, 1 })
  F.told()
  writeResponse(sent[1] and sent[1].seq or 0xEE, INVALID_VALUE, 0x0024)
  local n = F.last(F.told(), "LOCK_STATUS_CHANGED")
  T.eq(
    "the refusal reads not supported",
    n and n.LAST_ACTION_DESCRIPTION,
    "Keypad volume low - Not supported by this device"
  )
  T.eq("the lock's own volume is read back", reads(F.sent()), { 0x0024 })
  F.readResponse({ F.attr(0x0024, 0x20, 2) })
  local echo = F.last(F.told(), "SETTING_CHANGED")
  T.eq("and shown", echo and { echo.NAME, echo.VALUE }, { "volume", "high" })
  F.proxy("REQUEST_HISTORY")
  T.contains(
    "history keeps the refusal",
    F.last(F.told(), "HISTORY"),
    "Keypad volume low - Not supported by this device"
  )

  T.eq("low again is not written", set("SET_VOLUME", { VOLUME = "low" }), {})
  local told = F.told()
  n = F.last(told, "LOCK_STATUS_CHANGED")
  T.eq("and reads not supported", n and n.LAST_ACTION_DESCRIPTION, "Keypad volume low - Not supported by this device")
  echo = F.last(told, "SETTING_CHANGED")
  T.eq("the proxy is told the volume that stands", echo and echo.VALUE, "high")

  F.reload()
  F.readResponse(FRONT_PORCH)
  T.eq("after a reload low is still not written", set("SET_VOLUME", { VOLUME = "low" }), {})
  sent = set("SET_VOLUME", { VOLUME = "silent" })
  T.eq("silent is", sent[1] and { sent[1].attr, sent[1].value }, { 0x0024, 0 })
  writeResponse(sent[1] and sent[1].seq or 0xEE, 0)
  T.eq("and once the lock takes it nothing is owed", F.stored("pendingWrites"), {})
end

--------------------------------------------------------------------------------
T.section("the auto-lock list follows what the lock takes and holds")
--------------------------------------------------------------------------------
do
  online(FRONT_PORCH)
  F.proxy("REQUEST_CAPABILITIES")
  local told = F.told()
  T.eq("it starts as driver.xml's values", F.capability(told, "auto_lock_time_values"), XML_VALUES)
  T.eq("and display values", F.capability(told, "auto_lock_time_display_values"), XML_DISPLAY)

  local sent = set("SET_AUTO_LOCK_SECONDS", { SECONDS = "60" })
  T.eq("1 min goes to the lock as 60", sent[1] and { sent[1].attr, sent[1].value }, { 0x0023, 60 })
  writeResponse(sent[1] and sent[1].seq or 0xEE, 0)
  sent = set("SET_AUTO_LOCK_SECONDS", { SECONDS = "1800" })
  writeResponse(sent[1] and sent[1].seq or 0xEE, INVALID_VALUE, 0x0023)
  F.readResponse({ F.attr(0x0023, 0x23, 60) })
  told = F.told()
  T.eq(
    "a time the lock refuses leaves the list",
    F.capability(told, "auto_lock_time_values"),
    "0, 15, 30, 60, 120, 180, 300, 600, 1200"
  )
  T.eq(
    "with its display value",
    F.capability(told, "auto_lock_time_display_values"),
    "OFF,15 sec,30 sec,1 min,2 min,3 min,5 min,10 min,20 min"
  )

  F.readResponse({ F.attr(0x0023, 0x23, 45) })
  told = F.told()
  local echo = F.last(told, "SETTING_CHANGED")
  T.eq("a time set at the lock is shown", echo and { echo.NAME, echo.VALUE }, { "auto_lock_time", "45" })
  T.eq("and joins the list", F.capability(told, "auto_lock_time_values"), "0, 15, 30, 45, 60, 120, 180, 300, 600, 1200")
  T.eq(
    "with a display value",
    F.capability(told, "auto_lock_time_display_values"),
    "OFF,15 sec,30 sec,45 sec,1 min,2 min,3 min,5 min,10 min,20 min"
  )
end

--------------------------------------------------------------------------------
T.section("other firmware is offered what the last refused")
--------------------------------------------------------------------------------
do
  local function firmware(build)
    F.receive(F.BASIC, false, 0x71, F.READ_RSP, F.u16(0x4000) .. string.char(0, 0x42, #build) .. build)
  end
  online(FRONT_PORCH)
  firmware("v004.010.052")
  local sent = set("SET_VOLUME", { VOLUME = "low" })
  writeResponse(sent[1] and sent[1].seq or 0xEE, INVALID_VALUE, 0x0024)
  F.readResponse({ F.attr(0x0024, 0x20, 2) })
  firmware("v004.010.052")
  T.eq("the same firmware still refuses low", set("SET_VOLUME", { VOLUME = "low" }), {})
  firmware("v004.010.060")
  sent = set("SET_VOLUME", { VOLUME = "low" })
  T.eq("newer firmware is asked again", sent[1] and { sent[1].attr, sent[1].value }, { 0x0024, 1 })
end

T.finish()
