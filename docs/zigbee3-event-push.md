<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

# Zigbee 3.0 real-time events: investigation and status

**Status: tabled (2026-07-30).** Revisit when Control4 ships the official
Zigbee 3.0 driver API - coordinator-side binding/reporting configuration may
arrive with it. Interim mitigation: a 30-second LockState poll (below).

## Problem

Physical lock operations (keypad, thumbturn, one-touch, auto-lock) generate no
Zigbee traffic on a Zigbee 3.0 join, so the driver can only learn about them by
polling. ZCL delivers both Operation Event Notifications and attribute reports
exclusively to destinations in the device's ZDO binding table - and nothing on
this platform can create that binding entry.

## What was verified on hardware

All findings from 2026-07-30, live against a SmartCode with the BDL-C4-RF
module (Zigbee 3.0 join, dev controller OS 3.x):

1. **Event masks are not the problem.** Keypad/RF/Manual/Programming event
   masks (attrs 0x41-0x45) all read `0xFFFF` (fully enabled), yet no Operation
   Event Notification ever arrives.
2. **Reporting is accepted but undeliverable.** Configure Reporting for
   LockState returned SUCCESS, but with a 60s max interval no report arrived
   in a 75s window - the lock has no binding-table entry pointing at the
   coordinator, so its reporting engine has nowhere to send.
3. **Drivers cannot send ZDO.** A `Mgmt_Bind_req` (profile 0x0000) fails
   instantly at send time (`OnZigbeePacketFailed`); a `Bind_req` (0x0021)
   fails identically. This is why the one third-party driver with ZDO bind
   code (Somfy Glydea) ships with the call commented out.
4. **ZDO is not forwarded inbound either.** A power cycle produced only the
   Kwikset announce (cluster 0xFC57) and Diagnostics frames - no profile-0
   traffic reaches `OnZigbeePacketIn`.
5. **No API or schema escape hatch.** `C4:GetZigbeeEUID()` returns `-`; there
   is no coordinator-EUID getter; neither driver.xml nor the public
   docs-zigbee documentation offers bind/report configuration that Director
   would execute at join time.
6. **The native driver's channel does not exist on the Z3 join.** Kwikset's
   BD protocol (cluster 0xBD) - which carries the native driver's unsolicited
   pushes `0xFD` Door Alarm, `0xFE` Lock Status Changed, `0xFF` User Code
   Added - answers `UNSUP_CLUSTER_COMMAND` on the Zigbee 3.0 join. The module
   is dual-personality: embedded-profile join speaks BD and pushes; Z3 join
   speaks standard ZCL and pushes nothing.

## How every real-time Control4 Zigbee driver actually works

Device-initiated push - never coordinator-created binds:

- Native Kwikset/Yale/Schlage lock drivers: manufacturer protocols (BD et al.)
  on the embedded join; the firmware unicasts events to the coordinator on its
  own initiative.
- Control4's own Zigbee 3.0-era hardware (Z2IO, Lux): Control4 manufacturer
  clusters; same philosophy.
- Third-party sensors: IAS Zone enrollment (the driver writes the CIE address;
  the device then pushes) or firmware that binds itself to the coordinator
  during commissioning.

The Kwikset Z3 firmware does none of these.

## Options considered

| # | Option | Verdict |
| - | ------ | ------- |
| A | Re-join embedded + implement the BD transport (full command map recovered from the native driver source; real-time with source attribution) | Viable, moderate rewrite; loses the standard-ZCL story |
| B | Dual dialect: BD when the module answers it, ZCL+poll otherwise | A, plus future-proofing; most work |
| C | Stay Z3 with a modest LockState poll | Shipped as the interim; ~30s latency, no source attribution for physical ops |
| D | Wait for the official Control4 Zigbee 3.0 API | **Chosen** - binding/reporting config plausibly arrives with it |

## Interim mitigation (shipped)

`startStatePolling()`: LockState every 30s + battery hourly while online,
stopped while offline. All downstream notifies are change-gated, so polls are
silent unless something actually moved. The module answers its parent every few
seconds regardless, so the battery cost is negligible. This is a deliberate,
documented deviation from the event-driven polling convention - the hardware
offers no events to be driven by.

## Revisit triggers

- Control4 announces/releases the official Zigbee 3.0 driver API - check for
  binding or reporting configuration.
- A Director/zserver update changes the ZDO policy for driver-originated
  packets.
- Kwikset Z3 firmware that auto-binds DoorLock during commissioning.

## Bench re-test recipe (minutes, via c4 MCP eval on the driver)

```lua
-- 1. Can drivers send ZDO yet? (expect: OnZigbeePacketFailed today)
C4:SendZigbeePacket(string.char(0x91, 0x00), 0x0000, 0x0033, 0, 0, 0)

-- 2. Do reports deliver yet? (configure LockState min=0 max=60; expect a
--    report within 60s if a binding path exists)
C4:SendZigbeePacket(string.char(0x00, 0x90, 0x06, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x3c, 0x00), 0x0104, 0x0101, 0, 1, 2)

-- 3. Is BD alive on this join? (expect UNSUP 0x81 today; a real reply means
--    the module is on the embedded join / dual personality changed)
C4:SendZigbeePacket(string.char(0x01, 0xa0, 0x11), 0x0104, 0x00BD, 0, 2, 2)
```
