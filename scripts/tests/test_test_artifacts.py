import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('artifacts', Path(__file__).parents[1] / 'test_artifacts.py')
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'build').mkdir()
        (self.root / 'archive').mkdir()
        (self.root / 'archive/summary.json').write_text('{"result":"recorded"}')
        self.old = self.root / 'build/old.xcresult'
        self.old.mkdir()
        (self.old / 'test.bin').write_bytes(b'old evidence')
        self.kept = self.root / 'build/final.xcresult'
        self.kept.mkdir()
        (self.kept / 'test.bin').write_bytes(b'final evidence')
        self.decisions = {'keep': [{'path': 'build/final.xcresult', 'reason': 'Final gate'}],
                          'delete': [{'path': 'build/old.xcresult', 'reason': 'Superseded',
                                      'evidence': ['archive/summary.json']}]}

    def run_apply(self, plan):
        return a.apply(self.root, plan, self.root / 'archive/receipt.json', idle_check=lambda _: None)

    def test_delete_exact_artifact_preserves_final_and_summary(self):
        result = self.run_apply(a.prepare(self.root, self.decisions))
        self.assertEqual(result['status'], 'complete')
        self.assertFalse(self.old.exists())
        self.assertTrue((self.kept / 'test.bin').exists())
        self.assertTrue((self.root / 'archive/summary.json').exists())

    def test_changed_second_candidate_prevents_all_deletions(self):
        media = self.root / 'build/screen.png'
        media.write_bytes(b'first')
        self.decisions['delete'].append({'path': 'build/screen.png', 'reason': 'Duplicate',
                                         'evidence': ['archive/summary.json']})
        plan = a.prepare(self.root, self.decisions)
        media.write_bytes(b'changed')
        with self.assertRaises(ValueError): self.run_apply(plan)
        self.assertTrue(self.old.exists())

    def test_changed_or_missing_evidence_prevents_delete(self):
        plan = a.prepare(self.root, self.decisions)
        (self.root / 'archive/summary.json').write_text('changed')
        with self.assertRaises(ValueError): self.run_apply(plan)
        self.assertTrue(self.old.exists())

    def test_tracked_file_refused(self):
        subprocess.run(['git', '-C', str(self.root), 'add', '-f', 'build/old.xcresult'], check=True)
        with self.assertRaises(ValueError): a.prepare(self.root, self.decisions)

    def test_outside_build_and_whole_build_refused(self):
        for name in ['build', 'archive/summary.json', 'build/../archive/summary.json']:
            with self.assertRaises(ValueError): a.candidate(self.root, name)

    def test_symlink_candidate_and_ancestor_refused(self):
        (self.root / 'build/link.xcresult').symlink_to(self.old)
        with self.assertRaises(ValueError): a.candidate(self.root, 'build/link.xcresult')
        (self.root / 'build/link').symlink_to(self.root / 'archive')
        (self.root / 'archive/screen.png').write_bytes(b'outside')
        with self.assertRaises(ValueError): a.candidate(self.root, 'build/link/screen.png')

    def test_nested_symlink_never_deletes_target(self):
        target = self.root / 'archive/summary.json'
        (self.old / 'external-link').symlink_to(target)
        self.run_apply(a.prepare(self.root, self.decisions))
        self.assertTrue(target.exists())

    def test_self_evidence_and_kept_overlap_refused(self):
        self.decisions['delete'][0]['evidence'] = ['build/old.xcresult/test.bin']
        with self.assertRaises(ValueError): a.prepare(self.root, self.decisions)
        self.decisions['delete'][0]['evidence'] = ['archive/summary.json']
        self.decisions['keep'].append({'path': 'build/old.xcresult', 'reason': 'Unresolved'})
        with self.assertRaises(ValueError): a.prepare(self.root, self.decisions)

    def test_busy_guard_prevents_delete(self):
        def busy(_): raise RuntimeError('In use')
        plan = a.prepare(self.root, self.decisions)
        with self.assertRaises(RuntimeError):
            a.apply(self.root, plan, self.root / 'archive/receipt.json', idle_check=busy)
        self.assertTrue(self.old.exists())

    def test_closeout_detects_unclassified_media(self):
        plan = a.prepare(self.root, self.decisions)
        self.run_apply(plan)
        self.assertEqual(a.check_closeout(self.root, plan)['status'], 'complete')
        (self.root / 'build/new.png').write_bytes(b'unclassified')
        self.assertEqual(a.check_closeout(self.root, plan)['unclassified_artifacts'], ['build/new.png'])

    def test_closeout_detects_pending_run(self):
        plan = a.prepare(self.root, self.decisions)
        self.run_apply(plan)
        (self.root / 'build/run.json').write_text('{"cleanup_status":"pending"}')
        self.assertEqual(a.check_closeout(self.root, plan)['status'], 'pending')

    def exercise_runner(self, exit_code, summary_error=False):
        import os
        import json
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        tools = self.root / 'fake-tools'; tools.mkdir()
        executable = tools / 'xcodebuild'
        executable.write_text('#!/usr/bin/env python3\nimport pathlib,sys\np=pathlib.Path(sys.argv[sys.argv.index("-resultBundlePath")+1]);p.mkdir();(p/"result").write_text("fixture");sys.exit(' + str(exit_code) + ')\n')
        executable.chmod(0o755)
        derived = self.root / 'shared-derived'; derived.mkdir()
        args = SimpleNamespace(directory='build/runner-test', purpose='regression', scope='isolated fixture',
                               command=['xcodebuild', '-derivedDataPath', str(derived), 'test'])
        capture = patch.object(a, 'capture_summary', side_effect=ValueError('incomplete result')) if summary_error else patch.object(a, 'capture_summary', return_value={'summary': {'result': 'Passed' if exit_code == 0 else 'Failed'}})
        with patch.dict(os.environ, {'PATH': str(tools) + os.pathsep + os.environ['PATH']}), patch.object(a, 'check_idle'), capture:
            self.assertEqual(a.run_tests(self.root, args), exit_code)
        state = json.loads((self.root / args.directory / 'run.json').read_text())
        self.assertEqual(state['cleanup_status'], 'pending')
        self.assertEqual(state['automatic_attachment_export'], False)
        return state

    def test_runner_success_requires_resource_closeout(self):
        self.assertEqual(self.exercise_runner(0)['status'], 'passed')

    def test_runner_failure_still_persists_state(self):
        self.assertEqual(self.exercise_runner(9)['status'], 'failed_or_interrupted')

    def test_runner_summary_error_does_not_leave_running_state(self):
        state = self.exercise_runner(9, summary_error=True)
        self.assertIn('summary_error', state)
        self.assertNotEqual(state['status'], 'running')


if __name__ == '__main__': unittest.main()
