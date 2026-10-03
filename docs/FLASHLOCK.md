# Why FlashLock misbehaves on iOS 6

[FlashLock](http://moreinfo.thebigboss.org/moreinfo/depiction.php?file=flashlockData)
1.1-1 (`com.filippobiga.flashlock`, BigBoss, 2011) adds a flashlight button to
the lock screen. On an iPhone 4 running iOS 6.1.3, a tap does this:

1. the torch blinks once
2. the lock screen freezes and the display goes dark
3. a few seconds later the torch comes on and stays on

## What the binary does

FlashLock.dylib is armv6 code from the iOS 4 era. Disassembling its
`toggleLight` method gives this sequence for switching on:

```
devices → objectAtIndex:0 → hasTorch
AVCaptureSession alloc/init → beginConfiguration
AVCaptureDeviceInput deviceInputWithDevice:error: → addInput:
AVCaptureVideoDataOutput alloc/init → setSampleBufferDelegate:queue: → addOutput:
lockForConfiguration: → setTorchMode:On → commitConfiguration
startRunning
```

To switch off, it checks `isRunning`, then calls `stopRunning` and
`unlockForConfiguration`.

On iOS 4, an `AVCaptureSession` was the only reliable way to keep the torch on.
That explains each of the symptoms:

- **The single blink.** `commitConfiguration` applies the torch setting before
  the session is running.
- **The freeze and dark screen.** `startRunning` is synchronous, and FlashLock
  calls it on SpringBoard's main thread. Powering up the whole camera pipeline
  takes seconds on an iPhone 4 and drops the torch while it happens. The lock
  screen can't respond during that time, and its short dim timer runs out.
- **The light coming back.** Once the session is running, the torch setting
  takes effect again.
- **Battery drain.** While the light is on, the camera keeps capturing video
  frames into the sample buffer delegate.

Other weaknesses: it takes `devices[0]` instead of asking for the back camera,
and it tracks whether the light is on through the session's `isRunning`, so it
can't recover if anything else touches the torch.

## What TorchLock does instead

Since iOS 5 the torch can be switched with no session at all:

```objc
[device lockForConfiguration:&error];
[device setTorchMode:AVCaptureTorchModeOn];
[device unlockForConfiguration];
```

The setting persists after `unlockForConfiguration`. On the test phone it stayed
on through 30 seconds of lock screen sleep. TorchLock reads the torch state
from the device's own `torchMode`, so the button always shows the real state.

## Method

The analysis was static: strings, plus a Capstone disassembly with selector
references resolved from `__objc_selrefs`. FlashLock's binary is not included
in this repository.
