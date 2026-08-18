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
