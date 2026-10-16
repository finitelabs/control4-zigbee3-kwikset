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

T.finish()
