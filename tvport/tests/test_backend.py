import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend  # noqa: E402

LOG = '''[dm] [nvn-mtl] memory up to frame 2700: resident 1867 MB, GPU allocated 1483 MB, deferred-release queue 10; headroom to the system memory limit 230 MB
[longframe] frame 1491 (27.11 s) whole frame 556.1 ms, submit+present 533.1 ms, GPU 238.4 ms; new pipelines 0 + shader libraries 0, 0.0 ms in all; texture uploads 264 first + 0 re-uploads, 61.4 MB / 284.6 ms; draws with a hybrid pipeline 0
[longframe] frame 1632 (29.47 s) whole frame 54.5 ms, submit+present 40.5 ms, GPU 9.5 ms; new pipelines 4 + shader libraries 0, 31.8 ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms; draws with a hybrid pipeline 0
[longframe] frame 1535 (27.84 s) whole frame 23.3 ms, submit+present 7.6 ms, GPU 20.5 ms; new pipelines 0 + shader libraries 0, 0.0 ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms; draws with a hybrid pipeline 0
[dm] [nvn] on-screen up to frame 3000: 300 frames, dropped 0 (discarded 0), p99 16.68 ms; footprint 1873 MiB; brightness -1.00; thermal 0
[dm] [nvn-mtl] parallel precompile: 363 draws left in this submission, 2 pipelines handed to the background
'''


class ReadLog(unittest.TestCase):
    def setUp(self):
        self.run_log = backend.read_log(LOG)

    def test_memory(self):
        self.assertEqual(self.run_log['peak_mb'], 1873)
        self.assertEqual(self.run_log['gpu_mb'], 1483)
        self.assertEqual(self.run_log['min_headroom_mb'], 230)
        self.assertEqual(self.run_log['last_frame'], 3000)

    def test_only_real_hitches_are_counted(self):
        self.assertEqual(self.run_log['hitches'], 2)
        self.assertEqual(self.run_log['worst_ms'], 556.1)
        self.assertEqual(self.run_log['texture_ms'], 284.6)
        self.assertEqual(self.run_log['pipeline_ms'], 31.8)

    def test_gpu_overruns(self):
        self.assertEqual(self.run_log['gpu_slow_frames'], 2)

    def test_last_line(self):
        self.assertTrue(self.run_log['ended_on_precompile'])

    def test_empty_log(self):
        empty = backend.read_log('')
        self.assertEqual((empty['peak_mb'], empty['hitches'], empty['min_headroom_mb']), (0, 0, None))


class Verdicts(unittest.TestCase):
    def test_textures_are_named_as_the_cause(self):
        text = ' '.join(backend.verdicts(backend.read_log(LOG), []))
        self.assertIn('mostly texture loading', text)

    def test_memory_kill_comes_first(self):
        kills = [{'time': '2026-11-02 11:52:39.00 -0700', 'reason': 'per-process-limit', 'mb': 2100}]
        out = backend.verdicts(backend.read_log(LOG), kills)
        self.assertIn('2,100 MB', out[0])

    def test_clean_run(self):
        out = backend.verdicts(backend.read_log('[dm] [nvn] on-screen up to frame 600: 300 frames, dropped 0 (discarded 0), p99 16.68 ms; footprint 900 MiB; thermal 0'), [])
        self.assertEqual(len(out), 1)
        self.assertIn('Nothing unusual', out[0])
        self.assertIn('closed by itself', out[0])


class Jetsam(unittest.TestCase):
    def test_reports_only_this_apps_kills(self):
        report = {'date': '2026-11-02 11:52:39', 'memoryStatus': {'pageSize': 16384}, 'processes': [
            {'name': 'DmIOS', 'rpages': 134400, 'reason': 'per-process-limit'}, {'name': 'cloudd', 'rpages': 100, 'reason': 'per-process-limit'}]}
        alive = {'date': '2026-11-02 11:53:13', 'memoryStatus': {'pageSize': 16384}, 'processes': [{'name': 'DmIOS', 'rpages': 110000}]}
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'JetsamEvent-1.ips').write_text('{"bug_type":"298"}\n' + json.dumps(report))
            (Path(folder) / 'JetsamEvent-2.ips').write_text('{"bug_type":"298"}\n' + json.dumps(alive))
            (Path(folder) / 'JetsamEvent-3.ips').write_text('not json')
            self.assertEqual(backend.read_jetsam(Path(folder)), [{'time': '2026-11-02 11:52:39', 'reason': 'per-process-limit', 'mb': 2100}])


class Failures(unittest.TestCase):
    def test_the_reason_survives_a_quiet_ending(self):
        script = "echo '[RED] This game needs a device'; echo noise; echo '** BUILD FAILED **'; exit 65"
        with self.assertRaises(backend.Failure) as caught:
            backend.stream(['/bin/sh', '-c', script], log_filter=lambda line: False)
        self.assertIn('needs a device', str(caught.exception))
        self.assertNotIn('noise', str(caught.exception))

    def test_a_failure_without_a_reason_shows_the_last_lines(self):
        with self.assertRaises(backend.Failure) as caught:
            backend.stream(['/bin/sh', '-c', 'echo last words; exit 1'], log_filter=lambda line: False)
        self.assertIn('last words', str(caught.exception))


class OneBuildAtATime(unittest.TestCase):
    def test_a_second_build_is_refused_and_the_lock_comes_back(self):
        with tempfile.TemporaryDirectory() as folder:
            original, backend.SUPPORT = backend.SUPPORT, Path(folder)
            try:
                first = backend.one_build_at_a_time()
                with self.assertRaises(backend.Failure):
                    backend.one_build_at_a_time()
                first.close()
                backend.one_build_at_a_time().close()
            finally:
                backend.SUPPORT = original


class ShaderList(unittest.TestCase):
    def test_rows_merge_once_in_first_seen_order(self):
        self.assertEqual(backend.merged_rows('# header\nS\ta\t0\nR\tb\n', 'R\tb\nC\tc\n\n'), ['S\ta\t0', 'R\tb', 'C\tc'])

    def test_saved_rows_join_the_manifest_after_its_header(self):
        with tempfile.TemporaryDirectory() as folder:
            build, project = Path(folder), Path(folder) / 'project'
            (project / 'Gen/dm').mkdir(parents=True)
            (project / 'Gen/dm/pso_manifest.tsv').write_text('# header\nS\ta\t0\n')
            (build / backend.SHADER_LIST).write_text('S\ta\t0\nR\tb\n')
            game = type('G', (), {'build': build})()
            backend.bundle_shaders(game, project)
            self.assertEqual((project / 'Gen/dm/pso_manifest.tsv').read_text(), '# header\nS\ta\t0\nR\tb\n')

    def test_no_saved_list_leaves_the_manifest_alone(self):
        with tempfile.TemporaryDirectory() as folder:
            build, project = Path(folder), Path(folder) / 'project'
            (project / 'Gen/dm').mkdir(parents=True)
            (project / 'Gen/dm/pso_manifest.tsv').write_text('# header\n')
            backend.bundle_shaders(type('G', (), {'build': build})(), project)
            self.assertEqual((project / 'Gen/dm/pso_manifest.tsv').read_text(), '# header\n')


class Devices(unittest.TestCase):
    def test_keeps_real_apple_tvs_only(self):
        listing = {'result': {'devices': [
            {'hardwareProperties': {'deviceType': 'appleTV', 'reality': 'simulated', 'udid': 'SIM'}},
            {'hardwareProperties': {'deviceType': 'iPhone', 'reality': 'physical', 'udid': 'PHONE'}},
            {'hardwareProperties': {'deviceType': 'appleTV', 'reality': 'physical', 'udid': 'TV', 'marketingName': 'Apple TV 4K (3rd generation)'},
             'deviceProperties': {'name': 'Basement', 'osVersionNumber': '27.2', 'developerModeStatus': 'enabled'}, 'connectionProperties': {'tunnelState': 'connected'}}]}}
        tvs = backend.apple_tvs(listing)
        self.assertEqual([t['id'] for t in tvs], ['TV'])
        self.assertTrue(tvs[0]['connected'] and tvs[0]['developer_mode'])


class GameFolder(unittest.TestCase):
    def make(self, folder, *paths):
        for path in paths:
            target = Path(folder) / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('')

    def test_new_game_is_not_prepared(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make(folder, 'Game.nsp', 'cover.png')
            game = backend.Game(Path(folder))
            self.assertEqual(game.sources, ['Game.nsp'])
            self.assertFalse(game.prepared)

    def test_built_game_is_found(self):
        chain = backend.chain()
        with tempfile.TemporaryDirectory() as folder:
            self.make(folder, '0100000000010000_build/patched_v1/main.patched.bin', '0100000000010000_build/extract/v1/RomFS.img', f'0100000000010000_build/shader/ios/b-{chain}/inputs.tsv')
            game = backend.Game(Path(folder))
            self.assertEqual((game.title_id, game.package), ('0100000000010000', 'v1'))
            self.assertTrue(game.prepared)

    def test_shaders_of_another_chain_do_not_count(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make(folder, '0100000000010000_build/patched_v1/main.patched.bin', '0100000000010000_build/extract/v1/RomFS.img', '0100000000010000_build/shader/ios/b-000000000000/inputs.tsv')
            self.assertFalse(backend.Game(Path(folder)).prepared)

    def test_new_bundle_id_comes_from_team_and_title(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make(folder, '0100ABCD00000000_build/x')
            self.assertEqual(backend.Game(Path(folder)).bundle_id('TEAM123'), 'dev.tvport.team123.g0100abcd00000000')


if __name__ == '__main__':
    unittest.main()
