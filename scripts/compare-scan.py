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
    targets: [.executableTarget(name: "ScanProbe", dependencies: [.product(name: "StorageCore", package: "StorageScope")])])
'''.replace('SOURCE', json.dumps(str(source))))
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
(fixture / 'linked-loop').symlink_to(fixture, target_is_directory=True)
with (fixture / 'sparse.img').open('wb') as handle:
    handle.truncate(256 * 1024 * 1024)
samples = {'reference': [], 'candidate': []}
expected = None
for iteration in range(6):
    for name in (['reference', 'candidate'] if iteration % 2 == 0 else ['candidate', 'reference']):
        result = json.loads(subprocess.check_output([str(executables[name]), str(fixture)], text=True, timeout=90))
        elapsed = result.pop('seconds')
        if expected is None:
            expected = result
        assert result == expected, 'The candidate changed coverage, categories, totals or exclusions'
        if iteration > 0:
            samples[name].append(elapsed)
reference_time, candidate_time = (statistics.median(samples[name]) for name in ['reference', 'candidate'])
report = {'referenceVersion': '3.5.1', 'candidateVersion': '3.6.0', 'fixtureFiles': 10004,
    'identicalCoverageAndTotals': True, 'result': expected, 'seconds': samples,
    'referenceMedianSeconds': reference_time, 'candidateMedianSeconds': candidate_time,
    'candidateToReferenceRatio': candidate_time / reference_time}
(root / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
assert candidate_time <= reference_time * 1.10, 'More than 10% scan regression on the same warmed fixture; investigate before release'
