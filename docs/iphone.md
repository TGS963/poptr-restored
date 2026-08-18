# Physical iPhone

Tested configurations:

- iPhone 6s Plus (`iPhone8,2`), iOS 15.8.8
- iPhone 5s (`iPhone6,1`), iOS 12.5.7
- Time Run 2.0.5, arm64
- libraries built with an iOS 10 minimum deployment target

The 5s is the oldest arm64 iPhone, so the iOS 10 deployment target covers it.
Other arm64 iPhones should work; nothing here is device-specific.

The normal package carries `nilfix.dylib` and `accountfix.dylib`. The
PlayCover graphics fix isn't needed on real hardware. `iosdebug.dylib` is
optional and only logs launch notifications and uncaught Objective-C
exceptions.

The patcher removes `UISupportedDevices` from the Info.plist (an old device
allowlist that blocks newer models) and preserves everything else.
Diagnostic builds also enable Finder file sharing so the log can be pulled
off the device; normal builds don't touch file-sharing settings.

## Build and patch

```bash
scripts/build.sh iphone

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/patch.sh iphone input.ipa restored-iphone.ipa
```

Install with a tool that re-signs under your own provisioning identity. Free
provisioning means re-signing every week.

Diagnostic build:

```bash
INSERT_DYLIB=/path/to/insert_dylib \
  scripts/patch.sh iphone --diagnostics input.ipa diagnostic-iphone.ipa
```

The log lands at `Documents/PoPTR-Restored.log`, reachable via Finder.

The optional currency and character modification is applied separately to a
completed restored IPA. See [unlocks.md](unlocks.md); it is never included by
the normal iPhone patch command.
