#!/usr/bin/env python3
"""Exercise the actual SpringBoard buttons using a DEBUG=1 device probe.

Uses existing SSH key access, or TORCHLOCK_SSH_PASSWORD via sshpass.
Changes preferences temporarily and restores them, the torch, and lock state.
An optional --install-debug package is installed and resprings the phone first.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="2222")
    parser.add_argument("--install-debug", type=Path)
    args = parser.parse_args()
    ssh = ["ssh", "-F", "/dev/null", "-p", args.port, "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "LogLevel=ERROR", "-o", "HostKeyAlgorithms=+ssh-rsa",
           "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
           "-o", "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1",
           "-o", "Ciphers=+aes128-cbc,3des-cbc", "root@localhost"]
    env = os.environ.copy()
    if env.get("TORCHLOCK_SSH_PASSWORD"):
        env["SSHPASS"] = env["TORCHLOCK_SSH_PASSWORD"]
        ssh = ["sshpass", "-e"] + ssh

    def remote(command, data=None, allow_failure=False):
        result = subprocess.run(ssh + [command], input=data, capture_output=True,
                                env=env, timeout=30)
        if result.returncode and not allow_failure:
            raise RuntimeError(f"Remote command failed ({result.returncode}): {command}\n" +
                               result.stderr.decode(errors="replace") + result.stdout.decode(errors="replace"))
        return result.stdout

    def event(listener, allow_unhandled=False):
        remote("activator send " + listener, allow_failure=allow_unhandled)
        time.sleep(0.7)

    if args.install_debug:
        remote("cat > /tmp/torchlock-device-check.deb && dpkg -i /tmp/torchlock-device-check.deb "
               "&& killall -9 SpringBoard", args.install_debug.read_bytes())
        time.sleep(5)

    listeners = remote("activator listeners").decode()
    if "com.aurelio.torchlock.test" not in listeners:
        raise RuntimeError("Install a DEBUG=1 package before running device checks")

    records = []

    def probe(action="snapshot", **values):
        nonce = str(uuid.uuid4())
        command = {"nonce": nonce, "action": action, **values}
        remote("cat > /tmp/torchlock-test-command.plist && chmod 644 /tmp/torchlock-test-command.plist "
               "&& activator send com.aurelio.torchlock.test", plistlib.dumps(command))
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            time.sleep(0.2)
            try:
                state = json.loads(remote("cat /tmp/torchlock-test.json"))
            except (RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError):
                continue
            if state["nonce"] == nonce:
                records.append({"action": action, **state})
                return state
        raise RuntimeError("Device probe timed out; inspect SpringBoard crash logs")

    def verify(condition, description):
        if not condition:
            raise AssertionError(description + "\n" + json.dumps(records[-1], indent=2))
        print("PASS: " + description, flush=True)

    def position(button, side):
        return button["present"] and button["width"] == 44 and button["height"] == 44 and (
            button["x"] == (12 if side == "left" else button["parentWidth"] - 56))

    prefs_path = "/var/mobile/Library/Preferences/com.aurelio.torchlock.plist"
    had_prefs = remote("if [ -f " + prefs_path + " ]; then echo yes; fi").strip() == b"yes"
    original_prefs = remote("cat " + prefs_path) if had_prefs else None
    original_state = probe()
    fixture_installed = False
    long_content_installed = False
    evidence = Path(tempfile.mkdtemp(prefix="torchlock-device-check-"))
    if original_prefs:
        (evidence / "original-prefs.plist").write_bytes(original_prefs)
    try:
        probe("prefs", prefs={})
        event("libactivator.lockscreen.show")
        state = probe()
        verify(state["locked"] and position(state["lockButton"], "left"), "Default lock button is on the left")
        verify(not state["notificationButton"]["present"], "Notification Center defaults off")
        if state["torchMode"]:
            probe("tap-lock")
        state = probe("tap-lock")
        verify(state["torchMode"] == 1 and state["torchActive"] and state["lockButton"]["label"] == "Flashlight on",
               "Lock button turns the actual torch on")
        state = probe("tap-lock")
        verify(state["torchMode"] == 0 and not state["torchActive"], "Lock button turns the actual torch off")

        original_camera = state["cameraGrabber"]
        original_bolt = state["lockButton"]["image"]
        verify(original_camera["present"] and any(g["class"] == "UIPanGestureRecognizer" and g["enabled"]
               for g in original_camera["gestures"]), "Native camera grabber has an enabled pan recognizer")
        state = probe("prefs", prefs={"ReplaceCameraGrabber": True, "IconStyle": "classic", "AlwaysShowButton": False})
        verify(not state["lockButton"]["present"] and state["cameraGrabber"]["image"] != original_camera["image"] and
               state["cameraGrabber"]["gestures"] == original_camera["gestures"],
               "Camera replacement removes the separate button and preserves native recognizers and delegates")
        verify(all(state["cameraGrabber"][k] == original_camera[k] for k in ("x", "y", "width", "height", "hidden")),
               "Replacement keeps native camera geometry and visibility")
        state = probe("cancel-camera-tap")
        verify(state["torchMode"] == 0 and not state["cameraActive"], "Canceled camera tap leaves the torch off")
        state = probe("tap-camera")
        lit_classic = state["cameraGrabber"]["image"]
        verify(state["torchMode"] == 1 and state["torchActive"] and not state["cameraActive"],
               "Completed camera-slot tap turns the actual torch on without opening camera")
        state = probe("tap-camera")
        verify(state["torchMode"] == 0 and state["cameraGrabber"]["image"] != lit_classic,
               "Second camera-slot tap turns the torch off and updates the icon")
        camera_icons = {state["cameraGrabber"]["image"]}
        for style in ("metal", "outline", "bulb", "bolt"):
            state = probe("prefs", prefs={"ReplaceCameraGrabber": True, "IconStyle": style})
            camera_icons.add(state["cameraGrabber"]["image"])
        verify(len(camera_icons) == 5, "Camera shortcut renders five distinct selectable icons live")
        state = probe("cancel-camera-pan")
        verify(state["torchMode"] == 0 and not state["cameraActive"], "Canceled native camera pan leaves the torch off")
        state = probe("swipe-camera")
        verify(state["cameraActive"] and state["cameraVisible"] and state["torchMode"] == 0,
               "Native upward-pan callback still opens the camera with the replacement enabled")
        event("libactivator.system.homebutton")
        state = probe()
        verify(not state["cameraActive"] and not state["cameraVisible"], "Home closes the camera through the native dismissal path")
        event("libactivator.lockscreen.show")
        state = probe()
        # iOS may recreate awayView and its recognizers when Home dismisses camera.
        current_camera_gestures = state["cameraGrabber"]["gestures"]
        verify(state["locked"] and not state["lockButton"]["present"] and
               state["cameraGrabber"]["image"] in camera_icons,
               "Camera replacement survives native lock-screen recreation")
        state = probe("prefs", prefs={"ReplaceCameraGrabber": True, "Enabled": False})
        verify(state["cameraGrabber"]["image"] == original_camera["image"] and
               state["cameraGrabber"]["gestures"] == current_camera_gestures,
               "Master disable restores the original camera image and recognizers")
        state = probe("prefs", prefs={})
        verify(state["cameraGrabber"]["image"] == original_camera["image"] and
               state["cameraGrabber"]["label"] == original_camera["label"] and state["lockButton"]["present"],
               "Disabling replacement restores the native camera and separate torch button")
        lock_icons = {original_bolt}
        for style in ("classic", "metal", "outline", "bulb"):
            state = probe("prefs", prefs={"IconStyle": style})
            lock_icons.add(state["lockButton"]["image"])
            unlit = state["lockButton"]["image"]
            state = probe("tap-lock")
            verify(state["torchMode"] == 1 and state["lockButton"]["image"] != unlit,
                   f"{style} icon distinguishes on/off and keeps the lock button working")
            probe("tap-lock")
        verify(len(lock_icons) == 5, "Separate lock button renders five distinct icon choices")
        state = probe("prefs", prefs={"IconStyle": "unknown"})
        verify(state["lockButton"]["image"] == original_bolt, "Unknown icon preference falls back to the original bolt")

        probe("prefs", prefs={"AlwaysShowButton": False})
        state = probe()
        verify(state["lockButton"]["hidden"], "Always Show Button still hides the unlit lock button")
        event("com.aurelio.torchlock.toggle")
        state = probe()
        verify(not state["lockButton"]["hidden"] and state["torchMode"] == 1, "Lit torch reveals the lock button")
        event("libactivator.lockscreen.dismiss")
        state = probe()
        verify(not state["locked"] and state["torchMode"] == 0, "Default unlock turns the torch off")

        event("libactivator.system.activate-notification-center")
        baseline = probe()
        baseline_height = baseline["headerHeight"]
        baseline_class = baseline["headerClass"]
        baseline_inset = baseline["bottomInset"]
        baseline_indicator_inset = baseline["indicatorBottomInset"]
        state = probe("prefs", prefs={"ShowInNotificationCenter": True})
        verify(position(state["notificationButton"], "left") and state["barPinned"] and
               state["barHeight"] == 64 and state["barY"] + 64 == state["grabberY"],
               "Opt-in pins the left button above the bottom grabber")
        verify(state["notificationButton"]["hitTest"], "Bottom button receives touches")
        verify(state["barBackgroundAlpha"] == 0 and state["blankTouchesPass"],
               "Bottom icon has no rectangular background and empty space passes touches through")
        verify(state["headerHeight"] == baseline_height and state["headerClass"] == baseline_class,
               "Bottom placement leaves the original header untouched")
        verify(state["bottomInset"] >= baseline_inset + 64 and state["indicatorBottomInset"] >= baseline_indicator_inset + 64,
               "Notification list reserves scroll space for the bottom bar")
        bottom_y = state["notificationButton"]["windowY"]
        probe("long-content")
        long_content_installed = True
        state = probe("scroll-bottom")
        verify(state["notificationButton"]["windowY"] == bottom_y and state["notificationButton"]["hitTest"],
               "Bottom button stays fixed and tappable after scrolling a long list")
        verify(state["contentBottomY"] <= state["barY"] + 1,
               "Final notification content scrolls clear of the bottom bar")
        probe("restore-content")
        long_content_installed = False
        state = probe("tap-notification")
        verify(state["torchMode"] == 1 and state["torchActive"] and
               state["notificationButton"]["label"] == "Flashlight on",
               "Notification Center button turns the actual torch on")
        notification_icons = set()
        for style in ("bolt", "classic", "metal", "outline", "bulb"):
            state = probe("prefs", prefs={"ShowInNotificationCenter": True, "IconStyle": style})
            notification_icons.add(state["notificationButton"]["image"])
        verify(len(notification_icons) == 5 and state["torchMode"] == 1,
               "Notification Center updates all five icons live without changing torch state")
        state = probe("prefs", prefs={"ShowInNotificationCenter": True, "ButtonPosition": "right", "TurnOffOnUnlock": False})
        verify(position(state["notificationButton"], "right"), "Right position updates Notification Center without respring")
        event("libactivator.system.homebutton")
        event("libactivator.lockscreen.show")
        state = probe()
        verify(position(state["lockButton"], "right") and state["lockButton"]["label"] == "Flashlight on",
               "Right lock button reflects the torch lit from Notification Center")
        event("libactivator.lockscreen.dismiss")
        event("libactivator.system.activate-notification-center")
        state = probe("tap-notification")
        verify(state["torchMode"] == 0 and not state["torchActive"], "Notification Center button turns torch off")
        state = probe("prefs", prefs={"ShowInNotificationCenter": True, "ButtonPosition": "left"})
        verify(position(state["notificationButton"], "left"), "Left position updates Notification Center without respring")
        event("libactivator.system.homebutton")
        event("libactivator.lockscreen.show")
        state = probe()
        verify(position(state["lockButton"], "left") and state["lockButton"]["label"] == "Flashlight off",
               "Left lock button reflects the torch turned off from Notification Center")
        event("libactivator.lockscreen.dismiss")
        event("libactivator.system.activate-notification-center")

        probe("tap-notification")
        state = probe("prefs", prefs={"ShowInNotificationCenter": False})
        verify(not state["notificationButton"]["present"] and state["headerHeight"] == baseline_height and
               state["headerClass"] == baseline_class and state["bottomInset"] == baseline_inset and
               state["indicatorBottomInset"] == baseline_indicator_inset and state["torchMode"] == 1,
               "Disabling Notification Center removes its row and keeps torch state")
        probe("prefs", prefs={"ShowInNotificationCenter": True})
        state = probe("prefs", prefs={"Enabled": False, "ShowInNotificationCenter": True})
        verify(not state["lockButton"]["present"] and not state["notificationButton"]["present"] and state["torchMode"] == 0,
               "Master disable removes both buttons and turns torch off")
        event("com.aurelio.torchlock.toggle", allow_unhandled=True)
        verify(probe()["torchMode"] == 0, "Disabled Activator action leaves the torch off")
        state = probe("prefs", prefs={"ShowInNotificationCenter": True})
        verify(state["notificationButton"]["present"], "Master re-enable restores Notification Center")
        event("libactivator.system.homebutton")
        event("libactivator.system.activate-notification-center")
        state = probe()
        verify(state["barHeight"] == 64 and state["bottomInset"] == baseline_inset + 64,
               "Reopening Notification Center does not duplicate the bar or scroll inset")

        probe("prefs", prefs={})
        probe("fixture")
        fixture_installed = True
        state = probe("prefs", prefs={"ShowInNotificationCenter": True})
        verify(state["fixtureDirect"] and state["fixtureY"] == 0 and state["headerHeight"] == 23,
               "Existing table header stays in place while the bottom button is enabled")
        state = probe("prefs", prefs={})
        verify(state["fixtureDirect"] and state["fixtureY"] == 0 and state["headerHeight"] == 23,
               "Disabling restores the original table header and frame")
        probe("restore-header")
        fixture_installed = False

        probe("prefs", prefs={"ShowInNotificationCenter": True, "TurnOffOnUnlock": False})
        event("libactivator.system.homebutton")
        event("libactivator.lockscreen.show")
        probe("tap-lock")
        event("libactivator.lockscreen.dismiss")
        verify(probe()["torchMode"] == 1, "Turn Off on Unlock off keeps the torch lit")
        event("libactivator.system.activate-notification-center")
        state = probe()
        verify(state["notificationButton"]["label"] == "Flashlight on", "Reopened Notification Center reflects the kept-on torch")
        probe("tap-notification")
    finally:
        recovery_needed = False
        try:
            if long_content_installed:
                probe("restore-content")
            if fixture_installed:
                probe("prefs", prefs={})
                probe("restore-header")
            # Enable the action briefly so the original torch state can be restored.
            state = probe("prefs", prefs={"TurnOffOnUnlock": False})
            if state["torchMode"] != original_state["torchMode"]:
                event("com.aurelio.torchlock.toggle")
            event("libactivator.system.homebutton")
            if probe()["locked"] != original_state["locked"]:
                event("libactivator.lockscreen.show" if original_state["locked"] else "libactivator.lockscreen.dismiss")
        except (RuntimeError, subprocess.SubprocessError) as error:
            recovery_needed = True
            print("Probe unavailable during cleanup: " + str(error), flush=True)
        finally:
            (evidence / "snapshots.json").write_text(json.dumps(records, indent=2) + "\n")
            print("Device evidence: " + str(evidence), flush=True)
            if had_prefs:
                remote("cat > " + prefs_path + " && chown mobile:mobile " + prefs_path, original_prefs)
            else:
                remote("rm -f " + prefs_path)
            if recovery_needed:
                remote("killall -9 SpringBoard")
                raise RuntimeError("Device check failed; preferences restored and SpringBoard restarted")
            probe("reload-prefs")
    print("DEVICE CHECKS PASSED", flush=True)


if __name__ == "__main__":
    main()
