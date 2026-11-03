# TVPort

A Mac app that builds Switch games you own into Apple TV apps and installs them. It sits on [nxnative](https://github.com/seedds/nxnative) (MIT), which runs the game's own code natively with its graphics rebuilt on Metal. No games, keys or Nintendo artwork are part of this project.

Tested hardware: Apple TV 4K (3rd generation, A15), tvOS 27.2, Xcode 27.2.

## Run it

**The packed app:** unzip `TVPort-<version>.zip` and open TVPort.app from any folder. It is signed ad hoc and not notarized, so the first time macOS refuses it: open **System Settings > Privacy & Security** and press **Open Anyway**. At its first start it sets itself up (see [The packed app](#the-packed-app)) and lists anything else this Mac needs in **Setup**.

**From this checkout**, which runs the checkout's own engine:

```bash
cd tvport/app && xcodegen generate
```

```bash
xcodebuild -project tvport/app/TVPort.xcodeproj -scheme TVPort -configuration Release -derivedDataPath tvport/app/build build
```

```bash
open tvport/app/build/Build/Products/Release/TVPort.app
```

That build needs the project folder to stay where it was built, because it runs `tvport/backend.py` from there.

Add a folder holding your game's `.nsp` or `.xci` files, pick your Apple TV, and press **Build & Install**. A first build takes 30 to 60 minutes and needs your `prod.keys`. After that a build takes a few minutes, because the game's rewritten code and shaders are kept in `<title ID>_build` beside the game.

**Choose Artwork** takes any image. The preview is drawn by the same code as the real icon (`dm/ios/tools/tv_icon.swift`), which also makes the Top Shelf banners.

**Last Run** reads the game's log and the system's memory reports from the Apple TV, and says what went wrong in plain words.

**3D resolution** appears for a game whose rewritten code has a render-scale stub, the same test the iPhone launcher uses (`# RENDER_SCALE` in the main's fixups; `backend.py` `render_scale_supported`). That is Tears of the Kingdom 1.4.2 and 1.4.3, and Breath of the Wild 1.9.0. Below Full, the build writes `DM_RENDER_SCALE` into the app's `dm/env.txt`, so the game draws its 3D scene at that fraction of its size. The size is then fixed in place of the game's own dynamic resolution, and the menus stay sharp. It takes effect at the next Build & Install. On the A15, Tears of the Kingdom at 75% went from 15 to 30 fps in the area after the opening movie, with the GPU at about 28 ms a frame.

**Frame rate** appears for a game whose profile has a frame-rate target (`fps_target`, read from the derived profile first; the iPhone launcher's `DM_GAME_FPS_TARGET!=0`). 30 fps writes `DM_FPS_TARGET=30`. The TV then does half the work, so it heats up more slowly, and a game it cannot run at 60 is steadier: Tears of the Kingdom's area after the opening movie needs about 29 ms of GPU a frame at 75%.

**Hold 30 fps when the Apple TV is hot** appears for a game with a frame step (`# FPS_STATE_OFF` in the main's fixups; `frame_step_supported`), and it is on by default. The Apple TV 4K has no fan. When tvOS reports thermal state serious, it lowers the chip's clocks itself, below any app: on iPhones the GPU runs at about a third of its speed ([A thermally serious iPhone holds 30 fps](../docs/reference/frame-rate.md#a-thermally-serious-iphone-holds-30-fps)). No public API turns that off, and it is what protects the TV. With this on, the frame step holds 30 fps until the TV has been back to fair for 30 s. Turned off, the build writes `DM_THERMAL_CAP=0`, and the game keeps trying for 60 fps. It then rarely reaches 60 at the lower clocks, and the TV stays hot, and slow, for longer. Tears of the Kingdom reached serious within 20 to 40 s of a launch in most runs on 2026-11-03. That throttling also slows its loading, which runs on the CPU. What keeps a TV cooler is less work and air around it: a lower 3D resolution and frame rate, and a place that is not shut in a cabinet or set on another warm device.

## The packed app

`python3 scripts/package_tvport.py` makes `tvport/dist/TVPort.app` and `TVPort-<version>.zip` (about 50 MB), an app that runs on any Mac without this checkout. It carries:

| In the app | What it is |
|---|---|
| `Contents/Resources/engine.tar.xz` | The engine: the tracked files of `dm/` and `scripts/` and `LICENSE`, 2,300 files, 300 MB unpacked. `engine.json` names its digest, commit and shader chain |
| `Contents/Resources/backend.py`, `requirements.txt` | This folder's, unchanged |
| `Contents/Helpers/uv` | [uv](https://github.com/astral-sh/uv), which makes the engine's Python |
| `Contents/Resources/Licenses` | nxnative's MIT notice, the engine's third-party licenses and uv's. The About window says the same |

At its first start the app unpacks the engine into `~/Library/Application Support/TVPort/engine/<digest>`, because the engine's tools write beside themselves and a signed app must not change. Then uv downloads Python 3.14 and the packages in `requirements.txt` into `python` and `venv` beside it: about 110 MB, a few seconds, and the only step that needs the internet. Nothing goes into `~/.local` or a shared cache.

It cannot carry these, so **Setup** checks each and gives the command or the place to fix it:

- **Xcode** with its tvOS and iOS platforms and the Metal toolchain. The shaders are iOS Metal libraries, so a tvOS build needs the iOS platform too.
- **An Apple ID** signed in to Xcode (Settings > Accounts). A free one works, and TVPort finds its personal team itself.
- **xcodegen, zstd and glslang** from Homebrew, and the **.NET SDK 10**, which builds the game extractor and runs the shader translator.
- **Your own game dumps and `prod.keys`.** They stay in the folders you choose. TVPort reads the keys only during a first build.

**Updates:** a new TVPort.app carries a new engine. Its first start unpacks that engine, and its first build removes the engines of earlier releases. The Python is made again only when `requirements.txt` changes. Games already built keep their `<title ID>_build`. A new shader chain rebuilds a game's shaders at its next build, which then needs `prod.keys` again. The app does not look for updates itself.

**Never in the app:** game files, keys, built game apps, or anything a build makes. Only tracked files go into the engine, so a profile's shader tables from a game's build (`c1_full.tsv`, `cb_extent.tsv`), extracted files and builds in the checkout stay out. The script stops at a tracked file that looks like one of these, or that `.gitignore` says a build makes. It also leaves out `dm/tools/fuzz`, whose inputs are made-up game files. The game profiles nxnative publishes in `dm/games` are part of the engine. Built games must never be shared: each person builds from their own dumps.

`TVPORT_DATA` moves the app's folder, for a test run.

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

## Saves

tvOS has no lasting storage for files: on tvOS 27.2, `Documents` refuses writes and `Application Support` cannot be created, and `Library/Caches`, where the game keeps its saves, can be purged while the app is closed. Preferences do last. A save is mostly zeros, so it fits there: Super Mario Odyssey's 2 MB save packs to 9 KB.

| Copy | Where | Survives |
|---|---|---|
| Working | `Library/Caches/save` on the TV | Until tvOS purges it |
| Protected | The app's preferences, seconds after each save (`dm/ios/SourcesTV/TVSaves.m`) | A cache purge, a reinstall. Not deleting the app |
| Backup | `<title ID>_build/save-backups` on this Mac, or iCloud Drive's `TVPort Saves/<title ID>`. Every 5 minutes while TVPort is open | Anything that happens to the TV |

The protected copy comes back by itself when the save folder is empty. Build & Install backs up first, and puts the newest backup on a TV that has lost its saves. It never replaces a save that is there. **Back Up Saves** makes the same copy at any time.

### Automatic backups

While TVPort is open it backs up every built game's saves from the selected Apple TV: once when it opens, then every 5 minutes, and every minute while the TV cannot be reached, so a round runs soon after the TV comes back. A round only lists the TV's files and copies from it, with `devicectl`. It never launches, ends or installs anything, so it does not disturb a game being played. It skips its turn while a build runs, because each build backs up first. A TV that is asleep or away, or a game that is not installed, makes no error: the round just ends. Each game in the list shows when its saves were last backed up.

- **Cheap when nothing changed:** each backup keeps the TV's listing it was copied from (`tvport-manifest.json`: path, size and time of each file). A round lists the TV once per game and copies only when the listing differs. Then it takes about a second.
- **Whole copies:** the game commits a save by swapping `save.work` into `save`, so a copy taken across that swap could mix old and new files. After copying, the round lists the TV again and throws the copy away if anything changed. The next round tries again.
- **Kept:** the newest 20 backups, and the newest of each of the last 30 days. A copy identical to the newest backup makes no new one.
- **iCloud Drive:** with **Keep backups in iCloud Drive** on, new backups go to `~/Library/Mobile Documents/com~apple~CloudDocs/TVPort Saves/<title ID>/`. A free Apple ID cannot give the tvOS app iCloud, so the Mac carries them there. If iCloud Drive is off, TVPort says so and keeps them beside the game. A restore takes the newest backup of both places.

The preferences abort the app past about 1 MB, so TVSaves.m keeps them under 900 KB, and a save that would pass that goes to a plain file in `Library/Preferences`. That folder took a write in testing, but Apple does not promise to keep it. `NSUserDefaults` is the documented one. Animal Crossing's island always goes there: it is 24 MB of encrypted files that do not compress. Saves are stored with LZFSE, which takes a fraction of a second, and the copy starts as soon as the app stops being active, so closing it from the app switcher right after a save no longer loses the copy.

### Players

Apple's way to give each Apple TV profile its own data is the User Management capability, which a free Apple ID cannot have: Xcode refuses it, so the app cannot see which profile is active. With two or more names in **Players**, the game asks "Who's playing?" before it starts, and each name gets its own saves (`dm/ios/SourcesTV/TVPlayers.m`). The first name listed keeps the save already on the TV, whoever picks first, and a name keeps its saves for good, so renaming someone starts them fresh. A game whose only save belongs to the console keeps one save for everyone instead, as on a Switch: in Animal Crossing each name is a resident of the same island, and the first name listed keeps the first user. Up to 8 names.

## Limits

- **Memory:** the file-backed guest memory above is what keeps a game under the limit. Everything else, mainly textures and render targets, still counts toward 2,097 MB. The Increased Memory Limit entitlement is silently dropped for a free Apple ID on tvOS.
- **Free Apple ID:** an install stops opening after 7 days. Build & Install renews it. Free accounts also have limits on apps and App IDs, so keep a game's bundle ID, which TVPort does for you.
- **Game files live in `Library/Caches`**, which tvOS may purge when storage runs low. Build & Install sends them again. Saves are protected separately: see [Saves](#saves).
- **First-use shader stalls.** The game records each shader on the TV, and each build copies that list to `tvport-shaders.tsv` beside the game and bundles it, so deleting the app does not lose it. A scene the game has never shown can still stall the first time.
- **Back stays in the game.** The remote's Back and a controller's B do not leave it. Use the TV button.
- **Launching needs an awake TV.** Installs work while it sleeps.
- Only one build runs at a time.

## Tests

```bash
python3 -I tvport/tests/test_backend.py
```

They need no Apple TV, and they never touch `~/Library/Application Support/TVPort` or iCloud Drive.
