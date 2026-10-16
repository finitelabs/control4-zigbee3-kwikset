-- Which of the lock's user ids kwikset_zigbee3_lock writes a user to. ZCL numbers a
-- lock's N PIN users 0 to N-1 or 1 to N. Front Porch's Kwikset 916 (N = 30) answered
-- Get PIN for user 0 and refused users 30 and 31 with INVALID_FIELD (2026-10-16), so
-- its ids are 0 to 29; the driver wrote users to 1 to 30, never to 0, and its 30th
-- user to an id the lock refuses. Get PIN for ids 0 and N now settles the range, and
-- a stored user keeps the slot it was written to.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lock_user_ids.lua

local T = require("testlib")
local F = require("lock_fixtures")

local INVALID_FIELD = 0x85

--- A store holding the keypad lock and `users`.
local function store(users)
  local seed = {}
  for k, v in pairs(F.KEYPAD) do
    seed[k] = v
  end
  seed.users = users
  return seed
end

-- Front Porch's one user, written by an earlier build to user 1.
local FRONT_PORCH = { [1] = { name = "Derek", code = "1234", active = true, slot = 1 } }

--- Users 1 to n at the slots `first` on.
local function filled(n, first)
  local users = {}
  for i = 1, n do
    users[i] = { name = "User " .. i, code = string.format("%04d", 1000 + i), active = true, slot = first + i - 1 }
  end
  return users
end

--- The driver online over `users`; the lock answers NumberOfPINUsersSupported 30.
--- @return table seqs The sequence of each Get PIN the answer drew, by the id it names.
local function online(users)
  F.start(store(users))
  OnZigbeeOnlineStatusChanged("ONLINE", "", "")
  F.sent()
  F.readResponse({ F.attr(0x0012, 0x21, 30) })
  local seqs = {}
  for _, f in ipairs(F.only(F.sent(), F.GET_PIN)) do
    seqs[F.userId(f)] = f.seq
  end
  return seqs
end

--- The lock's answers to Get PIN for ids 0 and 30: true answers, false refuses.
local function answer(seqs, zero, top)
  for id, answered in pairs({ [0] = zero, [30] = top }) do
    local seq = seqs[id] or 0xEE -- never asked: an answer to nothing
    if answered then
      F.getPinResponse(seq, id, 0)
    else
      F.defaultResponse(seq, F.GET_PIN, INVALID_FIELD)
    end
  end
end

--- The user ids the `cmd` commands among `frames` name.
local function named(frames, cmd)
  local ids = {}
  for _, f in ipairs(F.only(frames, cmd)) do
    ids[#ids + 1] = F.userId(f)
  end
  return ids
end

--- Whether a Read Attributes among `frames` asks for `attr`.
local function reads(frames, attr)
  for _, f in ipairs(F.only(frames, 0x00, false)) do
    for at = 1, #f.payload - 1, 2 do
      if f.payload:byte(at) + f.payload:byte(at + 1) * 256 == attr then
        return true
      end
    end
  end
  return false
end

--- Add a user as the proxy does, and return the ids its PIN went to.
local function add(code)
  F.sent()
  F.proxy("ADD_USER", { USER_NAME = "Guest", PASSCODE = code, IS_ACTIVE = "true" })
  local ids = {}
  for _, f in ipairs(F.only(F.sent(), F.SET_PIN)) do
    ids[#ids + 1] = F.userId(f)
  end
  return ids
end

--------------------------------------------------------------------------------
T.section("a 916's answers: user 0 answered, user 30 refused, so its ids are 0 to 29")
--------------------------------------------------------------------------------
do
  local seqs = online(FRONT_PORCH)
  T.check("the lock's N draws Get PIN for ids 0 and 30", seqs[0] ~= nil and seqs[30] ~= nil, T.show(seqs))
  F.told()
  answer(seqs, true, false)
  local told = F.told()
  T.eq("the proxy is told 30 users", F.capability(told, "max_users"), "30")
  T.eq("and the ids are stored", F.stored("userIds"), { first = 0, last = 29 })

  T.eq("a new user goes to id 0", add("5678"), { 0 })
  local added = F.last(F.told(), "USER_ADDED")
  T.eq("as Control4's user 2", added and added.USER_ID, 2)
  local users = F.stored("users")
  T.eq("stored at slot 0", users[2] and users[2].slot, 0)
  T.eq("Front Porch's user 1 keeps slot 1", users[1] and users[1].slot, 1)

  F.proxy("EDIT_USER", { USER_ID = "1", USER_NAME = "Derek", PASSCODE = "4321", IS_ACTIVE = "true" })
  local sets = F.only(F.sent(), F.SET_PIN)
  T.eq("user 1's new code goes to id 1", #sets == 1 and F.userId(sets[1]), 1)

  -- Keypad unlock by the lock's user 0: source Keypad, code Unlock.
  F.told()
  F.receive(F.DOORLOCK, true, 0x31, F.OPER_EVENT, string.char(0x00, 0x02) .. F.u16(0) .. string.rep("\0", 9))
  local n = F.last(F.told(), "LOCK_STATUS_CHANGED")
  T.eq("an operation by the lock's user 0 names the user at slot 0", n and n.SOURCE, "Guest")
end

--------------------------------------------------------------------------------
T.section("a full 916 holds 30 users, at ids 0 to 29")
--------------------------------------------------------------------------------
do
  answer(online(filled(29, 1)), true, false)
  T.eq("the 30th user goes to id 0", add("5678"), { 0 })
  F.told()
  T.eq("a 31st is refused", add("8765"), {})
  local n = F.last(F.told(), "LOCK_STATUS_CHANGED")
  T.eq("with the lock's count", n and n.LAST_ACTION_DESCRIPTION, "Cannot add user: lock supports 30 codes")
end

--------------------------------------------------------------------------------
T.section("a lock numbering from 1: user 0 refused, user N answered, so its ids are 1 to N")
--------------------------------------------------------------------------------
do
  local seqs = online(filled(29, 1))
  F.told()
  answer(seqs, false, true)
  T.eq("the proxy is told 30 users", F.capability(F.told(), "max_users"), "30")
  T.eq("the 30th user goes to id 30", add("5678"), { 30 })
end

--------------------------------------------------------------------------------
T.section("answers that settle nothing keep ids 1 to N-1, which both numberings allow")
--------------------------------------------------------------------------------
do
  local seqs = online(filled(28, 1))
  T.eq("until the lock answers, the proxy is told 29 users", F.capability(F.told(), "max_users"), "29")
  answer(seqs, true, true)
  T.eq("both answered: nothing new is told", F.capability(F.told(), "max_users"), nil)
  T.eq("nothing is stored", F.stored("userIds"), nil)
  T.eq("the 29th user goes to id 29", add("5678"), { 29 })
  T.eq("and a 30th is refused, not sent to 0 or 30", add("8765"), {})

  answer(online(FRONT_PORCH), false, false)
  T.eq("both refused: a new user goes to id 2", add("5678"), { 2 })

  online(FRONT_PORCH)
  T.eq("no answers yet: a new user goes to id 2", add("5678"), { 2 })
end

--------------------------------------------------------------------------------
T.section("the settled ids hold across a reload")
--------------------------------------------------------------------------------
do
  answer(online(FRONT_PORCH), true, false)
  F.reload()
  T.eq("init tells the proxy 30 users", F.capability(F.told(), "max_users"), "30")
  T.eq("and a new user goes to id 0 before the lock answers again", add("5678"), { 0 })
end

--------------------------------------------------------------------------------
T.section("a deleted user's id is not reused while its clear is owed")
--------------------------------------------------------------------------------
do
  answer(online(FRONT_PORCH), true, false)
  F.sent()
  F.proxy("DELETE_USER", { USER_ID = "1" })
  local clears = F.only(F.sent(), F.CLEAR_PIN)
  T.eq("the delete clears id 1", #clears == 1 and F.userId(clears[1]), 1)
  T.eq("a new user goes to id 0", add("5678"), { 0 })
  T.eq("the next to id 2, while id 1's clear is owed", add("8765"), { 2 })
  F.receive(F.DOORLOCK, true, clears[1].seq, F.CLEAR_PIN, string.char(0))
  T.eq("once the lock confirms it, id 1 is free", add("1357"), { 1 })
end

--------------------------------------------------------------------------------
T.section("a deleted user's id stays taken when the lock refuses its clear")
--------------------------------------------------------------------------------
do
  answer(online(FRONT_PORCH), true, false)
  F.sent()
  F.proxy("DELETE_USER", { USER_ID = "1" })
  local clears = F.only(F.sent(), F.CLEAR_PIN)
  F.told()
  F.receive(F.DOORLOCK, true, clears[1] and clears[1].seq or 0xEE, F.CLEAR_PIN, string.char(1))
  local n = F.last(F.told(), "LOCK_STATUS_CHANGED")
  T.eq(
    "the refusal is shown",
    n and n.LAST_ACTION_DESCRIPTION,
    "Deleted User 1 (Derek) - rejected by lock (status 0x01)"
  )
  F.reload()
  T.eq("a new user goes to id 0", add("5678"), { 0 })
  T.eq("the next to id 2, while the old code may still open the door", add("8765"), { 2 })

  F.sent()
  EC.Sync_Users({})
  local sync = F.sent()
  local again
  for _, f in ipairs(F.only(sync, F.CLEAR_PIN)) do
    if F.userId(f) == 1 then
      again = f
    end
  end
  T.check("Sync Users clears id 1 again", again ~= nil, T.show(named(sync, F.CLEAR_PIN)))
  F.receive(F.DOORLOCK, true, again and again.seq or 0xEE, F.CLEAR_PIN, string.char(0))
  T.eq("once the lock confirms it, id 1 is free", add("1357"), { 1 })
end

--------------------------------------------------------------------------------
T.section("a deleted user's id stays taken when the lock never confirms its clear")
--------------------------------------------------------------------------------
do
  answer(online(FRONT_PORCH), true, false)
  F.proxy("DELETE_USER", { USER_ID = "1" })
  F.told()
  for _ = 1, 11 do
    if Timer.PendingWrites then
      F.tick("PendingWrites")
    end
  end
  local n = F.last(F.told(), "LOCK_STATUS_CHANGED")
  T.eq("the delete fails", n and n.LAST_ACTION_DESCRIPTION, "Deleted User 1 (Derek) - not confirmed by lock")
  T.eq("a new user goes to id 0", add("5678"), { 0 })
  T.eq("the next to id 2", add("8765"), { 2 })
end

--------------------------------------------------------------------------------
T.section("only a keypad or RFID operation names a user, whatever id the lock reports")
--------------------------------------------------------------------------------
do
  local seed = store({ [2] = { name = "Guest", code = "5678", active = true, slot = 0 } })
  seed.userIds = { first = 0, last = 29 }
  F.start(seed)
  --- The lock reports an operation by `src` with event `code` and user `uid` (0 if nil).
  local function operation(src, code, uid)
    F.told()
    F.receive(F.DOORLOCK, true, 0x31, F.OPER_EVENT, string.char(src, code) .. F.u16(uid or 0) .. string.rep("\0", 9))
    local n = F.last(F.told(), "LOCK_STATUS_CHANGED")
    return n and { n.SOURCE, n.LAST_ACTION_DESCRIPTION }
  end

  F.proxy("LOCK")
  T.eq("Control4's own lock reads Control4", operation(0x01, 0x01), { "Control4", "Locked (Control4)" })
  T.eq("a thumbturn unlock reads Manual", operation(0x02, 0x0e), { "Manual", "Unlocked (Manual)" })
  T.eq("a keypad lock names the user at slot 0", operation(0x00, 0x01), { "Guest", "Locked by Guest (Keypad)" })
  T.eq("an RFID unlock does too", operation(0x03, 0x02), { "Guest", "Unlocked by Guest (RFID)" })
  T.eq(
    "a keypad lock by an id no user holds reads its number",
    operation(0x00, 0x01, 5),
    { "User 5", "Locked by User 5 (Keypad)" }
  )
end

--------------------------------------------------------------------------------
T.section("a probe answer the lock missed is asked for again")
--------------------------------------------------------------------------------
do
  -- Front Porch's verdicts from an earlier online, so only the user ids are open.
  local function resolved(users)
    local seed = store(users)
    seed.settingSupport = {
      ["attr:autolock"] = true,
      ["attr:volume"] = true,
      ["attr:onetouch"] = false,
      ["attr:wrongcode"] = true,
      ["attr:shutout"] = true,
    }
    F.start(seed)
    OnZigbeeOnlineStatusChanged("ONLINE", "", "")
    F.sent()
    F.readResponse({ F.attr(0x0012, 0x21, 30) })
    local seqs = {}
    for _, f in ipairs(F.only(F.sent(), F.GET_PIN)) do
      seqs[F.userId(f)] = f.seq
    end
    return seqs
  end

  local seqs = resolved(FRONT_PORCH)
  F.getPinResponse(seqs[0] or 0xEE, 0, 0)
  T.check("with id 30's answer lost, the probe goes on", Timer.CapProbe ~= nil)
  if Timer.CapProbe then
    F.fire("CapProbe")
  end
  local reread = reads(F.sent(), 0x0012)
  T.check("its next round reads N again", reread)
  if reread then
    F.readResponse({ F.attr(0x0012, 0x21, 30) })
  end
  local asked = F.only(F.sent(), F.GET_PIN)
  T.eq("and asks for id 30 alone", named(asked, F.GET_PIN), { 30 })
  F.told()
  F.defaultResponse(asked[1] and asked[1].seq or 0xEE, F.GET_PIN, INVALID_FIELD)
  T.eq("the range settles", F.stored("userIds"), { first = 0, last = 29 })
  T.eq("and the proxy is told 30 users", F.capability(F.told(), "max_users"), "30")

  answer(resolved(FRONT_PORCH), true, false)
  T.eq("both answered at once, the probe stops", Timer.CapProbe, nil)
end

T.finish()
