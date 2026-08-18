# Troubleshooting

## Game won't launch

Usually mixed-up builds: iPhoneOS dylibs in a PlayCover package or vice
versa. Both are arm64, so nothing complains until runtime. Check:

```bash
file dist/iphone/*.dylib
file dist/playcover/*.dylib

otool -L /path/to/extracted.app/PrinceofPersia |
  grep -E 'nilfix|accountfix|gfxfix'
```

Don't hand-copy dylibs between package types; re-run the patcher for the
right target.

## Black background under PlayCover

Confirm `gfxfix.dylib` sits next to the executable and shows in the
`otool -L` output. Re-import a freshly patched IPA rather than editing
PlayCover's managed copy in place.

## Apple sign-in prompts

`accountfix.dylib` is missing or wasn't injected; verify with `otool -L`.
Note the fix only silences dead endpoints. Online features, Game Center,
purchases, and restores don't come back. The servers are gone.

## Saves

Back up the app container before reinstalling or changing bundle
identifiers. The patcher never touches save data, but reinstalls can wipe it.

## Unlocks didn't apply

Most common cause: no save profile yet. The module waits for
`Documents/Cosmos/1`, so run the clean restored IPA once first. It checks at
2, 4, 8, and 16 seconds after launch, then every 30 seconds while the game
is open. Park the game at the main menu, give it a minute, then cold-launch
so it picks up the changed values. One cold launch isn't always enough;
try a few before assuming it failed.

If a record fails validation or a write fails, the module gives up rather
than retry; it won't risk mangling saves. Don't look for a log in
`Documents`, there isn't one. The completion marker is an extensionless file
tucked away in Application Support, which is also what keeps later launches
from rewriting the saves.

Before changing an existing currency record the mod drops
`.poptr-restored-backup` siblings next to it. Restoring those means digging
into the app container by hand, so a full container backup taken beforehand
is the easier path back.
