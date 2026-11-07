# Breath of the Wild on an iPad mini 6 (A15)

This branch is TVPort (68hctmzzjf-svg/TVPort, itself nxnative by seedds) with its two Apple TV changes turned on for iPad and iPhone too:

| Change | Where | Why |
|---|---|---|
| Guest memory in a file | `dm/host/hle_svc.c` `guest_block` | iPadOS ends an app on its *footprint*, which counts anonymous memory but not file pages. The game's 4 GB block is a shared mapping of an unlinked sparse file in `Library/Caches`, which the system pages to flash. On by default on iOS devices with at most 6 GB of RAM; `DM_GUEST_FILE=0` turns it off, `=1` on |
| No BC textures | `dm/ios/Sources/main.m` | Upstream refuses to start on a GPU without BC formats (A15 / A16). TVPort restored the decoder (`nvn_mtl.m`, `nvn_bcdec.c`); the iOS start check now logs instead of refusing |

Settings for the iPad are in [`scripts/ipad_a15/botw-env.txt`](../scripts/ipad_a15/botw-env.txt): handheld, texture cap 512, 3D at 75%, 30 fps.

## Build on the Intel Mac (Xcode 26.3)

```
scripts/ipad_a15/build_botw_ipad.sh            # defaults: ~/Downloads/BotW and ~/Downloads/prod.keys
```

It runs `build_ipa_from_nsp.py` with `--allow-other-metal --gpu none --romfs separate --env-file scripts/ipad_a15/botw-env.txt --bundle-id com.michellecarrega.botw`, a build folder of its own (`<NSP folder>/ipad_a15_build`) and its own IPA (`ZeldaBreathOfTheWild-iPad.ipa`), so the iPhone build and its IPA are left alone.

- The shader chain differs from the fork's main, so the first build recompiles every shader.
- `--romfs separate` keeps the IPA small; run the copy command the script prints once to put the game files on the iPad.
- The iPad needs about 4 GB free while the game runs, for the guest memory file, on top of the game files.
