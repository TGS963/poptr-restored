# PoP: TR Restored

Compatibility patches to keep Prince of Persia: Time Run 2.0.5 running on a
modern iPhone and on Apple Silicon via PlayCover. The game was delisted years
ago; unpatched, it crashes at launch on recent iOS and draws a black
background under PlayCover.

This repo holds the source: Objective-C shims, shell scripts, and docs.
The decrypted original IPA and the patched builds it produces are archived
separately (archive.org link to follow) so the game is preserved as a
runnable pair.

## The fixes

- `nilfix.dylib` fixes a launch crash from an API that now returns nil where
  the game expects a string
- `accountfix.dylib` disables sign-in prompts from dead Game Center and
  StoreKit endpoints
- `gfxfix.dylib` (PlayCover only) forces retained backing on the old Spark2
  render layers so the background isn't black
- `unlockmod.dylib` (optional) unlocks in-game currency and character skins;
  kept out of the normal patch flow on purpose

The iPhone patcher also strips `UISupportedDevices` from the Info.plist, a
hardcoded device allowlist that blocks installs on newer models. All real
compatibility checks still apply.

## Requirements

- Apple Silicon Mac with Xcode command-line tools
- An arm64 IPA of Time Run 2.0.5 (see the archive)
- An `insert_dylib` build (pointed at via `INSERT_DYLIB`)
- PlayCover, or a sideloading tool for a physical iPhone

## Usage

```bash
scripts/build.sh iphone      # or: playcover

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/patch.sh iphone input.ipa restored-iphone.ipa

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/patch.sh playcover input.ipa restored-playcover.ipa
```

Add `--diagnostics` after `iphone` to inject a small launch logger. The output
IPA is ad-hoc signed; your install tool still needs to sign it properly.

Unlocks are a separate second step on top of an already restored IPA:

```bash
scripts/build-unlocks.sh iphone      # or: playcover

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/add-unlocks.sh iphone restored-iphone.ipa unlocked-iphone.ipa

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/add-unlocks.sh playcover restored-playcover.ipa unlocked-playcover.ipa
```

The normal restoration output is never touched by this. Read
[docs/unlocks.md](docs/unlocks.md) first, and back up the app container
before applying; it edits save data.

Details in [docs/iphone.md](docs/iphone.md) and
[docs/playcover.md](docs/playcover.md); known failure modes in
[docs/troubleshooting.md](docs/troubleshooting.md).

Back up your saves before touching an existing install.

See [NOTICE.md](NOTICE.md).
