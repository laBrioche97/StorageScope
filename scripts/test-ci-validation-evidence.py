import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get('STORAGESCOPE_TEST_TEMP', tempfile.gettempdir())).resolve()
        self.temp = tempfile.TemporaryDirectory(dir=base)
        assert Path(self.temp.name).resolve().parent == base
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'macos-validated-package-candidate/release-assets/StorageScope-macOS-arm64-DEVELOPMENT.pkg'
        self.package.parent.mkdir(parents=True)
        self.package.write_bytes(b'disposable candidate bytes')
        self.digest = hashlib.sha256(self.package.read_bytes()).hexdigest()
        self.needs = {name: {'result': 'success'} for name in ['build-and-test', 'windows-build', 'macos-package', 'macos-installed']}
        self.write('macos-native-interface-xcode-27/storagescope-scan-comparison/results.json', {
            'identicalCoverageAndTotals': True, 'singleFileReplayExact': True,
            'candidateToReferenceRatio': 1.1, 'fullTreePersistenceBudgetRatio': 1.25})
        for runner in ['macos-15', 'macos-26', 'xcode-27']:
            base = 'macos-package-proof-' + runner + '/'
            self.write(base + 'storagescope-package-validation.json', {'version': '3.7.1', 'packageSha256': self.digest,
                'offlineInstalledStartup': True, 'replacementPreservesData': True, 'userOwnedApplicationTrashed': True,
                'os': runner, 'architecture': 'arm64'})
            self.write(base + 'storagescope-explorer-trash-validation.json', {'version': '3.7.1', **{key: True for key in [
                'realExplorerConfirmation', 'ordinaryCleanupRemainsBlocked', 'actualSystemRecycle', 'unreadableTrashEntryRetained',
                'unknownSizeNotZero', 'onlyDisposableFixtureEmptied', 'replacedFolderPreserved']}})
            self.write(base + 'storagescope-update-validation/results.json', {'valid': {'installedVersion': '3.7.1',
                'realSparkleReplacement': True, 'newVersionStarts': True, 'completeIndexPreserved': True,
                'incrementalChangesOnly': True, 'noAutomaticFullRescan': True}, **{key: {'rejected': True, 'previousVersionPreserved': True}
                for key in ['unsigned', 'invalid-signature', 'altered', 'interrupted', 'cancelled', 'read-only']}})

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def run_check(self, mode, needs=None, head='head-fixture', run='42'):
        environment = dict(os.environ, CI_VALIDATION_NEEDS=json.dumps(needs or self.needs), GITHUB_SHA='head-fixture', GITHUB_RUN_ID='42')
        return subprocess.run([sys.executable, str(Path(__file__).with_name('ci-validation-evidence.py')), mode,
            '--root', str(self.root), '--head', head, '--run-id', run, '--version', '3.7.1'],
            env=environment, capture_output=True).returncode

    def test_successful_suite_then_reject_wrong_commit_run_or_changed_package(self):
        self.assertEqual(self.run_check('create'), 0)
        self.assertEqual(self.run_check('verify'), 0)
        self.assertNotEqual(self.run_check('verify', head='another-commit'), 0)
        self.assertNotEqual(self.run_check('verify', run='another-run'), 0)
        self.package.write_bytes(b'changed package')
        self.assertNotEqual(self.run_check('verify'), 0)

    def test_failed_or_skipped_dependency_cannot_produce_evidence(self):
        for name in self.needs:
            for result in ['failure', 'skipped', 'cancelled']:
                with self.subTest(name=name, result=result):
                    needs = copy.deepcopy(self.needs)
                    needs[name]['result'] = result
                    self.assertNotEqual(self.run_check('create', needs=needs), 0)

    def test_mismatched_installed_candidate_and_missing_native_proof_rejected(self):
        self.write('macos-package-proof-macos-26/storagescope-package-validation.json', {'version': '3.7.1', 'packageSha256': 'wrong'})
        self.assertNotEqual(self.run_check('create'), 0)
        (self.root / 'macos-package-proof-macos-15/storagescope-explorer-trash-validation.json').unlink()
        self.assertNotEqual(self.run_check('create'), 0)

    def test_tampered_dependency_or_native_result_in_downloaded_evidence_rejected(self):
        self.assertEqual(self.run_check('create'), 0)
        record = json.loads((self.root / 'ci-validation.json').read_text())
        record['checks']['windows-build'] = 'skipped'
        self.write('ci-validation.json', record)
        self.assertNotEqual(self.run_check('verify'), 0)
        self.assertEqual(self.run_check('create'), 0)
        record = json.loads((self.root / 'ci-validation.json').read_text())
        record['installed']['macos-26']['trashVerified'] = False
        self.write('ci-validation.json', record)
        self.assertNotEqual(self.run_check('verify'), 0)


    def test_lost_index_or_full_rescan_during_upgrade_rejected(self):
        name = 'macos-package-proof-macos-26/storagescope-update-validation/results.json'
        original = json.loads((self.root / name).read_text())
        for key in ['completeIndexPreserved', 'incrementalChangesOnly', 'noAutomaticFullRescan']:
            record = copy.deepcopy(original)
            record['valid'][key] = False
            self.write(name, record)
            self.assertNotEqual(self.run_check('create'), 0)


if __name__ == '__main__':
    unittest.main()
