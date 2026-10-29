"""Runs only on an ephemeral CI Mac, against a real installed Apple Silicon package."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

if os.environ.get('GITHUB_ACTIONS') != 'true' or not os.environ.get('RUNNER_TEMP'):
    raise RuntimeError('Package installation tests require an isolated GitHub runner')

package = Path(sys.argv[1]).resolve()
app = Path('/Applications/StorageScope.app')
binary = app / 'Contents/MacOS/StorageScope'
report = Path(os.environ['RUNNER_TEMP']) / 'storagescope-package-validation.json'
subprocess.run(['sudo', 'installer', '-pkg', str(package), '-target', '/'], check=True, timeout=120)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
expected = plistlib.loads(Path('Packaging/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == expected['CFBundleShortVersionString']
assert info['CFBundleVersion'] == expected['CFBundleVersion']
assert info['CFBundleIdentifier'] == 'com.labrioche.StorageScope'
assert info['LSMinimumSystemVersion'] == '14.0' and info['SURequireSignedFeed']
assert all(info.get(key) for key in ['NSAppBundlesUsageDescription', 'NSAppDataUsageDescription', 'NSAppleEventsUsageDescription'])
architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
assert set(architectures) == {'arm64'}
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
environment = dict(os.environ, HTTP_PROXY='http://127.0.0.1:9', HTTPS_PROXY='http://127.0.0.1:9', ALL_PROXY='http://127.0.0.1:9')
subprocess.run([str(binary), '--verify-installation'], env=environment, check=True, timeout=35)
# This runner is disposable. Never exercise removal against an existing application.
fixture = Path('/Applications') / ('StorageScope-QA-' + str(uuid.uuid4()) + '.app')
assert fixture.parent == Path('/Applications') and not fixture.exists()
(fixture / 'Contents/MacOS').mkdir(parents=True)
(fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.labrioche.permission-fixture',
    'CFBundleName': 'Disposable permission fixture', 'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'Fixture', 'CFBundleVersion': '1'}))
(fixture / 'Contents/StorageScope-QA-marker').write_text('Disposable CI fixture')
subprocess.run(['cp', '/usr/bin/true', str(fixture / 'Contents/MacOS/Fixture')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(fixture)], check=True)
subprocess.run(['sudo', 'chown', '-R', 'root:wheel', str(fixture)], check=True)
subprocess.run([str(binary), '--verify-application-removal'], env=dict(environment, STORAGESCOPE_QA_ROOT_APP=str(fixture)), check=True, timeout=45)
ui = Path(os.environ['RUNNER_TEMP']) / 'storagescope-packaged-ui'
subprocess.run([str(binary), '--verify-interface', str(ui)], env=environment, check=True, timeout=120)
subprocess.run([str(binary), '--verify-live-interface', str(ui)], env=environment, check=True, timeout=180)
assert len(list(ui.glob('*.png'))) >= 4
# An in-place second installation must preserve settings and not create another application.
preferences = Path.home() / 'Library/Application Support/StorageScope/package-test-preserved.txt'
preferences.parent.mkdir(parents=True, exist_ok=True)
preferences.write_text('disposable continuity fixture', encoding='utf-8')
subprocess.run(['sudo', 'installer', '-pkg', str(package), '-target', '/'], check=True, timeout=120)
assert preferences.read_text(encoding='utf-8') == 'disposable continuity fixture'
assert not list(Path('/Applications').glob('StorageScope *.app'))
subprocess.run([str(binary), '--verify-installation'], env=environment, check=True, timeout=35)
report.write_text(json.dumps({'version': info['CFBundleShortVersionString'], 'architecture': os.uname().machine,
    'os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
    'packageSha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'supportedArchitectures': architectures,
    'offlineInstalledStartup': True, 'packagedNativeScreenshots': len(list(ui.glob('*.png'))),
    'replacementPreservesData': True, 'appleDeveloperIDSigned': False, 'notarized': False}, indent=2), encoding='utf-8')
print(report.read_text())
