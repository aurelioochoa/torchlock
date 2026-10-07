# Gates: Camera replacement and icon choices

Scope: Add an opt-in camera-grabber torch tap while preserving the native upward camera gesture, and four additional icon designs selectable live in Settings.

- [x] G1: The release compiles for iOS 6 armv7 with warnings treated as errors.
  CHECK: make check
  EXPECT: Signing TorchLock
  EVIDENCE: exit=0; shell=/usr/bin/bash; cwd=/home/aurelio/Repos/torchlock; EXPECT=matched; captured-output-sha256=f86bb95770f00d5a857d09b7fc047666b58489e0ef08a18d063fc666d94826c7; captured-output-bytes=6524

- [x] G2: Packaged settings include camera replacement and the original plus four new icons, with no debug probe in release.
  CHECK: python3 scripts/package-check.py
  EXPECT: RELEASE PACKAGE CHECK PASSED
  EVIDENCE: python3 scripts/package-check.py exited 0 and printed RELEASE PACKAGE CHECK PASSED for com.aurelio.torchlock_1.3.0_iphoneos-arm.deb; validated five choices, opt-in defaults, gzip archives, armv7/iOS 6.0, and debug probe exclusion with a debug-package positive control.

- [x] G3: Device checks prove camera-slot tap toggles, original pan recognizer preservation, live icon changes and restoration, plus existing lock/Notification Center behavior.
  CHECK: python3 scripts/device-check.py
  EXPECT: DEVICE CHECKS PASSED
  EVIDENCE: exit=0; shell=/usr/bin/bash; cwd=/home/aurelio/Repos/torchlock; EXPECT=matched; captured-output-sha256=11f8e37ce6ed66a8d223d62679d471b0c3aed6bb27332aff284285081f0f663e; captured-output-bytes=3191; 71 snapshots at /tmp/torchlock-device-check-kafkkr2w/snapshots.json, sha256=34c2b92ce871cf99553c34686e99d0d60c75aa88463804ad85359c57f9b29235

- [x] G4: On-device screenshots show four distinct readable icon designs and the replacement in the native camera position.
  EVIDENCE: Inspected /tmp/torchlock-icon-review/screens-review.png and docs/assets/icon-styles.png, composed from on-device screenshots and native-scale rendered artwork. Classic, Metal, Outline and Light Bulb are distinct and readable. Native camera replacement stays within the 30x52pt camera slot; the separate button is removed and the unlock slider remains clear.

- [x] G5: A swipe through the original camera gesture opens the camera and cancellation leaves the torch unchanged; Settings lists all icon choices.
  EVIDENCE: Original pan callback opened the actual camera (cameraActive/cameraVisible true); camera-open.png shows the live camera UI. Canceled native pan/tap left torchMode=0; on-device pane captured in settings.png. Packaged selector contains Original Bolt, iOS 6 Classic, Metal, Outline and Light Bulb. User confirmed that all is working correctly. Callback injection and user observation are the evidence; no automated physical-touch injection was performed.

Final audit: 5 met, 0 unmet, 0 abandoned. Initial ad-hoc trial reset preferences to defaults; this was disclosed to the user. Subsequent device checks and visual captures preserved preferences.

Installed final release 1.3.0 on the iPhone. Installation exited 0; the preference file remained byte-identical, the toggle listener is registered, and debug/test listeners are absent.
