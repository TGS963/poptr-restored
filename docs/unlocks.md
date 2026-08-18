# Optional unlocks (currency and characters)

This one's strictly opt-in, which is why it lives in its own build and patch
scripts instead of the normal restoration flow. The restoration IPAs never
include it. `add-unlocks.sh` also refuses anything that isn't a clean
restored IPA for the right target: raw decrypted IPAs, diagnostic builds,
already-modded packages, and iPhone/PlayCover mixups all get rejected.

## What it does

Once the game has created its save profile (`Documents/Cosmos/1`), the
module applies a one-time edit to the save container:

- blue orbs set to 99,999
- red gems set to 9,999
- Princes 2 through 12 unlocked

Characters you already own are left alone. That's the whole list. It doesn't
touch quests, missions, achievements, story progress, weapons, Sands of
Time, XP, or upgrade levels.

I was fairly paranoid about corrupting saves here, so the module is picky:
currency records and their SHA-1 sidecars have to match the exact Spark2
record shape byte for byte, otherwise it refuses to write anything. On a
fresh install where the profile doesn't exist yet, it checks at 2, 4, 8, and
16 seconds after launch, then every 30 seconds until the profile shows up.
After a successful run it drops a marker in Application Support and never
writes again.

## Build and apply

Build for the same target as your restored IPA:

```bash
scripts/build-unlocks.sh iphone      # or: playcover
```

Then produce a separate modded package:

```bash
INSERT_DYLIB=/path/to/insert_dylib \
  scripts/add-unlocks.sh iphone restored-iphone.ipa unlocked-iphone.ipa

INSERT_DYLIB=/path/to/insert_dylib \
  scripts/add-unlocks.sh playcover restored-playcover.ipa unlocked-playcover.ipa
```

The input IPA isn't modified and existing outputs won't be overwritten.
Sideload or import the result again so it gets signed.

## Save safety

Back up the full app container before using this. Yes, really.

The module does its own belt-and-suspenders: before touching an existing
currency record it copies the record and its SHA-1 sidecar with a
`.poptr-restored-backup` suffix, and if any write fails it rolls the whole
currency group back. But those backups live inside the app container, so if
the container goes, they go with it. A full container backup is the only
real safety net.

Removing the dylib afterwards stops future applications, but doesn't undo
anything already written. To get back to the old state, restore your
container backup.

How to run it:

1. Start from a fully closed game.
2. Fresh install? Play until the game creates its profile first.
3. Sit at the main menu until the unlocks apply, then cold-launch so the
   game reloads the changed values. If they don't show up right away, cold
   launch a few more times; sometimes it takes two or three for the game to
   pick them up.

The module runs on the main queue, but I never fully mapped the old game's
background save behavior, so staying off actual gameplay during the update
lowers the odds of a competing save write.

One deliberate quirk: the release module writes nothing visible to
`Documents`, no logs, no status files. Its completion marker is an
extensionless file in Application Support, which is what stops later
launches from rewriting the saves.
