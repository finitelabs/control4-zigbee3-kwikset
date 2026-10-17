# <span style="color:#D12231">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Fixed

- Fixed one-touch locking that had been turned off showing as on after a driver
  update or controller reboot, where a change the lock had not yet confirmed
  could be sent to it as on; the setting now loads as it was saved
- Fixed user codes on a lock that numbers its users from 0, such as the
  SmartCode 10 Touchscreen: the driver now learns the lock's user numbers from
  the lock, so every one of its codes can be used and none is sent to a number
  the lock refuses
- Fixed a lock or unlock from Control4 or the thumbturn being credited to a user
  when the lock reports a user number with it: only a keypad or RFID operation
  now names a user
- Fixed a deleted user's number on the lock going to a new user before the lock
  confirmed the delete, while the old code could still open the door: the number
  stays taken until the lock confirms it, and Sync Users sends a delete the lock
  did not take again
- Fixed date-range user schedules starting and ending hours late by the
  controller's offset from UTC (5 hours in US Central summer time): the dates
  and times now go to the lock in its own local time
- Fixed lock settings the lock does not have, such as one-touch locking on the
  SmartCode 10 Touchscreen, being shown as on and sent to the lock: only the
  settings the lock reports are offered, and a value it refuses now reads "Not
  supported by this device" and is not sent again (keypad volume low used to be
  turned into high)
- Fixed user codes and the admin code showing in plain text in the driver's log
  at the Trace and Ultra log levels; the log now shows `***REDACTED***` in their
  place
- Fixed the lock's history in the Control4 app ending at the driver's last load,
  however many operations the driver had recorded since: each entry is now sent
  as it is recorded
- Fixed a keypad user's name landing on an earlier thumbturn lock or unlock in
  the lock's history when the lock's reports arrived late or out of order: each
  report now names the operation it describes by the time on the lock's own
  clock
- Fixed the lock's last action changing to Control4 within 30 seconds of a
  keypad or thumbturn operation: a status read that finds the lock as it was no
  longer reports anything
- Fixed the Locked, Unlocked, Jammed, and Battery Low events never firing, so
  programming on them now runs

### Changed

- Changed the lock's real-time binding to go through the controller's Zigbee
  API, so keypad, thumbturn, and one-touch operations show as they happen
- Changed the auto-lock, wrong code attempts, and shutout timer lists to follow
  the lock: a value it refuses is dropped, and one set at the lock is added
- Changed the lock status read every 30 seconds to stop once the lock sends a
  real-time update after the driver loads; after that the status is read hourly
  with the battery, so the lock is no longer woken every 30 seconds

## v20260825 - 2026-08-25

### Changed

- Improved real-time event binding reliability: the driver now confirms each
  binding landed in the lock's own table and re-establishes it if missing,
  instead of silently falling back to the status poll

## v20260823 - 2026-08-23

### Added

- Added a Zigbee 3.0 Kwikset SmartCode lock driver that speaks ZCL DoorLock
  directly to the lock - no hub, bridge, or cloud required
- Added standard Control4 lock control (lock, unlock, toggle) from Navigators,
  Composer, and programming
- Added real-time state and per-user attribution: the driver binds the lock to
  the controller's Zigbee coordinator so operations report the moment they
  happen, and reads the lock's event log to name who acted - a keypad user (by
  name), manual thumbturn, one-touch, auto-relock, or Control4
- Added user code management with per-user daily and date-range schedules,
  validated against the limits the lock itself reports and enforced by the
  lock's own firmware
- Added keypad settings written to the lock and confirmed by it: auto-lock time,
  keypad volume, one-touch locking, wrong-code attempts, and shutout timer
  (adopted from the lock on first join)
- Added owed-write tracking for this sleepy battery device: changes stay
  "Applying lock changes..." until the lock confirms them, retry on a bounded
  window, survive driver reloads, and fail loudly instead of silently
- Added runtime keypad detection: keypadless models (SmartCode Convert)
  automatically drop user-code management and restore it when moved to a keypad
  lock
- Added lock history, battery reporting with a low-battery event, and Locked /
  Unlocked / Jammed / Battery Low programming events
- Added encrypted persistence for user PINs and the admin code
