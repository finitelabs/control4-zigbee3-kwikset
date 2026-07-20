[copyright]: # "Copyright 2026 Finite Labs, LLC. All rights reserved."

# <span style="color:#0057B8">Kwikset SmartCode (Zigbee 3)</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4,
> Kwikset, or the Zigbee Alliance.

<!-- #endif -->

# <span style="color:#0057B8">Overview</span>

A standalone Control4 driver for **Zigbee 3.0 Kwikset SmartCode** deadbolts and
levers. It presents a full Control4 lock (lock, unlock, toggle, user codes,
auto-lock, battery, history) and speaks standard ZCL DoorLock to the lock, so it
works with any Kwikset Zigbee 3.0 SmartCode joined to the controller's Zigbee
3.0 network.

# <span style="color:#0057B8">Installer Setup</span>

1. Add the **Kwikset SmartCode (Zigbee 3)** driver to your project.
2. Put the lock into Zigbee pairing mode (see the lock's manual) and join it to
   the controller's Zigbee 3.0 network.
3. Once it reports in, the lock resolves and its status, battery, and user codes
   are managed from the standard Control4 lock interface.

# <span style="color:#0057B8">Programming</span>

## Events

| Event       | Description                               |
| ----------- | ----------------------------------------- |
| Locked      | Fires when the lock is locked             |
| Unlocked    | Fires when the lock is unlocked           |
| Jammed      | Fires when the lock fails to lock/unlock  |
| Battery Low | Fires when the lock reports a low battery |

# <span style="color:#0057B8">Support</span>

If you have any questions, supported-device requests, or issues to report, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-zigbee3-kwikset/issues/new
