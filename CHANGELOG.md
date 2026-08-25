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

### Changed

- Real-time event binding is now verified against the lock's own binding table
  and re-established if missing, instead of silently falling back to the status
  poll

## v20260823 - 2026-08-23

### Added

- A Zigbee 3.0 Kwikset SmartCode lock driver that speaks ZCL DoorLock directly
  to the lock - no hub, bridge, or cloud required
- Standard Control4 lock control (lock, unlock, toggle) from Navigators,
  Composer, and programming
- Real-time state and per-user attribution: the driver binds the lock to the
  controller's Zigbee coordinator so operations report the moment they happen,
  and reads the lock's event log to name who acted - a keypad user (by name),
  manual thumbturn, one-touch, auto-relock, or Control4
- User code management with per-user daily and date-range schedules, validated
  against the limits the lock itself reports and enforced by the lock's own
  firmware
- Keypad settings written to the lock and confirmed by it: auto-lock time,
  keypad volume, one-touch locking, wrong-code attempts, and shutout timer
  (adopted from the lock on first join)
- Owed-write tracking for this sleepy battery device: changes stay "Applying
  lock changes..." until the lock confirms them, retry on a bounded window,
  survive driver reloads, and fail loudly instead of silently
- Runtime keypad detection: keypadless models (SmartCode Convert) automatically
  drop user-code management and restore it when moved to a keypad lock
- Lock history, battery reporting with a low-battery event, and Locked /
  Unlocked / Jammed / Battery Low programming events
- Encrypted persistence for user PINs and the admin code
