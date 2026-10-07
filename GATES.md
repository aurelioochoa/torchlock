# Gates: Bottom Notification Center torch

Scope: Pin the opt-in Notification Center torch icon above the bottom grabber, preserving Left/Right positioning and native shading, with no rectangular background.

- [x] G1: Code review confirms bottom anchoring, safe view lifetimes and restoration of reserved scroll space.
  EVIDENCE: Reviewed Tweak.x: bar is attached to the sliding panel above the native grabber; retained table is released on detach; reserved inset is added once per table and removed on disable or list destruction; existing headers and footers are untouched.

- [x] G2: Settings and documentation describe the bottom placement accurately.
  EVIDENCE: Reviewed PreferenceLoader footer, README and BUILDING.md: bottom placement is documented; Notification Center remains off by default and Left/Right still applies to both buttons.

- [x] G6: Screenshots show the bottom icon with native shading preserved and no background rectangle.
  EVIDENCE: Inspected /tmp/torchlock-bottom-left.png and /tmp/torchlock-bottom-right-on.png against /tmp/torchlock-bottom-baseline.png. Native linen and gradient remain continuous behind the bottom icon. Pixel comparison of the 240x100 region (200,810)-(440,910), outside either button, is identical for left, right and lit right: maximum channel difference 0.

- [x] G3: Existing Cydia index remains valid and the release compiles with warnings treated as errors.
  CHECK: make check
  EXPECT: Signing TorchLock
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/aurelio/Repos/torchlock; path=3df974dd8dfb/31 entries; EXPECT=matched; output-sha256=0c93dfc287451cbd216afee9ca39936e0041c4cba1b8ef49c5efa956efcd129a; output-bytes=10116

- [x] G4: Release package contains the bottom bar, correct preferences and no debug probe.
  CHECK: make build && python3 scripts/package-check.py
  EXPECT: RELEASE PACKAGE CHECK PASSED
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/aurelio/Repos/torchlock; path=3df974dd8dfb/31 entries; EXPECT=matched; output-sha256=a5a83e060b041525ac0d41432e4cf785c28aa5607110d308c6f58489279763a0; output-bytes=10249

- [x] G5: Device checks prove bottom positioning, hit testing, scrolling, live settings, torch toggles and untouched headers.
  CHECK: python3 scripts/device-check.py
  EXPECT: DEVICE CHECKS PASSED
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/aurelio/Repos/torchlock; path=3df974dd8dfb/31 entries; EXPECT=matched; output-sha256=8a6b7a68ea35a6ca87f6308bf10ea927522ccfdd3b3e950906f5f07b8e7e6d46; output-bytes=1789

Device evidence: /tmp/torchlock-device-check-etowtjzr/snapshots.json contains 39 snapshots; the bar has background alpha 0, passes blank-area touches, sits at Y=399 above the grabber at Y=463, and reserves 64 points for scrolling.

Installed release 1.2.1 and passed /tmp/torchlock-release-check.py: release version loaded, debug listeners absent, original preferences preserved, Activator smoke passed, original lock state restored. Gates: 6 met, 0 unmet, 0 abandoned.
