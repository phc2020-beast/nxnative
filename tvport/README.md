# TVPort

A Mac app that builds Switch games you own into Apple TV apps and installs them. It sits on [nxnative](https://github.com/seedds/nxnative) (MIT), which runs the game's own code natively with its graphics rebuilt on Metal. No games, keys or Nintendo artwork are part of this project.

Tested hardware: Apple TV 4K (3rd generation, A15), tvOS 27.2, Xcode 27.2.

## Run it

```bash
cd tvport/app && xcodegen generate
```

```bash
xcodebuild -project tvport/app/TVPort.xcodeproj -scheme TVPort -configuration Release -derivedDataPath tvport/app/build build
```

```bash
open tvport/app/build/Build/Products/Release/TVPort.app
```

Add a folder holding your game's `.nsp` or `.xci` files, pick your Apple TV, and press **Build & Install**. A first build takes 30 to 60 minutes and needs your `prod.keys`. After that a build takes a few minutes, because the game's rewritten code and shaders are kept in `<title ID>_build` beside the game.

**Choose Artwork** takes any image. The preview is drawn by the same code as the real icon (`dm/ios/tools/tv_icon.swift`), which also makes the Top Shelf banners.

**Last Run** reads the game's log and the system's memory reports from the Apple TV, and says what went wrong in plain words.

The app needs the project folder to stay where it was built, because it runs `tvport/backend.py` from there.

## What differs from nxnative

| Change | Where | Why |
|---|---|---|
| tvOS target | `dm/ios/project_tv.yml`, `SourcesTV/`, `build_ipa.sh` (`DM_TVOS=1`) | The app itself |
| Files in `Library/Caches` | `dm/ios/Sources/main.m` | tvOS apps have no lasting `Documents` |
| Controller routing | `front_ios.m` (`GCEventViewController`) | Keeps a controller's B button from also acting as the remote's Back |
| BC textures without BC hardware | `dm/gfx/nvn/nvn_mtl.m`, `dm/gfx/tex/nvn_bcdec.c` | The A15 can't read BC. BC1-5 decode in a GPU kernel, BC6H / BC7 / 3D on every CPU core. Restored from upstream's history (removed in `14fbcf9c`) |
| `DM_BC_MAX_DIM` | `nvn_mtl.m` | Drops the finest mip levels of those textures, which cost 4 to 8 times their Switch size once decoded |

Measured after these changes on the same scene load: 264 textures took 47 ms instead of 271 ms. Once the game had seen a scene, a run had 1 long frame instead of dozens.

The shaders are iOS Metal libraries, which tvOS 27 loads, so these changes leave the shader chain (`d1043b780a74`) as it was and existing shader builds stay valid. A change to the chain means rebuilding every game's shaders.

## Why games stutter or close

Measured on the A15 with Super Mario Odyssey, before these changes:

- **Closing:** tvOS kills an app at 2,097 MB, with no crash report: at most a `JetsamEvent` report with `per-process-limit`, and not every kill files one.
- **Stutter:** mostly texture loading, not shaders. One 556 ms frame spent 285 ms on 264 textures and none on shaders, because they were decoded on the CPU on the thread that submits the frame.
- **Some frames miss 60 fps on the GPU alone:** 17 to 23 ms a frame in docked mode.

## Getting past the memory limit

tvOS ends an app at 2,097 MB of *footprint*, and the Switch gives a game about 3.2 GB of its own, so a large game cannot fit in anonymous memory, the kind footprint counts. Footprint leaves out file pages. So on tvOS the game's memory is a shared mapping of a sparse file (`guest_block` in `dm/host/hle_svc.c`), which the system pages to flash when it needs the room, as a swap file. This needs no entitlement and no paid account, only public APIs. `DM_GUEST_FILE=0` turns it off.

Super Mario Odyssey in Handheld at Medium texture detail, on an A15 Apple TV 4K, in MiB:

| | Anonymous memory | File-backed |
|---|---|---|
| During boot | 879 | 242 |
| Where it was killed | 2,097 | under 700 |
| Peak footprint | 2,097, then killed | 924 |
| Lowest headroom | none | 1,173 |
| Textures loaded | about 500 | 846 |
| Peak Metal allocation | 1,514 | 2,298 |

That run held 59-60 fps after the transition, and tvOS filed no kill. Its length was under 5 minutes, because the game left the foreground cleanly at 4:48. Longer sessions and later kingdoms are untested.

The trade-offs: the game needs up to 4 GB of free storage while it runs, which the system takes back when it ends, however it ends. It adds flash writes. A scene that uses more memory than the TV has free will read pages back from flash, which can hitch. Textures and render targets are still counted against the limit, so Full texture detail is not free.

To measure a run, pass the profiler at launch, because it starts before `env.txt` is read and `Documents` is not writable:

```bash
xcrun devicectl device process launch --device <UDID> --terminate-existing -e '{"DM_MEMSTAT":"../Library/Caches/memstat.tsv"}' <bundle ID>
```

## Limits

- **Memory:** the file-backed guest memory above is what keeps a game under the limit. Everything else, mainly textures and render targets, still counts toward 2,097 MB. The Increased Memory Limit entitlement is silently dropped for a free Apple ID on tvOS.
- **Free Apple ID:** an install stops opening after 7 days. Build & Install renews it. Free accounts also have limits on apps and App IDs, so keep a game's bundle ID, which TVPort does for you.
- **Saves and game files live in `Library/Caches`**, which tvOS may purge when storage runs low. Deleting the app on the TV removes them too. There is no backup yet.
- **First-use shader stalls.** The game records each shader on the TV, and each build copies that list to `tvport-shaders.tsv` beside the game and bundles it, so deleting the app does not lose it. A scene the game has never shown can still stall the first time.
- **Back stays in the game.** The remote's Back and a controller's B do not leave it. Use the TV button.
- **Launching needs an awake TV.** Installs work while it sleeps.
- Only one build runs at a time.

## Tests

```bash
python3 -I tvport/tests/test_backend.py
```
