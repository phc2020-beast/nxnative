# iPad mini 6 (A15) build, from an Intel Mac

This branch is TVPort (nxnative plus Apple TV support) with two changes for an A15 iPad, such as the iPad mini 6 (2021, 4 GB). Neither has been tested on an iPad yet.

1. **The app starts on a GPU without BC texture formats.** `dm/ios/Sources/main.m` used to refuse any iPhone or iPad older than the A17 Pro or M1. TVPort's NVN layer decodes BC textures itself (`dm/gfx/nvn/nvn_mtl.m`, `no_bc`), so NVN games, which is most Nintendo games, can run. Vulkan and OpenGL games, such as Super Mario Galaxy, have no such decoder and may draw wrong.
2. **The Apple TV's memory trick is on for iPhone and iPad.** `dm/host/hle_svc.c` `guest_block` backs the game's memory with a file in `Library/Caches` on iOS too (`TARGET_OS_IPHONE`), so it stays outside the app's memory limit. A game then needs up to about 4 GB of free storage while it runs. Put `DM_GUEST_FILE=0` in the app's `Documents/env.txt` to turn it off.

## Building on an Intel Mac

This engine already runs its shader tools on Intel: the translator launcher and `spirv-cross` in `dm/gfx/tools` are universal binaries. Steps that boot the game on the Mac need Apple silicon, and the script skips them or says what it needs.

- Xcode 26.3 (macOS Sequoia's last), with the iOS platform and `xcodebuild -downloadComponent MetalToolchain`.
- Python 3.12 or later, `xcodegen`, `zstd` and `glslang` on the `PATH`, and the .NET SDK 10, as in the Intel setup you already have.
- Add `--allow-other-metal`, the equivalent of the old `--any-metal`, because Xcode 26.3's Metal compiler is not the tested one:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/<game> -k ~/keys/prod.keys --allow-other-metal
```

Sideload the IPA with Increased Memory Limit on. Start with a light NVN game. If textures use too much memory, add `DM_BC_MAX_DIM=1024` to `Documents/env.txt`.
