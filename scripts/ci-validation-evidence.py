"""Bind successful CI dependencies and installed-package proofs to one candidate.

The artifact is uploaded by the dependent CI job, not accepted from a caller.
Release jobs download it from that exact GitHub run and verify it again. This
does not depend on eventually consistent workflow/check status summaries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('mode', choices=['create', 'verify'])
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--head', required=True)
parser.add_argument('--run-id', required=True)
parser.add_argument('--version', required=True)
parser.add_argument('--package', type=Path)
args = parser.parse_args()
groups = {'build-and-test', 'windows-build', 'macos-package', 'macos-installed'}
runners = ['macos-14', 'macos-26', 'xcode-27']
package = args.package or args.root / 'macos-validated-package-candidate/release-assets/StorageScope-macOS-arm64-DEVELOPMENT.pkg'
digest = hashlib.sha256(package.read_bytes()).hexdigest()
output = args.root / 'ci-validation.json'

if args.mode == 'create':
    needs = json.loads(os.environ['CI_VALIDATION_NEEDS'])
    assert set(needs) == groups and all(value['result'] == 'success' for value in needs.values()), 'A required CI dependency did not succeed'
    assert os.environ['GITHUB_SHA'] == args.head and os.environ['GITHUB_RUN_ID'] == args.run_id
    installed = {}
    for runner in runners:
        root = args.root / ('macos-package-proof-' + runner)
        proof = json.loads((root / 'storagescope-package-validation.json').read_text())
        assert proof['version'] == args.version and proof['packageSha256'] == digest
        for field in ['offlineInstalledStartup', 'replacementPreservesData', 'userOwnedApplicationTrashed']:
            assert proof[field] is True
        trash = json.loads((root / 'storagescope-explorer-trash-validation.json').read_text())
        assert trash['version'] == args.version
        assert all(trash[field] is True for field in ['realExplorerConfirmation', 'ordinaryCleanupRemainsBlocked',
            'actualSystemRecycle', 'unreadableTrashEntryRetained', 'unknownSizeNotZero',
            'onlyDisposableFixtureEmptied', 'replacedFolderPreserved'])
        update = json.loads((root / 'storagescope-update-validation/results.json').read_text())
        assert update['valid']['installedVersion'] == args.version
        assert update['valid']['realSparkleReplacement'] and update['valid']['newVersionStarts']
        for case in ['unsigned', 'invalid-signature', 'altered', 'interrupted', 'cancelled', 'read-only']:
            assert update[case]['rejected'] and update[case]['previousVersionPreserved']
        installed[runner] = {'os': proof['os'], 'architecture': proof['architecture'],
            'packageSHA256': digest, 'trashVerified': True, 'updateVerified': True}
    scan = json.loads((args.root / 'macos-native-interface-xcode-27/storagescope-scan-comparison/results.json').read_text())
    assert scan['identicalCoverageAndTotals'] and scan['singleFileReplayExact']
    assert scan['candidateToReferenceRatio'] <= scan['fullTreePersistenceBudgetRatio']
    record = {'schemaVersion': 1, 'headSHA': args.head, 'runId': args.run_id, 'version': args.version,
        'checks': {name: 'success' for name in sorted(groups)}, 'packageSHA256': digest,
        'installed': installed, 'scanCoverageVerified': True}
    output.write_text(json.dumps(record, indent=2), encoding='utf-8')
else:
    record = json.loads(output.read_text())

assert record['schemaVersion'] == 1 and record['headSHA'] == args.head and record['runId'] == args.run_id
assert record['version'] == args.version and record['packageSHA256'] == digest
assert record['checks'] == {name: 'success' for name in groups}
assert record['scanCoverageVerified'] is True and set(record['installed']) == set(runners)
for proof in record['installed'].values():
    assert proof['architecture'] == 'arm64' and proof['packageSHA256'] == digest
    assert proof['trashVerified'] is True and proof['updateVerified'] is True
print(json.dumps({'version': args.version, 'headSHA': args.head, 'allRequiredChecksVerified': True,
    'packageSHA256': digest, 'installedRunners': runners}))
