-- Regression test for src/zigbee/zbind.lua: the bind bootstrap's read-back
-- verify and its broker-close handling in drain().
--
-- Run from the driver root:
--   make test
-- or:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_zbind.lua
--
-- After sending the binds the flow reads the device binding table back
-- (Mgmt_Bind_rsp) and re-issues any target cluster that is not present, then
-- settles. Two properties have to hold across every variant of that:
--   1. Verify converges: all targets present -> finish(true) with the coordinator
--      cache kept; a missing cluster is re-fired and re-checked after a settle;
--      and the retry is bounded so a cluster that never lands still settles.
--   2. The final read can carry a broker close in the same recv(), so a
--      completing frame must be parsed before the flow settles, and an
--      incomplete one must settle (not strand the callback): a wrong settle
--      either leaves every later ensureBinds short-circuiting on the idle guard
--      or forces a needless full re-discovery.
--   3. Verify confirms the exact bind requested - (srcEp, cluster) to the
--      coordinator at the probed gateway endpoint - so a same-cluster bind on
--      another endpoint, or one to another node, does not read as landed.
--
-- Cases:
--   1. table shows every target bound      -> finish(true), cache kept
--   2. table missing one cluster, present  -> re-fire, finish(true)
--      on the re-read after the settle
--   3. a cluster never appears             -> bounded retries, still finish(true)
--   4. completing table with the close     -> parse then finish(true), cache kept
--   5. close carries a truncated table     -> finish(false), cache dropped
--   6. close carries no bytes              -> drain does not settle; the step
--      timeout rescues as finish(false)
--   7. same cluster on a different source endpoint  -> re-fire, not confirm
--   8. bind at a different gateway endpoint          -> re-fire, not confirm
--   9. record omits the endpoint field              -> still confirm
--  10. bind to a different destination node          -> re-fire, not confirm

local T = require("testlib")

require("c4_shim")

-- Not provided by the shim; the flow reads both during connect()/ensureBinds().
function C4:GetUniqueMAC()
  return "0022A30012ABCDEF"
end
function C4:GetTime()
  return 1700000000000
end

-- Inject a fake unix socket before requiring the module, so connect() binds to a
-- scripted receive() instead of a real broker. `currentFake` is swapped per case.
local currentFake
package.loaded["socket.unix"] = {
  stream = function()
    return currentFake
  end,
}

local ZBind = require("zigbee.zbind")

-- Swap persistence for an in-memory store so the cache-kept / cache-dropped
-- contract can be asserted directly, independent of the real serializer.
local persist = require("lib.persist")
local store = {}
local function setStore(t)
  for k in pairs(store) do
    store[k] = nil
  end
  for k, v in pairs(t or {}) do
    store[k] = v
  end
end
function persist.get(_, key, default)
  local v = store[key]
  if v == nil then
    return default
  end
  return v
end
function persist.set(_, key, value)
  store[key] = value
end
function persist.delete(_, key)
  store[key] = nil
end

-- The flow logs on nearly every step; silence it so results are readable.
local logging = require("lib.logging")
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  if type(logging[m]) == "function" then
    logging[m] = function() end
  end
end

-- Minimal wire encoders, only enough to hand-build the frames the flow reads.
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
local function pbVarint(n)
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
local function pbVI(field, v)
  return pbVarint(field * 8 + 0) .. pbVarint(v)
end
local function pbLD(field, data)
  return pbVarint(field * 8 + 2) .. pbVarint(#data) .. data
end
-- An EUI64 as a fixed64 in 8 little-endian bytes, matching the module's encoder
-- so its hexLE() decodes the field back to the same address.
local function pbF64(field, hex)
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
  return pbVarint(field * 8 + 1) .. table.concat(o)
end

local CONNACK = string.char(0x20, 0x02, 0x00, 0x00)

local function publish(topic, payload)
  local body = mqStr(topic) .. payload
  return string.char(0x30) .. mqLen(#body) .. body
end

-- Handlers match only the topic suffix, so literal MAC/EUI segments are fine.
local BASE = "s1/c4/protected/zigbee3-public-api/v1/MAC/device/EUI"
-- exec-status/send-zdo carrying EXEC_OK (0): any{ 2: msg{ 2: 0 } }.
local EXEC_OK_PUBLISH = publish(BASE .. "/exec-status/send-zdo", pbLD(2, pbVI(2, 0)))

-- A PUBLISH header claiming 127 more bytes than are present: parse() cannot
-- complete a packet, so it consumes nothing and the flow stays mid-step.
local TRUNCATED = string.char(0x30, 0x7F) .. string.char(0, 0, 0)

local EUI = "00124B0001AABBCC"
local COORD = "00124B0001CE4B21"
local GW_EP = 2
local CL_DOORLOCK = 0x0101
local CL_POWER = 0x0001
local CLUSTERS = { { cluster = CL_DOORLOCK, srcEp = 1 }, { cluster = CL_POWER, srcEp = 1 } }

-- One binding-table record (repeated field 5): { 2=srcEp, 3=cluster, 5=dstEui,
-- 6=dstEp }. dstEp defaults to the probed gateway endpoint; pass false to omit
-- field 6 entirely, modelling a firmware that does not enumerate it.
local function bindRecord(srcEp, cluster, dstHex, dstEp)
  local rec = pbVI(2, srcEp) .. pbVI(3, cluster) .. pbF64(5, dstHex)
  if dstEp ~= false then
    rec = rec .. pbVI(6, dstEp or GW_EP)
  end
  return pbLD(5, rec)
end
-- Wrap a binding table as the incoming-zdo PUBLISH the verify step reads. The
-- ZDO response buffer the flow parses sits at command-frame field 8, nested as
-- any{2} -> msg{8} -> frame{3} -> cf{8}.
local function incomingZdo(tableBuf)
  return publish(BASE .. "/event/incoming-zdo", pbLD(2, pbLD(8, pbLD(3, pbLD(8, tableBuf)))))
end
local TABLE_BOTH = incomingZdo(bindRecord(1, CL_DOORLOCK, COORD) .. bindRecord(1, CL_POWER, COORD))
local TABLE_DOORLOCK_ONLY = incomingZdo(bindRecord(1, CL_DOORLOCK, COORD))
-- Both target clusters are bound to the coordinator, but on a different source
-- endpoint (99) than the targets ask for (1): must not count as our bind.
local TABLE_WRONG_EP = incomingZdo(bindRecord(99, CL_DOORLOCK, COORD) .. bindRecord(99, CL_POWER, COORD))
-- Both target clusters bound to the coordinator, but at a different gateway
-- (destination) endpoint than the flow probed: also must not count as our bind.
local TABLE_WRONG_DSTEP =
  incomingZdo(bindRecord(1, CL_DOORLOCK, COORD, GW_EP + 1) .. bindRecord(1, CL_POWER, COORD, GW_EP + 1))
-- Both target clusters bound to the coordinator with no destination-endpoint
-- field at all (a firmware that does not enumerate it): must still confirm.
local TABLE_NO_DSTEP = incomingZdo(bindRecord(1, CL_DOORLOCK, COORD, false) .. bindRecord(1, CL_POWER, COORD, false))
-- A destination EUI that is not the coordinator, derived from COORD so it cannot
-- collide with it. Both clusters bound on the right source endpoint but to this
-- other node: must not count as our bind.
local OTHER_EUI = (COORD:gsub("%x%x$", "99"))
local TABLE_WRONG_DST = incomingZdo(bindRecord(1, CL_DOORLOCK, OTHER_EUI) .. bindRecord(1, CL_POWER, OTHER_EUI))

-- Scripted socket. receive() replays {data, err, partial} triples in order; once
-- the script is exhausted it reports a would-block so drain()'s loop breaks.
local function fakeSocket(script)
  return {
    _i = 0,
    _script = script,
    sent = {},
    connect = function()
      return 1
    end,
    settimeout = function() end,
    send = function(self, pkt)
      self.sent[#self.sent + 1] = pkt
      return #pkt
    end,
    close = function(self)
      self.closed = true
    end,
    receive = function(self)
      self._i = self._i + 1
      local step = self._script[self._i]
      if not step then
        return nil, "timeout", ""
      end
      return step[1], step[2], step[3]
    end,
  }
end

local function publishCount(sock)
  local n = 0
  for _, pkt in ipairs(sock.sent) do
    if #pkt > 0 and string.byte(pkt, 1) == 0x30 then
      n = n + 1
    end
  end
  return n
end

-- Drive a fresh flow to the point where the binds are sent and the verify read
-- is armed, awaiting the binding table. The cached coordinator/endpoint let it
-- skip discovery and go straight to the probe. The recurring drain timer is
-- cancelled so ShimFireTimers only advances the settle/step timers and the test
-- feeds socket data through explicit drain() calls.
local function runToVerify(script)
  currentFake = fakeSocket(script)
  setStore({ zbindCoordEui = COORD, zbindGwEp = GW_EP })
  local rec = { count = 0, ok = nil }
  local zb = ZBind:new()
  zb:ensureBinds(EUI, CLUSTERS, function(ok)
    rec.count = rec.count + 1
    rec.ok = ok
  end)
  zb:drain() -- CONNACK -> onConnack -> beginProbe (probe bind sent)
  zb:drain() -- EXEC_OK -> beginBindRest -> verifyRead (Mgmt_Bind read sent)
  CancelTimer("ZBindDrain")
  return zb, rec
end

--------------------------------------------------------------------------------
T.section("binding table shows every target bound -> finish(true)")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_BOTH, nil, nil },
    { nil, "timeout", "" },
  })
  T.check("flow awaits the binding table after the probe accept", zb.state == "verify", zb.state)
  T.check("flow has not settled before the table read", rec.count == 0, rec.count)

  -- Clear the cache first, so a passing assertion proves finish(true) re-wrote it.
  store.zbindCoordEui, store.zbindGwEp = nil, nil
  zb:drain() -- reads TABLE_BOTH -> verify handler -> finish(true)

  T.check("callback fired exactly once", rec.count == 1, rec.count)
  T.check("flow settled successfully", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
  T.check("coordinator cache saved", store.zbindCoordEui == COORD, tostring(store.zbindCoordEui))
  T.check("gateway endpoint cache saved", store.zbindGwEp == GW_EP, tostring(store.zbindGwEp))
end

--------------------------------------------------------------------------------
T.section("table missing a cluster -> re-fire, confirm on re-read")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_DOORLOCK_ONLY, nil, nil }, -- verify read 1: power bind absent
    { nil, "timeout", "" },
    { TABLE_BOTH, nil, nil }, -- verify read 2 (after settle): both present
    { nil, "timeout", "" },
  })
  local before = publishCount(currentFake)
  zb:drain() -- TABLE_DOORLOCK_ONLY -> re-fire power + arm the settle timer

  T.check("did not settle on the incomplete table", rec.count == 0, rec.count)
  T.check("re-fired the missing bind", publishCount(currentFake) > before, publishCount(currentFake))

  ShimFireTimers() -- settle -> verifyRead again (sends a fresh Mgmt_Bind read)
  zb:drain() -- TABLE_BOTH -> finish(true)

  T.check("callback fired exactly once", rec.count == 1, rec.count)
  T.check("flow settled successfully once verified", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
  T.check("coordinator cache saved", store.zbindCoordEui == COORD, tostring(store.zbindCoordEui))
end

--------------------------------------------------------------------------------
T.section("a cluster never appears -> bounded retries, still finish(true)")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_DOORLOCK_ONLY, nil, nil }, -- read 1
    { nil, "timeout", "" },
    { TABLE_DOORLOCK_ONLY, nil, nil }, -- read 2
    { nil, "timeout", "" },
    { TABLE_DOORLOCK_ONLY, nil, nil }, -- read 3 (retry cap)
    { nil, "timeout", "" },
    { TABLE_DOORLOCK_ONLY, nil, nil }, -- would be read 4 if it looped
    { nil, "timeout", "" },
  })
  zb:drain() -- read 1 -> missing, re-fire, settle
  T.check("does not settle on read 1", rec.count == 0, rec.count)
  ShimFireTimers()
  zb:drain() -- read 2 -> missing, re-fire, settle
  T.check("does not settle on read 2", rec.count == 0, rec.count)
  ShimFireTimers()
  zb:drain() -- read 3 -> retry cap reached -> finish(true)

  T.check("settles after the bounded retries", rec.count == 1, rec.count)
  T.check("settles successfully (accepted binds kept)", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
  T.check("coordinator cache saved", store.zbindCoordEui == COORD, tostring(store.zbindCoordEui))
end

--------------------------------------------------------------------------------
T.section("completing table arrives in the same read as the close")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_BOTH, "closed", nil }, -- the confirming table, plus the close
    { nil, "timeout", "" },
  })
  store.zbindCoordEui, store.zbindGwEp = nil, nil
  zb:drain() -- close branch parses the table before settling -> finish(true)

  T.check("callback fired exactly once", rec.count == 1, rec.count)
  T.check("flow settled successfully", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
  T.check("coordinator cache survives", store.zbindCoordEui == COORD, tostring(store.zbindCoordEui))
  T.check("gateway endpoint cache survives", store.zbindGwEp == GW_EP, tostring(store.zbindGwEp))
  T.check("socket was closed on settle", currentFake.closed == true)
end

--------------------------------------------------------------------------------
T.section("close carries a truncated table (no completion possible)")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TRUNCATED, "closed", nil },
    { nil, "timeout", "" },
  })
  zb:drain()

  T.check("callback fired exactly once", rec.count == 1, rec.count)
  T.check("flow settled as a failure", rec.ok == false, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
  T.check("coordinator cache dropped", store.zbindCoordEui == nil, tostring(store.zbindCoordEui))
  T.check("gateway endpoint cache dropped", store.zbindGwEp == nil, tostring(store.zbindGwEp))
end

--------------------------------------------------------------------------------
T.section("close carries no bytes: drain does not settle, step timeout rescues")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { nil, "closed", "" }, -- empty-chunk break fires before the closed check
    { nil, "timeout", "" },
  })
  zb:drain()

  T.check("byte-less close does not settle in drain", rec.count == 0, rec.count)
  T.check("flow is still mid-verify after the empty close", zb.state == "verify", zb.state)
  T.check("socket left open for the step timer", currentFake.closed ~= true)

  ShimFireTimers() -- the step timeout is the only thing that settles this case

  T.check("step timeout settles the flow", rec.count == 1, rec.count)
  T.check("timed-out flow settles as a failure", rec.ok == false, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
  T.check("coordinator cache dropped", store.zbindCoordEui == nil, tostring(store.zbindCoordEui))
end

--------------------------------------------------------------------------------
T.section("a same-cluster bind on a different endpoint is not our target")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_WRONG_EP, nil, nil }, -- clusters bound, but on srcEp 99 not the target's 1
    { nil, "timeout", "" },
    { TABLE_BOTH, nil, nil }, -- the correct-endpoint table on the re-read
    { nil, "timeout", "" },
  })
  local before = publishCount(currentFake)
  zb:drain() -- wrong-endpoint records must not satisfy the (srcEp, cluster) targets

  T.check("does not settle on a wrong-endpoint match", rec.count == 0, rec.count)
  T.check("re-fires the target binds", publishCount(currentFake) > before, publishCount(currentFake))

  ShimFireTimers()
  zb:drain() -- the exact triple is now present

  T.check("settles once the exact triple is present", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
end

--------------------------------------------------------------------------------
T.section("a bind at a different gateway endpoint is not our target")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_WRONG_DSTEP, nil, nil }, -- bound to coord, but at gwEp+1 not the probed gwEp
    { nil, "timeout", "" },
    { TABLE_BOTH, nil, nil }, -- the correct gateway endpoint on the re-read
    { nil, "timeout", "" },
  })
  local before = publishCount(currentFake)
  zb:drain() -- a record naming a different gateway endpoint must not confirm our bind

  T.check("does not settle on a wrong-gateway-endpoint match", rec.count == 0, rec.count)
  T.check("re-fires the target binds", publishCount(currentFake) > before, publishCount(currentFake))

  ShimFireTimers()
  zb:drain() -- the exact triple is now present

  T.check("settles once the exact triple is present", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
end

--------------------------------------------------------------------------------
T.section("records that omit the endpoint field still confirm the target")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_NO_DSTEP, nil, nil }, -- records carry no field 6; tolerated
    { nil, "timeout", "" },
  })
  local before = publishCount(currentFake)
  zb:drain() -- (srcEp, cluster, coordinator) present, endpoint field absent -> confirmed

  T.check("settles on (srcEp, cluster, coordinator) alone", rec.ok == true, tostring(rec.ok))
  T.check("does not re-fire the already-present binds", publishCount(currentFake) == before, publishCount(currentFake))
  T.check("callback fired exactly once", rec.count == 1, rec.count)
  T.check("state returns to idle", zb.state == "idle", zb.state)
end

--------------------------------------------------------------------------------
T.section("a bind to a different destination node is not our target")
--------------------------------------------------------------------------------
do
  local zb, rec = runToVerify({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { EXEC_OK_PUBLISH, nil, nil },
    { nil, "timeout", "" },
    { TABLE_WRONG_DST, nil, nil }, -- right (srcEp, cluster), wrong destination node
    { nil, "timeout", "" },
    { TABLE_BOTH, nil, nil }, -- the coordinator destination on the re-read
    { nil, "timeout", "" },
  })
  local before = publishCount(currentFake)
  zb:drain() -- a record naming another destination must not confirm our bind

  T.check("does not settle on a non-coordinator destination", rec.count == 0, rec.count)
  T.check("re-fires the target binds", publishCount(currentFake) > before, publishCount(currentFake))

  ShimFireTimers()
  zb:drain() -- the coordinator destination is now present

  T.check("settles once the coordinator bind is present", rec.ok == true, tostring(rec.ok))
  T.check("state returns to idle", zb.state == "idle", zb.state)
end

T.finish()
