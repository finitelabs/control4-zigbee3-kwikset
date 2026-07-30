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

### Added

- Initial release: Zigbee 3.0 Kwikset SmartCode lock driver speaking ZCL
  DoorLock directly to the lock - no hub, bridge, or cloud required
- Standard Control4 lock control (lock, unlock, toggle) from Navigators,
  Composer, and programming, with manual, keypad, one-touch, and auto-lock
  operations reflected back within the state-poll interval (the platform offers
  no event push on Zigbee 3.0 joins - see docs/zigbee3-event-push.md)
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
- User PINs and the admin code persist encrypted
