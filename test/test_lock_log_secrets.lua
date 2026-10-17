-- What kwikset_zigbee3_lock writes to its log about lock codes. At trace the USERS
-- notify carried every user's code and SETTINGS the admin code (Front Porch,
-- 2026-10-17), and at Ultra the vendored proxy handler printed the code each
-- ADD_USER, EDIT_USER and SET_ADMIN_CODE carried. The proxy still gets every code.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_log_secrets.lua

local T = require("testlib")
local F = require("lock_fixtures")

local logging = require("lib.logging")

local USER_CODE = "24680"
local ADDED_CODE = "11357"
local EDITED_CODE = "86421"
local ADMIN_CODE = "97531"

-- The fixtures silence the log; it is read here, so it speaks again.
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  logging[m] = nil
end
-- lib.persist's trace of an encrypted value is the template's to fix; the rest is the driver's.
local logOne = logging._log
logging._log = function(self, level, text, ...)
  if type(text) == "string" and text:find("^Persist:") then
    return
  end
  return logOne(self, level, text, ...)
end

local seed = {}
for k, v in pairs(F.KEYPAD) do
  seed[k] = v
end
seed.users = { [1] = { name = "Guest", code = USER_CODE, active = true, slot = 1 } }
seed.userIds = { first = 0, last = 29 }
F.start(seed)

--- Run the proxy commands through the vendored handler at Ultra, printed and logged,
--- and return everything written.
local function logged(fn)
  logging:setLogLevel("6 - Ultra")
  logging:setLogMode("Print and Log")
  DEBUGPRINT = true
  local lines = {}
  local debugLog, errorLog = C4.DebugLog, C4.ErrorLog
  function C4:DebugLog(s)
    lines[#lines + 1] = tostring(s)
  end
  function C4:ErrorLog(s)
    lines[#lines + 1] = tostring(s)
  end
  local ok, err, printed = T.capture(fn)
  C4.DebugLog, C4.ErrorLog = debugLog, errorLog
  DEBUGPRINT = false
  logging:setLogMode("Off")
  T.check("the commands ran", ok, err)
  return printed .. "\n" .. table.concat(lines, "\n")
end

local function proxy(command, params)
  ShimPersistLand()
  ReceivedFromProxy(F.PROXY, command, params or {})
  ShimPersistLand()
end

--------------------------------------------------------------------------------
T.section("no code reaches the log")
--------------------------------------------------------------------------------
F.told()
local out = logged(function()
  proxy("REQUEST_USERS")
  proxy("SET_ADMIN_CODE", { PASSCODE = ADMIN_CODE })
  proxy("SET_ADMIN_CODE", { PASSCODE = ADMIN_CODE })
  proxy("ADD_USER", { USER_NAME = "Cleaner", PASSCODE = ADDED_CODE, IS_ACTIVE = "true" })
  proxy("EDIT_USER", { USER_ID = "1", USER_NAME = "Guest", PASSCODE = EDITED_CODE, IS_ACTIVE = "true" })
  proxy("REQUEST_USERS")
  proxy("REQUEST_SETTINGS")
end)
local told = F.told()
T.check("the log was written", #out > 200, out)
T.contains("the vendored handler printed the commands", out, "SET_ADMIN_CODE")
T.contains("the USERS notify is traced", out, "C4:SendToProxy(5001, USERS")
T.contains("with its codes redacted", out, "<passcode>***REDACTED***</passcode>")
T.contains("and so is SETTINGS", out, "<admin_code>***REDACTED***</admin_code>")
T.excludes("no line carries the stored user's code", out, USER_CODE)
T.excludes("nor an added user's", out, ADDED_CODE)
T.excludes("nor an edited user's", out, EDITED_CODE)
T.excludes("nor the admin code", out, ADMIN_CODE)

--------------------------------------------------------------------------------
T.section("the proxy is told every code")
--------------------------------------------------------------------------------
local echo = F.last(told, "SETTING_CHANGED")
T.eq("SETTING_CHANGED carries the admin code", echo and { echo.NAME, echo.VALUE }, { "admin_code", ADMIN_CODE })
local added = F.last(told, "USER_ADDED")
T.eq("USER_ADDED the added user's", added and added.PASSCODE, ADDED_CODE)
local changed = F.last(told, "USER_CHANGED")
T.eq("USER_CHANGED the edited user's", changed and changed.PASSCODE, EDITED_CODE)
local users = F.last(told, "USERS")
T.contains("USERS the edited user's", users, "<passcode>" .. EDITED_CODE .. "</passcode>")
T.contains("and the added user's", users, "<passcode>" .. ADDED_CODE .. "</passcode>")
T.contains("SETTINGS the admin code", F.last(told, "SETTINGS"), "<admin_code>" .. ADMIN_CODE .. "</admin_code>")

T.finish()
