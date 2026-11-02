#!/usr/bin/env python3
"""TVPort backend: builds a Switch game you own into an Apple TV app, installs it, and reads back how it ran.

The Mac app drives this; it also runs on its own. Commands print JSON: `devices`, `inspect` and `diagnose` one object, `build`
a stream of one object per line, {"event": "stage" | "log" | "progress" | "error" | "done", ...}.

The game goes through nxnative as usual (scripts/build_ipa_from_nsp.py makes <title ID>_build: rewritten modules and shaders), then
build_ipa.sh with DM_TVOS=1 makes a separate tvOS project beside them. A build folder from an earlier run is reused, so only the first build of a game takes long.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

REPO = Path(__file__).resolve().parent.parent
TITLE_RE = re.compile(r'^([0-9A-Fa-f]{16})_build$')
SOURCE_SUFFIXES = {'.nsp', '.xci', '.nsz', '.xcz'}
ENGINE_PACKAGES = ('fontTools', 'capstone', 'lz4')
SUPPORT = Path.home() / 'Library/Application Support'
TEXTURE_CAPS = (0, 1024, 512, 256)
CACHES = 'Library/Caches'
SHADER_LIST = 'tvport-shaders.tsv'
SAVE_BACKUPS = 'save-backups'
KEEP_BACKUPS = 20
LAUNCH_SETTLE_S = 3
SAVE_FILE = re.compile(r'^save(\.p-[a-z0-9-]+)?(_device)?/.')   # each player's committed save; save.work, save.new and the like are working copies


REASON = re.compile(r' error: |\[RED\]|FAIL: ')   # lines that say why a tool stopped; xcodebuild's own last lines only say that it did


class Failure(Exception):
    """A problem the person can act on; its text is shown as it is."""


def emit(event: str, **fields) -> None:
    print(json.dumps({'event': event, **fields}), flush=True)


def stage(name: str) -> None:
    emit('stage', name=name)


def run(argv: Iterable, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in argv], text=True, capture_output=True, **kwargs)


def stream(argv: Iterable, *, env=None, cwd=None, on_line=None, log_filter=None) -> None:
    """Run a command, passing its output on as log events; stop with its last lines when it fails."""
    process = subprocess.Popen([str(a) for a in argv], env=env, cwd=cwd, text=True, errors='replace', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    tail: list = []
    reasons: list = []
    for raw in process.stdout:
        line = raw.rstrip('\n')
        tail = (tail + [line])[-25:]
        if REASON.search(line):
            reasons = (reasons + [line.strip()])[-12:]
        if on_line:
            on_line(line)
        if log_filter is None or log_filter(line):
            emit('log', line=line[:400])
    if process.wait():
        raise Failure('\n'.join(reasons or tail[-6:])[-1500:])


def engine_python() -> str:
    """An interpreter with the engine's packages: this project's own environment, then the one NX Play installed, then the system's."""
    candidates = [SUPPORT / 'TVPort/venv/bin/python3', SUPPORT / 'NX Play/venv/bin/python3', Path('/opt/homebrew/bin/python3'), Path(shutil.which('python3') or 'python3')]
    probe = '; '.join(f'import {p}' for p in ENGINE_PACKAGES)
    for python in candidates:
        if python.exists() and run([python, '-c', probe]).returncode == 0:
            return str(python)
    raise Failure('No Python with fontTools, capstone and lz4. In Terminal: python3 -m pip install lz4 "capstone>=5,<6" fonttools nsz zbic')


def chain() -> str:
    match = re.search(r'#define DMSH_CHAIN "(.*)"', (REPO / 'dm/gfx/nvn/dmsh_chain.h').read_text())
    if not match:
        raise Failure('The engine has no shader chain version (dm/gfx/nvn/dmsh_chain.h)')
    return match.group(1)


def nacp_text(path: Path, flag: Optional[str] = None) -> str:
    result = run([sys.executable, '-I', REPO / 'dm/tools/nacp.py'] + ([flag] if flag else []) + [path])
    return result.stdout.strip() if result.returncode == 0 else ''


class Game:
    """One game folder and what earlier builds left in it."""

    def __init__(self, folder: Path):
        self.folder = folder.expanduser().resolve()
        if not self.folder.is_dir():
            raise Failure(f'No such folder: {self.folder}')
        self.title_id = ''
        self.build = None
        builds = sorted(p for p in self.folder.iterdir() if p.is_dir() and TITLE_RE.match(p.name))
        if builds:
            self.build = builds[0]
            self.title_id = TITLE_RE.match(self.build.name).group(1)

    @property
    def sources(self) -> list:
        return sorted(p.name for p in self.folder.iterdir() if p.suffix.lower() in SOURCE_SUFFIXES)

    @property
    def package(self) -> Optional[str]:
        patched = sorted(self.build.glob('patched_*')) if self.build else []
        patched = [p for p in patched if p.is_dir()]
        return patched[-1].name[len('patched_'):] if patched else None

    @property
    def extract(self) -> Optional[Path]:
        return self.build / 'extract' / self.package if self.package else None

    @property
    def romfs(self) -> Optional[Path]:
        if not self.extract:
            return None
        image = self.extract / 'RomFS.img'
        return image if image.is_file() else None

    @property
    def shaders(self) -> Optional[Path]:
        if not self.build:
            return None
        folder = self.build / 'shader/ios'
        return folder if (folder / f'b-{chain()}/inputs.tsv').is_file() else None

    @property
    def prepared(self) -> bool:
        return bool(self.package and self.romfs and self.shaders)

    @property
    def state_file(self) -> Optional[Path]:
        return self.build / 'tvport.json' if self.build else None

    def state(self) -> dict:
        if self.state_file and self.state_file.is_file():
            return json.loads(self.state_file.read_text())
        return {}

    def save_state(self, **fields) -> None:
        self.state_file.write_text(json.dumps({**self.state(), **fields}, indent=1))

    @property
    def icon(self) -> Optional[Path]:
        icon = self.extract / 'icon.jpg' if self.extract else None
        return icon if icon and icon.is_file() else None

    @property
    def app(self) -> Optional[Path]:
        return self.build / 'tvport-derived/Build/Products/Release-appletvos/DmIOS.app' if self.build else None

    def earlier_app(self) -> Optional[Path]:
        """The app of a build made before this project: its bundle ID keeps the game data already on the TV."""
        for app in (self.app, self.build / 'xcode-derived-data/Build/Products/Release-appletvos/DmIOS.app' if self.build else None):
            if app and (app / 'Info.plist').is_file():
                return app
        return None

    def bundle_id(self, team: str) -> str:
        saved = self.state().get('bundle_id')
        if saved:
            return saved
        app = self.earlier_app()
        if app:
            return plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
        return f'dev.tvport.{team.lower()}.g{self.title_id.lower()}'

    def name(self) -> str:
        control = self.extract / 'control.nacp' if self.extract else None
        return (nacp_text(control) if control and control.is_file() else '') or self.folder.name

    def version(self) -> str:
        control = self.extract / 'control.nacp' if self.extract else None
        return nacp_text(control, '--version') if control and control.is_file() else ''


def provisioning(app: Optional[Path]) -> dict:
    """What a signed app's profile says: its team, and when tvOS stops opening it."""
    profile = app / 'embedded.mobileprovision' if app else None
    if not profile or not profile.is_file():
        return {}
    decoded = run(['security', 'cms', '-D', '-i', profile])
    if decoded.returncode:
        return {}
    data = plistlib.loads(decoded.stdout.encode())
    expires = data['ExpirationDate'].replace(tzinfo=timezone.utc)
    return {'team': data['TeamIdentifier'][0], 'expires': expires.isoformat(), 'days_left': (expires - datetime.now(timezone.utc)).days,
            'free_team': bool(data.get('LocalProvision')) or (expires - data['CreationDate'].replace(tzinfo=timezone.utc)).days <= 7}


def known_team() -> str:
    folders = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles', Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    for folder in folders:
        for profile in sorted(folder.glob('*.mobileprovision'), key=lambda p: p.stat().st_mtime, reverse=True) if folder.is_dir() else []:
            decoded = run(['security', 'cms', '-D', '-i', profile])
            if decoded.returncode == 0:
                return plistlib.loads(decoded.stdout.encode())['TeamIdentifier'][0]
    return ''


def devicectl_json(*args) -> dict:
    with tempfile.TemporaryDirectory() as folder:
        out = Path(folder) / 'out.json'
        result = run(['xcrun', 'devicectl', *args, '--quiet', '--json-output', out])
        if not out.is_file():
            raise Failure(result.stderr.strip() or 'devicectl gave no answer. Is Xcode installed?')
        return json.loads(out.read_text())


def apple_tvs(listing: dict) -> list:
    tvs = []
    for device in listing.get('result', {}).get('devices', []):
        hardware = device.get('hardwareProperties', {})
        if hardware.get('deviceType') != 'appleTV' or hardware.get('reality') != 'physical':
            continue
        properties, connection = device.get('deviceProperties', {}), device.get('connectionProperties', {})
        tvs.append({'id': hardware.get('udid'), 'name': properties.get('name'), 'model': hardware.get('marketingName'), 'os': properties.get('osVersionNumber'),
                    'connected': connection.get('tunnelState') == 'connected', 'developer_mode': properties.get('developerModeStatus') == 'enabled'})
    return tvs


def installed_files(device: str, bundle: str) -> dict:
    try:
        data = devicectl_json('device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--subdirectory', CACHES)
    except (Failure, json.JSONDecodeError):
        return {}
    return {f.get('relativePath'): f.get('metadata', {}).get('size') for f in data.get('result', {}).get('files', [])}


def cmd_devices(_) -> None:
    print(json.dumps({'devices': apple_tvs(devicectl_json('list', 'devices'))}))


def cmd_inspect(args) -> None:
    game = Game(args.folder)
    app = game.earlier_app() if game.build else None
    profile = provisioning(app)
    team = profile.get('team') or known_team()
    print(json.dumps({'folder': str(game.folder), 'title_id': game.title_id, 'name': game.name() if game.build else game.folder.name, 'version': game.version() if game.build else '',
                      'sources': game.sources, 'prepared': game.prepared, 'icon': str(game.icon) if game.icon else None, 'team': team,
                      'bundle_id': game.bundle_id(team) if game.build and team else None, 'signing': profile, 'saved': game.state(),
                      'keys': str(find_keys(game) or '') or None, 'last_backup': latest_backup(game).name if latest_backup(game) else None}))


def cmd_preview(args) -> None:
    result = run(['xcrun', 'swift', REPO / 'dm/ios/tools/tv_icon.swift', args.art, '--preview', args.out])
    if result.returncode:
        raise Failure(result.stderr.strip() or 'The artwork could not be read')
    print(json.dumps({'preview': str(args.out)}))


def find_keys(game: Game) -> Optional[Path]:
    """prod.keys in the usual places, so one copy serves every game."""
    for folder in (game.folder, game.folder.parent, Path.home() / 'Games', Path.home() / '.switch', Path.home() / 'Downloads', Path.home() / 'Desktop'):
        keys = folder / 'prod.keys'
        if keys.is_file():
            return keys
    return None


def save_files(device: str, bundle: str) -> list:
    """The committed saves on the TV, as paths under Library/Caches. An app that is not installed has none."""
    try:
        data = devicectl_json('device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--subdirectory', CACHES)
    except (Failure, json.JSONDecodeError):
        return []
    return sorted(f['relativePath'] for f in data.get('result', {}).get('files', []) if SAVE_FILE.match(f.get('relativePath', '')) and not f.get('resources', {}).get('isDirectory'))


def latest_backup(game: Game) -> Optional[Path]:
    folders = sorted(p for p in (game.build / SAVE_BACKUPS).glob('*') if p.is_dir()) if game.build else []
    return folders[-1] if folders else None


def same_files(one: Path, other: Path) -> bool:
    names = lambda root: sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
    return names(one) == names(other) and all((one / n).read_bytes() == (other / n).read_bytes() for n in names(one))


def backup_saves(game: Game, device: str, bundle: str) -> dict:
    """Copies the TV's saves to the Mac, which survives what the TV's storage may not: an app deleted on the TV takes its preferences with it. Identical saves make no new backup."""
    files = save_files(device, bundle)
    if not files:
        return {'files': 0, 'folder': None, 'changed': False}
    incoming = game.build / '.save-backup-incoming'   # outside the backups, so a copy that fails partway is never taken for one
    shutil.rmtree(incoming, ignore_errors=True)
    for name in files:
        (incoming / name).parent.mkdir(parents=True, exist_ok=True)
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', f'{CACHES}/{name}', '--destination', incoming / name])
        if not (incoming / name).is_file():
            shutil.rmtree(incoming, ignore_errors=True)
            raise Failure(f'Could not copy {name} from the Apple TV. Nothing was changed.')
    newest = latest_backup(game)
    if newest and same_files(incoming, newest):
        shutil.rmtree(incoming)
        return {'files': len(files), 'folder': str(newest), 'changed': False}
    stamp, n = datetime.now().strftime('%Y-%m-%d-%H%M%S'), 1
    target = game.build / SAVE_BACKUPS / stamp
    while target.exists():
        n += 1
        target = game.build / SAVE_BACKUPS / f'{stamp}-{n}'
    target.parent.mkdir(parents=True, exist_ok=True)
    incoming.rename(target)
    for old in sorted(p for p in target.parent.iterdir() if p.is_dir())[:-KEEP_BACKUPS]:
        shutil.rmtree(old)
    return {'files': len(files), 'folder': str(target), 'changed': True}


def restore_saves(game: Game, device: str, bundle: str) -> int:
    """Puts the newest backup back on a TV that has lost its saves. It never replaces a save that is there."""
    backup = latest_backup(game)
    if not backup or save_files(device, bundle):
        return 0
    names = [p for p in backup.rglob('*') if p.is_file() and SAVE_FILE.match(str(p.relative_to(backup)))]
    for path in names:
        result = run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', path, '--destination', f'{CACHES}/{path.relative_to(backup)}'])
        if result.returncode:
            raise Failure(f'Could not put {path.name} back on the Apple TV: {result.stderr.strip()[-300:]}')
    return len(names)


def write_env(game: Game, mode: str, texture_cap: int, players: str = '') -> Path:
    """The switches the app reads at launch (main.m, dm/env.txt)."""
    path = game.build / 'tvport-env.txt'
    lines = ['# Written by TVPort', f'DM_OPMODE={0 if mode == "handheld" else 1}', f'DM_BC_MAX_DIM={texture_cap}']
    if players.strip():
        lines.append('DM_TV_PLAYERS=' + ' '.join(players.split()))
    path.write_text('\n'.join(lines) + '\n')
    return path


def profile_env(game: Game) -> dict:
    env = dict(os.environ)
    derived = game.build / 'profile'
    if (derived / game.title_id / 'game.tsv').is_file():
        env.update(DM_GAMES_DIR=str(derived), DM_GAMES_FIRST='1')
    return env


def restore_tables(game: Game) -> None:
    """c1_full.tsv and cb_extent.tsv are outputs of the shader build, kept in the profile, and a new checkout has none: take them from the game's last project."""
    profile = game.build / 'profile' / game.title_id
    if not profile.is_dir():
        profile = REPO / 'dm/games' / game.title_id
    for name in ('c1_full.tsv', 'cb_extent.tsv'):
        for origin in (game.build / 'tvport-xcode/Gen/dm' / name, game.build / 'xcode/Gen/dm' / name):
            if not (profile / name).is_file() and origin.is_file():
                shutil.copy2(origin, profile / name)


def prepare_game(game: Game, keys: Optional[Path], team: str, python: str) -> Game:
    stage('Extracting the game, rewriting its code and building shaders')
    emit('log', line='This is the long step: 30 to 60 minutes the first time, and once per game.')
    keys = keys if keys and keys.is_file() else find_keys(game)
    if not keys:
        raise Failure('This game has not been built yet, so it needs your prod.keys file')
    command = [python, REPO / 'scripts/build_ipa_from_nsp.py', game.folder, '-k', keys, '--prepare-xcode', '--keep-extracted', '--gpu', 'none', '--romfs', 'separate', '--allow-other-metal', '--progress', 'lines']
    if team:
        command += ['--team-id', team]
    stream(command, cwd=REPO)
    game = Game(game.folder)
    if not game.prepared:
        raise Failure('The engine finished without shaders or game files for this game. See the log above.')
    return game


def generate_project(game: Game, args, team: str, bundle: str, python: str) -> Path:
    stage('Generating the Apple TV project')
    restore_tables(game)
    env = profile_env(game)
    env.update(GAME=game.title_id, W=str(game.build), PATCHED=str(game.build / f'patched_{game.package}'), ROMFS=str(game.romfs), MSL_IOS=str(game.shaders), AOC='',
               DM_TVOS='1', DM_COPY_ROMFS='NO', DM_SHOW_FPS='1' if args.fps else '0', DM_ENV_FILE=str(write_env(game, args.mode, args.texture_cap, args.players)), DM_BUNDLE_ID=bundle, DM_TEAM_ID=team,
               DM_XCODE_PROJECT_DIR=str(game.build / 'tvport-xcode'), DM_XCODE_DERIVED_DATA=str(game.build / 'tvport-derived'), FONT_PY=python)
    art = args.art or game.icon
    if art:
        env['DM_ICON'] = str(art)
    stream(['bash', REPO / 'dm/ios/tools/build_ipa.sh', '--prepare-xcode'], env=env, cwd=REPO)
    return game.build / 'tvport-xcode'


def merged_rows(*texts: str) -> list:
    """Shader list rows from every source, each once, in the order first seen."""
    rows = dict.fromkeys(line for text in texts for line in text.splitlines() if line.strip() and not line.startswith('#'))
    return list(rows)


def remember_shaders(game: Game, device: str, bundle: str) -> None:
    """The game records each shader and pipeline it meets on the TV, in Library/Caches, and warms them at launch. That file goes when the app or the cache goes, and the game then stalls on
    each one again, so a copy stays beside the game. A game that has not run yet has nothing to copy."""
    saved = game.build / SHADER_LIST
    with tempfile.TemporaryDirectory() as folder:
        copy = Path(folder) / 'pso_user.tsv'
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', f'{CACHES}/pso_user.tsv', '--destination', copy])
        if copy.is_file():
            rows = merged_rows(saved.read_text() if saved.is_file() else '', copy.read_text())
            saved.write_text('\n'.join(rows) + '\n')


def bundle_shaders(game: Game, project: Path) -> None:
    """Puts the saved list into the app's own prewarm list, which the app reads next to the one on the TV."""
    saved, manifest = game.build / SHADER_LIST, project / 'Gen/dm/pso_manifest.tsv'
    if saved.is_file() and manifest.is_file():
        known = manifest.read_text()
        rows = merged_rows(saved.read_text())
        manifest.write_text(known.rstrip('\n') + '\n' + '\n'.join(row for row in rows if row not in set(merged_rows(known))) + '\n')
        emit('log', line=f'{len(rows)} known shaders and pipelines go into the app.')


def compile_app(game: Game, project: Path, device: Optional[str]) -> None:
    stage('Compiling and signing')
    schemes = sorted(p.stem for p in (project / 'DmIOS.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
    if not schemes:
        raise Failure('The generated project has no scheme')
    total = max(len(list((project / 'Gen/src').iterdir())), 1) + 12
    done = [0]

    def on_line(line: str) -> None:
        if line.startswith('CompileC ') or line.startswith('CompileAssetCatalog') or line.startswith('Ld '):
            done[0] += 1
            emit('progress', value=min(done[0] / total, 0.99))

    command = ['xcodebuild', '-project', project / 'DmIOS.xcodeproj', '-scheme', schemes[0], '-configuration', 'Release', '-destination', f'platform=tvOS,id={device}' if device else 'generic/platform=tvOS',
               '-derivedDataPath', game.build / 'tvport-derived', '-allowProvisioningUpdates', 'build']
    stream(command, on_line=on_line, log_filter=lambda x: bool(REASON.search(x)) or x.startswith(('CodeSign', '** ', 'Copy game resources')))
    emit('progress', value=1.0)


def install(game: Game, device: str, bundle: str) -> None:
    stage('Installing on the Apple TV')
    if not game.app or not (game.app / 'embedded.mobileprovision').is_file():
        raise Failure('Build the app first: there is no signed app to install')
    result = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, game.app])
    if result.returncode:
        raise Failure(result.stderr.strip()[-900:] or 'The install failed')
    stage('Checking the game files on the Apple TV')
    size = game.romfs.stat().st_size
    if installed_files(device, bundle).get('romfs.img') == size:
        emit('log', line='The game files are already on the Apple TV.')
        return
    emit('log', line=f'Sending the game files ({size / 2**30:.1f} GB). This takes a few minutes over the network.')
    stream(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', game.romfs, '--destination', f'{CACHES}/romfs.img'])


def one_build_at_a_time():
    """Two builds would write the same project and race each other's install on the TV. The system drops this lock when the process ends, however it ends."""
    path = SUPPORT / 'TVPort/build.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Failure('Another TVPort build is already running. Wait for it to finish.')
    return lock


def cmd_build(args) -> None:
    lock = one_build_at_a_time()   # held until this process exits
    game = Game(args.folder)
    team = args.team or known_team()
    if not team:
        raise Failure('No Apple signing team found. Open Xcode, sign in under Settings > Accounts, and build any app for the Apple TV once.')
    python = engine_python()
    if not game.prepared:
        game = prepare_game(game, args.keys, team, python)
    bundle = game.bundle_id(team)
    if args.device:
        remember_shaders(game, args.device, bundle)
        stage('Backing up saves to this Mac')
        backup = backup_saves(game, args.device, bundle)
        emit('log', line=f'{backup["files"]} save files backed up.' if backup['changed'] else 'The saves on this Mac are already up to date.' if backup['files'] else 'No saves on the Apple TV yet.')
    project = generate_project(game, args, team, bundle, python)
    bundle_shaders(game, project)
    compile_app(game, project, args.device)
    game.save_state(bundle_id=bundle, art=str(args.art) if args.art else None, mode=args.mode, texture_cap=args.texture_cap)
    if args.device:
        install(game, args.device, bundle)
        restored = restore_saves(game, args.device, bundle)
        if restored:
            emit('log', line=f'The Apple TV had lost its saves: {restored} files put back from this Mac.')
    emit('done', bundle_id=bundle, app=str(game.app), signing=provisioning(game.app))


def cmd_backup(args) -> None:
    game = Game(args.folder)
    if not game.build:
        raise Failure('This game has not been built yet, so it has no saves.')
    print(json.dumps(backup_saves(game, args.device, args.bundle)))


def running_pids(listing: dict, executable: str = 'DmIOS') -> list:
    return [p.get('processIdentifier') for p in listing.get('result', {}).get('runningProcesses', []) if f'/{executable}.app/' in str(p.get('executable', ''))]


def cmd_launch(args) -> None:
    # devicectl's --terminate-existing launches at once, and the Home screen coming back can then land on top of the new launch: tvOS suspends it during startup, which looks like a hang.
    # So the old instance goes first, and the Home screen gets a moment to settle.
    pids = running_pids(devicectl_json('device', 'info', 'processes', '--device', args.device))
    for pid in pids:
        run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', args.device, '--pid', pid])
    if pids:
        time.sleep(LAUNCH_SETTLE_S)
    result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device, args.bundle])
    if result.returncode:
        message = result.stdout + result.stderr
        raise Failure('The Apple TV is asleep. Wake it with the remote, then try again.' if 'asleep' in message else message.strip()[-700:])
    print(json.dumps({'launched': args.bundle}))


NUMBER = r'(-?[\d.]+)'
MEMORY_LINE = re.compile(rf'memory up to frame (\d+): resident {NUMBER} MB, GPU allocated {NUMBER} MB')
HEADROOM = re.compile(rf'headroom to the system memory limit {NUMBER} MB')
LONG_FRAME = re.compile(rf'\[longframe\] frame (\d+) \({NUMBER} s\) whole frame {NUMBER} ms, submit\+present {NUMBER} ms, GPU {NUMBER} ms; new pipelines (\d+) \+ shader libraries (\d+), {NUMBER} ms in all; '
                        rf'texture uploads (\d+) first \+ (\d+) re-uploads, {NUMBER} MB / {NUMBER} ms')
ON_SCREEN = re.compile(rf'on-screen up to frame (\d+): (\d+) frames, dropped (\d+).*?footprint (\d+) MiB')
HITCH_MS = 33.4   # a frame that misses two refreshes at 60 Hz


def read_log(text: str) -> dict:
    """What one run's log.txt says about memory and long frames."""
    memory = [(int(m[1]), float(m[2]), float(m[3])) for m in MEMORY_LINE.finditer(text)]
    headroom = [float(x) for x in HEADROOM.findall(text)]
    footprints = [int(m[4]) for m in ON_SCREEN.finditer(text)]
    frames = [{'frame': int(m[1]), 'ms': float(m[3]), 'gpu': float(m[5]), 'pipelines': float(m[8]), 'textures': float(m[12]), 'uploads': int(m[9])} for m in LONG_FRAME.finditer(text)]
    hitches = [f for f in frames if f['ms'] >= HITCH_MS]
    last_frame = max([m[0] for m in memory] + [int(m[1]) for m in ON_SCREEN.finditer(text)], default=0)
    return {'last_frame': last_frame, 'peak_mb': max([m[1] for m in memory] + footprints, default=0), 'gpu_mb': max((m[2] for m in memory), default=0), 'min_headroom_mb': min(headroom, default=None),
            'hitches': len(hitches), 'worst_ms': max((f['ms'] for f in frames), default=0), 'texture_ms': round(sum(f['textures'] for f in hitches), 1), 'pipeline_ms': round(sum(f['pipelines'] for f in hitches), 1),
            'gpu_slow_frames': len([f for f in frames if f['gpu'] > 16.7]), 'ended_on_precompile': text.rstrip().split('\n')[-1:] and 'parallel precompile' in text.rstrip().split('\n')[-1]}


def read_jetsam(folder: Path, process: str = 'DmIOS') -> list:
    """Times tvOS ended this app for memory; an out-of-memory kill leaves only these reports, no crash report."""
    kills = []
    for path in sorted(folder.rglob('JetsamEvent-*.ips')):
        lines = path.read_text(errors='replace').split('\n', 1)
        if len(lines) < 2:
            continue
        try:
            report = json.loads(lines[1])
        except json.JSONDecodeError:
            continue
        page = report.get('memoryStatus', {}).get('pageSize', 16384)
        for entry in report.get('processes', []):
            if entry.get('name') == process and entry.get('reason'):
                kills.append({'time': report.get('date', path.stem), 'reason': entry['reason'], 'mb': entry.get('rpages', 0) * page >> 20})
    return kills


def verdicts(run_log: dict, kills: list) -> list:
    """Plain sentences for the person, each from a number above."""
    out = []
    if kills:
        last = kills[-1]
        out.append(f'tvOS ended the game for using too much memory ({last["mb"]:,} MB, {last["reason"]}) at {last["time"][:19]}. Most of that is the game itself, so Texture Detail helps only a little.')
    headroom = run_log['min_headroom_mb']
    if headroom is not None and headroom < 200:
        out.append(f'Memory is tight: {headroom:.0f} MB from the limit at its lowest. A scene load can end the game.')
    if run_log['hitches']:
        if run_log['texture_ms'] > run_log['pipeline_ms'] * 2:
            out.append(f'{run_log["hitches"]} long frames, mostly texture loading ({run_log["texture_ms"]:.0f} ms against {run_log["pipeline_ms"]:.0f} ms of shaders). Lower Texture Detail.')
        elif run_log['pipeline_ms'] > run_log['texture_ms'] * 2:
            out.append(f'{run_log["hitches"]} long frames, mostly first-use shaders ({run_log["pipeline_ms"]:.0f} ms). They fade as the game sees each scene once.')
        else:
            out.append(f'{run_log["hitches"]} long frames: {run_log["texture_ms"]:.0f} ms of texture loading, {run_log["pipeline_ms"]:.0f} ms of shaders.')
    if run_log['gpu_slow_frames']:
        out.append(f'{run_log["gpu_slow_frames"]} slow frames took the GPU over 16.7 ms. Handheld mode lowers its load.')
    if not out and run_log['last_frame']:
        out.append(f'Nothing unusual up to frame {run_log["last_frame"]:,}, with memory at {run_log["peak_mb"]:,.0f} MB. If the game closed by itself, tvOS most likely ended it for memory: a sudden spike can miss these readings, and tvOS does not always file a report.')
    return out


def cmd_diagnose(args) -> None:
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle, '--source', f'{CACHES}/log.txt', '--destination', folder / 'log.txt'])
        if copied.returncode or not (folder / 'log.txt').is_file():
            raise Failure('The game has not left a log on the Apple TV yet. Play it once, then look again.')
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'systemCrashLogs', '--source', '.', '--destination', folder / 'reports'])
        log = (folder / 'log.txt').read_text(errors='replace')
        run_log, kills = read_log(log), read_jetsam(folder / 'reports')
        print(json.dumps({'run': run_log, 'kills': kills[-5:], 'verdicts': verdicts(run_log, kills[-1:]), 'log': log[-20000:]}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('devices')
    inspect = commands.add_parser('inspect')
    inspect.add_argument('folder', type=Path)
    preview = commands.add_parser('preview')
    preview.add_argument('--art', type=Path, required=True)
    preview.add_argument('--out', type=Path, required=True)
    build = commands.add_parser('build')
    build.add_argument('folder', type=Path)
    build.add_argument('--keys', type=Path)
    build.add_argument('--team')
    build.add_argument('--device')
    build.add_argument('--art', type=Path)
    build.add_argument('--mode', choices=('handheld', 'docked'), default='handheld')
    build.add_argument('--texture-cap', type=int, choices=TEXTURE_CAPS, default=512)
    build.add_argument('--fps', action='store_true')
    build.add_argument('--players', default='')
    backup = commands.add_parser('backup')
    backup.add_argument('folder', type=Path)
    backup.add_argument('--device', required=True)
    backup.add_argument('--bundle', required=True)
    launch = commands.add_parser('launch')
    launch.add_argument('--device', required=True)
    launch.add_argument('--bundle', required=True)
    diagnose = commands.add_parser('diagnose')
    diagnose.add_argument('--device', required=True)
    diagnose.add_argument('--bundle', required=True)
    args = parser.parse_args()
    try:
        {'devices': cmd_devices, 'inspect': cmd_inspect, 'preview': cmd_preview, 'build': cmd_build, 'backup': cmd_backup, 'launch': cmd_launch, 'diagnose': cmd_diagnose}[args.command](args)
    except Failure as failure:
        if args.command == 'build':
            emit('error', message=str(failure))
        else:
            print(json.dumps({'error': str(failure)}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
