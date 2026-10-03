# TorchLock

A lock screen flashlight button for **jailbroken iOS 6**, written to replace
[FlashLock](docs/FLASHLOCK.md), which lags on iOS 6.

Tap the bolt above the slide-to-unlock bar and the torch comes on immediately,
then stays on when the screen goes to sleep. With FlashLock on the same phone
you got one blink, a frozen lock screen that then went dark, and the light a
few seconds later.

Built and tested on an **iPhone 4 (iPhone3,2), iOS 6.1.3**.

## What it does

- **A button on the lock screen**, always visible, just above the left end of
  the unlock slider. It shows a dark circle when the torch is off, and a white
  circle with a yellow bolt when it is on.
- **Drives the torch directly.** It sets `torchMode` on the camera device, so
  no `AVCaptureSession` runs, nothing blocks SpringBoard's main thread and the
  camera doesn't stream frames while the light is on.
- **Doesn't let the screen dim right after a tap.** A tap counts as activity,
  so the lock screen dim timer restarts.
- **Turns the torch off when you unlock.** To keep it on, set
  `TurnOffOnUnlock` to `false` in
  `/var/mobile/Library/Preferences/com.aurelio.torchlock.plist`.
- **Adds an Activator action.** "Toggle Flashlight" (`com.aurelio.torchlock.toggle`)
  appears under *TorchLock* in Activator, so you can give it a gesture for use
  while unlocked.

## Requirements

On the phone:

- jailbroken iOS 6 with MobileSubstrate
- OpenSSH, to install from a PC
- Activator, optional, for the gesture action and for `make smoke`

On the PC:

- Linux on x86_64
- `git`, `curl`, `make`, `perl`
- libimobiledevice, for `iproxy` (USB to SSH)

## Quick start

```sh
make setup   # Theos + Linux iOS toolchain + iOS 10.3 SDK into ~/theos (skips what exists)
make build   # release .deb into tweak/packages/
make run     # build, install on the USB-connected iPhone, respring
make smoke   # torch on for ~3 seconds, then off
```

`make` on its own lists every target. `run`, `dev`, `smoke` and `uninstall` start
`iproxy` on `PORT` (default 2222) and SSH to the phone as root, which asks for
the root password.

TorchLock declares `Conflicts: com.filippobiga.flashlock`. Remove FlashLock
before installing, because two buttons fighting over one torch don't work.

## Development

| Target | What it does |
| --- | --- |
| `make dev` | Debug build, install, respring. Adds a second Activator listener, `com.aurelio.torchlock.debug`, which writes the torch state and the lock screen view tree to `/tmp/torchlock-debug.txt` and a screenshot to `/tmp/torchlock-screen.png` on the phone |
| `make check` | Clean compile with `-Werror` |
| `make verify` | `check`, then a release package |
| `make deploy DEB=<path>` | Install any package on the phone |
| `make uninstall` | Remove TorchLock from the phone and respring |

There are no unit tests, because the tweak only runs inside SpringBoard.
Testing it means running it on a device: `make smoke`, or in a debug build,
`activator send com.aurelio.torchlock.debug` followed by reading `/tmp/torchlock-debug.txt`.

[`docs/BUILDING.md`](docs/BUILDING.md) explains the toolchain choices (why the
10.3 SDK, why `-Wl,-U,_memset`, why gzip packages).

## Verified

All on the iPhone 4 / iOS 6.1.3 above:

- SpringBoard loads it with no crash and no safe mode, for both debug and
  release builds.
- Toggling through Activator switches the torch at once. `torchMode` and
  `isTorchActive` still matched after 6, 8 and 30 seconds.
- The backlight turned off (kernel log) eight seconds after the torch came on,
  and the torch stayed lit until it was toggled off 30 seconds later.
- The button is drawn above the left end of the unlock slider. This was
  checked with the debug build's screenshot.

Not yet checked by a test: the unlock-turns-it-off path, which hooks
`-[SBAwayController didFinishAnimatingOut]`.

## Layout

```
Makefile          standard verbs; wraps the Theos project
tweak/
  Makefile        Theos project (target, arch, flags)
  Tweak.x         the tweak (Logos)
  TorchLock.plist Substrate filter: SpringBoard only
  control         Debian package metadata
docs/
  BUILDING.md     toolchain notes
  FLASHLOCK.md    why FlashLock misbehaves on iOS 6
```
