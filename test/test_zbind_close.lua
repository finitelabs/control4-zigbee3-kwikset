-- Regression test for src/zigbee/zbind.lua broker-close handling in drain().
--
-- Run from the driver root:
--   make test
-- or:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_zbind_close.lua
--
-- A single socket read can return bytes AND signal a close at once. The bind flow
-- must settle correctly in every variant of that, because the close path also
-- decides whether the cached coordinator is kept or dropped, and a wrong settle
-- either strands the flow (callback never fires, every later run short-circuits on
-- the idle guard) or forces a needless full re-discovery. Both bugs this covers
-- were originally found by throwaway probes with no committed test behind them.
--
-- Cases:
--   A. completing frame arrives in the SAME read as the close -> parse it, reach
--      finish(true), cached coordinator/endpoint survive.
--   B. close carries a truncated (incomplete) frame -> settle finish(false),
--      cached coordinator/endpoint dropped.
--   C. close carries no bytes -> the err=="closed" branch is unreachable (the
--      empty-chunk break fires first), so drain does not settle; the step timeout
--      is what rescues it.
--   D. same race as A but the peer's close makes later writes fail -> the flow
--      still settles finish(true) and persists the cache, characterizing the
--      accepted best-effort trade (the remaining CLUSTER_POWER bind is dropped).

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

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
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

local CONNACK = string.char(0x20, 0x02, 0x00, 0x00)

local function publish(topic, payload)
  local body = mqStr(topic) .. payload
  return string.char(0x30) .. mqLen(#body) .. body
end

-- exec-status/send-zdo carrying EXEC_OK (0): any{ 2: msg{ 2: 0 } }.
local EXEC_TOPIC = "s1/c4/protected/zigbee3-public-api/v1/MAC/device/EUI/exec-status/send-zdo"
local EXEC_OK_PUBLISH = publish(EXEC_TOPIC, pbLD(2, pbVI(2, 0)))

-- A PUBLISH header claiming 127 more bytes than are present: parse() cannot
-- complete a packet, so it consumes nothing and the flow stays mid-step.
local TRUNCATED = string.char(0x30, 0x7F) .. string.char(0, 0, 0)

-- Scripted socket. receive() replays {data, err, partial} triples in order; once
-- the script is exhausted it reports a would-block so drain()'s loop breaks.
local function fakeSocket(script, failSendAfterClose)
  return {
    _i = 0,
    _script = script,
    _peerClosed = false,
    dropped = 0,
    sent = {},
    connect = function()
      return 1
    end,
    settimeout = function() end,
    send = function(self, pkt)
      -- A real unix socket rejects a write once the peer has closed, and rawSend
      -- pcalls the send and discards the result, so the flow never sees it. The
      -- default fake accepts every write; the failing variant models the reject.
      if failSendAfterClose and self._peerClosed then
        self.dropped = self.dropped + 1
        return nil, "closed"
      end
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
      if step[2] == "closed" then
        self._peerClosed = true
      end
      return step[1], step[2], step[3]
    end,
  }
end

local EUI = "00124B0001AABBCC"
local COORD = "00124B0001CE4B21"
local GW_EP = 2
local CLUSTERS = { { cluster = 0x0101, srcEp = 1 }, { cluster = 0x0001, srcEp = 1 } }

-- Drive a fresh flow up to the point where the probe step is armed and awaiting
-- the exec-status response, i.e. one drain() that reads the CONNACK. Returns the
-- ZBind and a cb recorder; the fake socket is reachable as `currentFake`.
local function runToProbe(script, failSendAfterClose)
  currentFake = fakeSocket(script, failSendAfterClose)
  setStore({ zbindCoordEui = COORD, zbindGwEp = GW_EP })
  local rec = { count = 0, ok = nil }
  local zb = ZBind:new()
  zb:ensureBinds(EUI, CLUSTERS, function(ok)
    rec.count = rec.count + 1
    rec.ok = ok
  end)
  zb:drain() -- reads CONNACK -> onConnack -> beginProbe (cached endpoint)
  return zb, rec
end

--------------------------------------------------------------------------------
print("\n[A] completing frame arrives in the SAME read as the close")
--------------------------------------------------------------------------------
do
  local zb, rec = runToProbe({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { nil, "closed", EXEC_OK_PUBLISH }, -- the accepting exec-status, plus close
    { nil, "timeout", "" },
  })
  check("probe step is armed after the CONNACK", zb.state == "probe", zb.state)
  check("flow has not settled before the close read", rec.count == 0, rec.count)

  -- Clear the cache first, so a passing assertion proves finish(true) re-wrote it
  -- rather than the seed merely lingering.
  store.zbindCoordEui, store.zbindGwEp = nil, nil
  zb:drain()

  check("callback fired exactly once", rec.count == 1, rec.count)
  check("flow settled successfully", rec.ok == true, tostring(rec.ok))
  check("state returns to idle", zb.state == "idle", zb.state)
  check("coordinator cache survives", store.zbindCoordEui == COORD, tostring(store.zbindCoordEui))
  check("gateway endpoint cache survives", store.zbindGwEp == GW_EP, tostring(store.zbindGwEp))
  check("socket was closed on settle", currentFake.closed == true)
end

--------------------------------------------------------------------------------
print("\n[B] close carries a truncated frame (no completion possible)")
--------------------------------------------------------------------------------
do
  local zb, rec = runToProbe({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { nil, "closed", TRUNCATED },
    { nil, "timeout", "" },
  })
  check("probe step is armed after the CONNACK", zb.state == "probe", zb.state)

  zb:drain()

  check("callback fired exactly once", rec.count == 1, rec.count)
  check("flow settled as a failure", rec.ok == false, tostring(rec.ok))
  check("state returns to idle", zb.state == "idle", zb.state)
  check("coordinator cache dropped", store.zbindCoordEui == nil, tostring(store.zbindCoordEui))
  check("gateway endpoint cache dropped", store.zbindGwEp == nil, tostring(store.zbindGwEp))
end

--------------------------------------------------------------------------------
print("\n[C] close carries no bytes: fast settle is unreachable, timeout rescues")
--------------------------------------------------------------------------------
do
  local zb, rec = runToProbe({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { nil, "closed", "" }, -- empty-chunk break fires before the closed check
    { nil, "timeout", "" },
  })
  check("probe step is armed after the CONNACK", zb.state == "probe", zb.state)

  zb:drain()

  -- The contract the byte-less case pins: drain must NOT settle here.
  check("byte-less close does not settle in drain", rec.count == 0, rec.count)
  check("flow is still mid-step after the empty close", zb.state == "probe", zb.state)
  check("socket is left open for the step timer", currentFake.closed ~= true)

  ShimFireTimers() -- the step timeout is the only thing that settles this case

  check("step timeout settles the flow", rec.count == 1, rec.count)
  check("timed-out flow settles as a failure", rec.ok == false, tostring(rec.ok))
  check("state returns to idle", zb.state == "idle", zb.state)
  check("coordinator cache dropped", store.zbindCoordEui == nil, tostring(store.zbindCoordEui))
end

--------------------------------------------------------------------------------
print("\n[D] sends fail after the peer closes: accepted best-effort trade")
--------------------------------------------------------------------------------
do
  -- Same race as A (the accepting bind arrives with the close), but now every
  -- write after that close is rejected the way a real socket rejects it. The
  -- flow reaches beginBindRest and publishes the remaining CLUSTER_POWER bind
  -- onto the dead socket; that write is dropped, yet finish(true) must still
  -- stand and the cache must still persist. This is the single behavior a
  -- send-always-succeeds fake cannot observe, so it is pinned explicitly.
  local zb, rec = runToProbe({
    { CONNACK, nil, nil },
    { nil, "timeout", "" },
    { nil, "closed", EXEC_OK_PUBLISH },
    { nil, "timeout", "" },
  }, true)
  store.zbindCoordEui, store.zbindGwEp = nil, nil
  zb:drain()

  check("settles success despite the post-close write failing", rec.ok == true, tostring(rec.ok))
  check(
    "cache persists on the accepted trade",
    store.zbindCoordEui == COORD and store.zbindGwEp == GW_EP,
    tostring(store.zbindCoordEui)
  )
  check(
    "the remaining cluster bind was attempted after close and rejected",
    currentFake.dropped == 1,
    currentFake.dropped
  )
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
