# Timeout

A small macOS menu bar app that locks your screen when a timer runs out.

## Features
- Pick 1, 5, 15 or 30 minutes and press Start.
- Locks the screen with the system lock screen when time is up.
- The lock fires even if the app is quit or force-quit (a per-user LaunchAgent runs the timer headless).
- Cancelling a running timer requires a passcode you choose on first launch.
- Menu bar countdown, a "5 minutes left" banner, a big top-right countdown in the last minute, and a sound at 10 seconds.

## Build
Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
open Timeout.app
```

## Notes
- Locking uses the private `SACLockScreenImmediate` function from `login.framework`, falling back to `pmset displaysleepnow`
  (which locks only if "Require password after screen saver or display off" is set to "Immediately").
- The app is ad-hoc signed; on first launch right-click it and choose Open.
- The passcode is stored salted and hashed in `UserDefaults`. It deters accidental cancelling; it is not a security boundary.
- Reset the passcode: `defaults delete com.timeout.app passHash; defaults delete com.timeout.app salt`.
- Cancel manually: `launchctl bootout gui/$(id -u)/com.timeout.app.lock` and delete `~/Library/LaunchAgents/com.timeout.app.lock.plist`.

## License

MIT. See [LICENSE](LICENSE).
