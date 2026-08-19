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
