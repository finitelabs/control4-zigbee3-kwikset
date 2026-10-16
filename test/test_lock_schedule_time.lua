-- The times kwikset_zigbee3_lock sends in a date-range (year-day) schedule. ZCL
-- LocalTime is seconds since 2000-01-01 on the local wall clock, and that is the clock
-- Front Porch's Kwikset 916 keeps: its event at 12:50:38 CDT on 2026-10-16 carried
-- 845470238, the Unix time less 946684800 and 18000 (2026-10-16). The driver sent
-- os.time of the local date less 946684800, the UTC instant, which on a controller in
-- Central time lands the window 5 hours late in summer and 6 in winter.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_schedule_time.lua

local T = require("testlib")
local F = require("lock_fixtures")

-- The controller's clock in US Central time, as Front Porch's is, for the dates this
-- suite schedules: os.time reads a date as local time, so 12:50 CDT is 17:50 UTC.
local CENTRAL = {
  ["2026-10-16 12:50"] = 1792173000, -- CDT, UTC-5
  ["2026-12-25 08:00"] = 1798207200, -- CST, UTC-6
}
local realTime = os.time
os.time = function(t) -- luacheck: ignore
  if type(t) == "table" then
    local at = CENTRAL[string.format("%04d-%02d-%02d %02d:%02d", t.year, t.month, t.day, t.hour or 12, t.min or 0)]
    if at then
      return at
    end
  end
  return realTime(t)
end

--- The start and end a year-day schedule frame carries.
local function window(f)
  local p = f.payload
  local function u32(at)
    return p:byte(at) + p:byte(at + 1) * 256 + p:byte(at + 2) * 65536 + p:byte(at + 3) * 16777216
  end
  return { u32(4), u32(8) }
end

--------------------------------------------------------------------------------
T.section("a date range goes to the lock as its own wall-clock time")
--------------------------------------------------------------------------------
do
  local seed = { users = { [1] = { name = "Derek", code = "1234", active = true, slot = 1 } } }
  for k, v in pairs(F.KEYPAD) do
    seed[k] = v
  end
  F.start(seed)
  F.sent()
  F.proxy("EDIT_USER", {
    USER_ID = "1",
    USER_NAME = "Derek",
    PASSCODE = "1234",
    IS_ACTIVE = "true",
    IS_RESTRICTED_SCHEDULE = "true",
    SCHEDULE_TYPE = "date_range",
    START_YEAR = "2026",
    START_MONTH = "10",
    START_DAY = "16",
    START_TIME = tostring(12 * 60 + 50),
    END_YEAR = "2026",
    END_MONTH = "12",
    END_DAY = "25",
    END_TIME = tostring(8 * 60),
  })
  local sets = F.only(F.sent(), F.SET_YEARDAY)
  T.eq("one year-day schedule is sent, for user 1", #sets == 1 and F.userId(sets[1]), 1)
  local got = sets[1] and window(sets[1]) or {}
  T.eq("12:50 on 2026-10-16 (CDT) starts at the lock's own 12:50", got[1], 845470200)
  T.eq("08:00 on 2026-12-25 (CST) ends at the lock's own 08:00", got[2], 851500800)
end

T.finish()
