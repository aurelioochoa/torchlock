# Building on Linux

TorchLock builds with [Theos](https://theos.dev) on Linux, using
[L1ghtmann's iOS toolchain](https://github.com/L1ghtmann/llvm-project)
(clang 11.1, ld64-609) and an SDK from [theos/sdks](https://github.com/theos/sdks).
`make setup` installs all three into `THEOS` (default `~/theos`). These are the
pinned versions:

| Piece | Version |
| --- | --- |
| Toolchain | release `test-210562a`, `iOSToolchain-x86_64.tar.xz` |
| SDK | `iPhoneOS10.3.sdk` from release `master-146e41f` |
| Target | `iphone:clang:10.3:6.0`, `ARCHS = armv7` |

## Why these choices

**armv7 only.** Every device that runs iOS 6 is armv7 or armv7s, and armv7 code
runs on both. arm64 doesn't exist before iOS 7.

**The 10.3 SDK, not 9.3.** The 9.3 SDK's `.tbd` stubs link as *iOS Simulator*
under ld64-609, and the link fails with
`file not found: /usr/lib/system/liblaunch.dylib for architecture armv7`. 10.3
is the newest SDK that still carries armv7 stubs. 11.0 and later are
arm64-only.

**`-Wl,-U,_memset`.** clang emits `memset` calls to zero structs (fast
enumeration state, `CGRect` returns). The 10.3 SDK's stubs export only
`__platform_memset`, not `_memset`, so the link fails. The flag leaves `_memset`
to be looked up when the dylib loads, and iOS 6's libSystem provides it. You
can confirm the binding with:

```sh
~/theos/toolchain/linux/iphone/bin/llvm-objdump --macho --lazy-bind \
  tweak/.theos/obj/armv7/TorchLock.dylib    # shows: flat-namespace _memset
```

**`ld: warning: building for iOS, but linking in .tbd file … built for iOS Simulator`.**
This shows up for every framework the 10.3 SDK pulls in. It's harmless, because
the stubs list both device and simulator architectures and the armv7 slice is
the one used. `make check` is unaffected, since `-Werror` applies only to the
compiler.

**gzip packages.** The phone's dpkg (1.18.10) would accept xz, but gzip is the
format every iOS 6 era dpkg can read. The wrapper passes
`THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip`.

**Signing.** Theos signs the dylib with the toolchain's `ldid`, and the
evasi0n-jailbroken iOS 6.1.3 kernel accepted it as-is. If a different
jailbreak rejects it (SpringBoard logs a code signature error and the tweak
doesn't load), re-sign on the phone with `ldid -S` on the installed dylib.

## No dpkg-deb on the PC

Theos falls back to its bundled `dm.pl` when `dpkg-deb` is missing, so the PC
doesn't need dpkg installed.

## Installing by hand

`make deploy` does this. Spelled out:

```sh
iproxy 2222 22 &
ssh -p 2222 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
    root@localhost 'cat > /tmp/t.deb && dpkg -i /tmp/t.deb && killall -9 SpringBoard' \
    < tweak/packages/com.aurelio.torchlock_*_iphoneos-arm.deb
```

On the phone's side, don't pipe `dpkg` into `head`/`tail`. Neither exists on a
stock iOS 6 jailbreak, so dpkg gets killed by SIGPIPE and installs nothing, even
though the command appears to have run.
