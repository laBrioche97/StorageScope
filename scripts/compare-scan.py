"""Same machine, same fixture, alternating optimized builds; no personal files."""
import io
import json
import os
from pathlib import Path
import statistics
import subprocess
import tarfile

assert os.environ.get('GITHUB_ACTIONS') == 'true'
repository = Path.cwd()
root = Path(os.environ['RUNNER_TEMP']) / 'storagescope-scan-comparison'
root.mkdir()
reference = root / 'reference'
reference.mkdir()
subprocess.run(['git', 'fetch', '--depth=1', 'origin', 'refs/tags/v3.5.1:refs/tags/v3.5.1'], check=True)
assert subprocess.check_output(['git', 'rev-parse', 'v3.5.1'], text=True).strip() == '259d13b2af47ab6385c9a804032867b9c89db7f6'
archive = subprocess.check_output(['git', 'archive', '--format=tar', 'v3.5.1'])
with tarfile.open(fileobj=io.BytesIO(archive)) as package:
    package.extractall(reference, filter='data')
probe_source = (repository / 'scripts/scan-probe.swift').read_text()
executables = {}
for name, source in [('reference', reference), ('candidate', repository)]:
    probe = root / (name + '-probe')
    (probe / 'Sources/ScanProbe').mkdir(parents=True)
    (probe / 'Sources/ScanProbe/main.swift').write_text(probe_source)
    (probe / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScanProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "StorageScope", path: SOURCE)],
    targets: [.executableTarget(name: "ScanProbe", dependencies: [.product(name: "StorageCore", package: "StorageScope")], swiftSettings: SETTINGS)])
'''.replace('SOURCE', json.dumps(str(source))).replace('SETTINGS', '[.define("STORAGESCOPE_TREE_PROBE")]' if name == 'candidate' else '[]'))
    log = root / (name + '-build.log')
    with log.open('w') as handle:
        subprocess.run(['swift', 'build', '--disable-sandbox', '--configuration', 'release', '--package-path', str(probe), '--product', 'ScanProbe'], check=True, stdout=handle, stderr=subprocess.STDOUT, timeout=300)
    output = subprocess.check_output(['swift', 'build', '--disable-sandbox', '--configuration', 'release', '--package-path', str(probe), '--show-bin-path'], text=True).strip()
    executables[name] = Path(output) / 'ScanProbe'
fixture = root / 'fixture'
fixture.mkdir()
extensions = ['jpg', 'mp4', 'pdf', 'zip', 'swift', 'log', 'mp3']
for index in range(10000):
    folder = fixture / ('folder-' + str(index // 50))
    folder.mkdir(exist_ok=True)
    (folder / ('item-' + str(index) + '.' + extensions[index % len(extensions)])).write_bytes(bytes([index % 251]) * (32 + index % 1024))
(fixture / '.hidden').write_bytes(b'hidden')
os.link(fixture / '.hidden', fixture / 'hard-link')
with (fixture / 'sparse.img').open('wb') as handle:
    handle.truncate(256 * 1024 * 1024)
samples = {'reference': [], 'candidate': []}
expected = None
for iteration in range(6):
    for name in (['reference', 'candidate'] if iteration % 2 == 0 else ['candidate', 'reference']):
        result = json.loads(subprocess.check_output([str(executables[name]), str(fixture)], text=True, timeout=90, env=dict(os.environ, STORAGESCOPE_BENCHMARK_VOLUME="isolated-scan-" + name)))
        elapsed = result.pop('seconds')
        if expected is None:
            expected = result
            assert result['files'] == 10003 and result['directories'] == 200, 'The complete fixture must be covered'
        assert result == expected, 'The candidate changed coverage, categories, totals or exclusions'
        if iteration > 0:
            samples[name].append(elapsed)
reference_time, candidate_time = (statistics.median(samples[name]) for name in ['reference', 'candidate'])
# A separate golden-coverage case: the old directory-only skip operation on a
# link could omit an unrelated sibling. Neither version may traverse the loop.
(fixture / 'linked-loop').symlink_to(fixture, target_is_directory=True)
linked = {}
for name in ['reference', 'candidate']:
    linked[name] = json.loads(subprocess.check_output([str(executables[name]), str(fixture)], text=True, timeout=90, env=dict(os.environ, STORAGESCOPE_BENCHMARK_VOLUME="isolated-scan-" + name)))
    linked[name].pop('seconds')
assert linked['candidate'] == dict(expected, skipped=expected['skipped'] + 1), 'A link must not change any sibling totals or categories'
# 3.7 adds a durable record for every file, unlike the directory-only reference.
# Preserve the exact coverage checks and measure that new work explicitly. The
# persistent-tree baseline will become the reference for subsequent 10% checks.
replay_samples = []
for iteration in range(3):
    print("Startup replay", iteration + 1, flush=True)
    replay = json.loads(subprocess.check_output([str(executables['candidate']), str(fixture), '--replay'], text=True, timeout=90,
        env=dict(os.environ, STORAGESCOPE_BENCHMARK_VOLUME='isolated-scan-candidate')))
    replay_samples.append(replay.pop('seconds'))
    assert replay == dict(expected, skipped=expected['skipped'] + 1), 'Startup replay lost persistent files or changed the complete totals'
changed = fixture / 'folder-0/item-0.jpg'
changed.write_bytes(changed.read_bytes() + b'delta')
# Give the journal daemon time to publish this isolated change before opening.
import time
time.sleep(2)
changed_replay = json.loads(subprocess.check_output([str(executables['candidate']), str(fixture), '--replay'], text=True, timeout=90,
    env=dict(os.environ, STORAGESCOPE_BENCHMARK_VOLUME='isolated-scan-candidate', STORAGESCOPE_PROBE_EXPECTED_LOGICAL=str(expected['logicalBytes'] + 5))))
changed_seconds = changed_replay.pop('seconds')
changed_expected = json.loads(json.dumps(expected))
changed_expected['skipped'] += 1
changed_expected['logicalBytes'] += 5
changed_expected['categories']['Images']['logical'] += 5
assert changed_replay == changed_expected, 'A single-file replay must update exact totals without omitting the rest of the tree'
report = {'referenceVersion': '3.5.1', 'candidateVersion': '3.7.0', 'fixtureFiles': 10003,
    'identicalCoverageAndTotals': True, 'result': expected, 'seconds': samples,
    'symbolicLinkRegression': {'referenceFiles': linked['reference']['files'], 'candidateFiles': linked['candidate']['files'],
        'loopNotTraversed': True, 'allSiblingFilesRetained': True},
    'referenceMedianSeconds': reference_time, 'candidateMedianSeconds': candidate_time,
    'candidateToReferenceRatio': candidate_time / reference_time,
    'fullTreePersistenceBudgetRatio': 1.25,
    'startupReplaySeconds': replay_samples, 'startupReplayMedianSeconds': statistics.median(replay_samples),
    'singleFileReplaySeconds': changed_seconds, 'singleFileReplayExact': True}
(root / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
assert candidate_time <= reference_time * 1.25, 'Full scan plus durable file tree exceeds its 25% added-work budget; investigate before release'
assert statistics.median(replay_samples) < candidate_time * 0.75, 'An unchanged startup must be substantially faster than a full scan'
assert changed_seconds < candidate_time * 0.75, 'One changed file must not cost another full scan'
