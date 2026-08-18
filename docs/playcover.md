# PlayCover on Apple Silicon

Three libraries get injected:

- `nilfix.dylib`: same nil-string launch fix as the iPhone build
- `accountfix.dylib`: same disabled Game Center and StoreKit paths
- `gfxfix.dylib`: retained backing for the old Spark2 render layers, which
  otherwise draw the gameplay background as black

PlayTools comes from PlayCover itself; nothing here replaces it.

The graphics fix applies retained backing broadly. I also tried a narrower
hook targeting specific layers, but it left the background broken in a visual
A/B against the unpatched baseline, so the broad version ships.

## Build and patch

```bash
scripts/build.sh playcover

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/patch.sh playcover input.ipa restored-playcover.ipa
```

Import the IPA into PlayCover. Start with keymapping off; the game's old
touch queue under translated keymaps isn't validated.

Want the currency and character unlocks too? That's a separate pass over the
finished restored IPA, never part of the normal patch command. See
[unlocks.md](unlocks.md).
