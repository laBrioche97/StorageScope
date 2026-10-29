"""Exercise Sparkle with signed local feeds and the actual packaged application.

No real user installation is touched. The private Ed25519 seed stays in the process
environment/stdin; fixture packages, logs and reports contain public metadata only.
"""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import socket
import threading
import time
import urllib.request

assert os.environ.get('GITHUB_ACTIONS') == 'true'
root = Path(os.environ['RUNNER_TEMP']) / 'storagescope-update-validation'
root.mkdir(exist_ok=True)
assets = Path('release-assets').resolve()
signer = Path(os.environ['STORAGESCOPE_SPARKLE_SIGNER']).resolve() if os.environ.get('STORAGESCOPE_SPARKLE_SIGNER') else next(Path('.build').rglob('sign_update')).resolve()
secret = os.environ['SPARKLE_PRIVATE_KEY'] + '\n'
candidate_info = plistlib.loads(Path('dist/StorageScope.app/Contents/Info.plist').read_bytes())
version = candidate_info['CFBundleShortVersionString']
build = candidate_info['CFBundleVersion']
previous_build = str(int(build) - 1)
# Exercise the update with the actual previously distributed executable too,
# rather than only changing the candidate's version metadata.
previous_app = root / 'published-previous' / 'StorageScope.app'
previous_release = {
    '3.5.1': ('3.5.0', 'StorageScope-universal.zip', 'ce16eb706251d48906b545704648f50a92c644a98f6c1fcfcd674179be16f5c5'),
    '3.6.0': ('3.5.1', 'StorageScope-arm64.zip', '795349e7a1af853a154dc5d652c3effdaef440431039837018f7dd8e6c700c8a'),
}.get(version)
if previous_release:
    previous_version, previous_filename, previous_sha = previous_release
    url = 'https://github.com/laBrioche97/StorageScope/releases/download/v' + previous_version + '/' + previous_filename
    with urllib.request.urlopen(url, timeout=90) as response:
        previous_archive = response.read(20_000_001)
    assert len(previous_archive) <= 20_000_000
    assert hashlib.sha256(previous_archive).hexdigest() == previous_sha
    previous_zip = root / ('published-' + previous_version + '.zip')
    previous_zip.write_bytes(previous_archive)
    subprocess.run(['ditto', '-x', '-k', str(previous_zip), str(previous_app.parent)], check=True)
    previous_info = plistlib.loads((previous_app / 'Contents/Info.plist').read_bytes())
    assert previous_info['CFBundleShortVersionString'] == previous_version and previous_info['CFBundleVersion'] == previous_build
    assert previous_info['SUPublicEDKey'] == candidate_info['SUPublicEDKey']
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(previous_app)], check=True)

def sign(path, verify=False, signature=None):
    args = [str(signer), '--ed-key-file', '-'] + (['--verify'] if verify else []) + [str(path)]
    if signature: args.append(signature)
    return subprocess.run(args, input=secret, text=True, capture_output=True)

archive = assets / 'StorageScope-arm64.zip'
result = sign(archive)
assert result.returncode == 0, 'Sparkle could not sign the test archive'
signature = re.search(r'edSignature="([^"]+)"', result.stdout)[1]
assert sign(archive, True, signature).returncode == 0
assert sign(assets / 'appcast.xml', True).returncode == 0
shutil.copy2(archive, root / 'update.zip')
shutil.copy2(archive, root / 'altered.zip')
with (root / 'altered.zip').open('ab') as handle: handle.write(b'altered')
assert sign(root / 'altered.zip', True, signature).returncode != 0, 'An altered update must be rejected'

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
    def copyfile(self, source, output):
        if self.path.endswith('/interrupted.zip'):
            output.write(source.read(65_536)); output.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if self.path.endswith('/slow.zip'):
            try:
                while chunk := source.read(65_536):
                    output.write(chunk); output.flush(); time.sleep(.2)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        super().copyfile(source, output)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'

def feed(name, filename, edsignature):
    path = root / name
    path.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated validation</title>
<item><title>StorageScope {version}</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="{base}/{filename}" sparkle:edSignature="{edsignature}" length="{(root / filename).stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>''', encoding='utf-8')
    assert sign(path).returncode == 0
    return path

feed('valid.xml', 'update.zip', signature)
feed('altered.xml', 'altered.zip', signature)
feed('invalid-signature.xml', 'update.zip', 'A' * 86 + '==')
for filename in ['interrupted.zip', 'slow.zip']: shutil.copy2(archive, root / filename)
feed('interrupted.xml', 'interrupted.zip', signature)
feed('cancelled.xml', 'slow.zip', signature)
feed('read-only.xml', 'update.zip', signature)
unsigned = root / 'unsigned.xml'; unsigned.write_bytes((root / 'valid.xml').read_bytes().replace(b'Isolated validation', b'Tampered metadata'))

def launch_scenario(name, should_succeed):
    folder = root / name; folder.mkdir(exist_ok=True)
    app = folder / 'StorageScope.app'
    from_published = name == 'valid' and previous_app.exists()
    subprocess.run(['ditto', str(previous_app) if from_published else 'dist/StorageScope.app', str(app)], check=True)
    info_file = app / 'Contents/Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    info.update(CFBundleVersion=previous_build, CFBundleShortVersionString=previous_version if from_published else '0.0.1',
        StorageScopeValidationFeedURL=base + '/' + name + '.xml',
        NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    info_file.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    mount = None
    if name == 'read-only':
        image = root / 'read-only.dmg'
        subprocess.run(['hdiutil', 'create', '-srcfolder', str(folder), '-volname', 'StorageScopeValidation', '-format', 'UDRO', str(image)], check=True, capture_output=True)
        mount = root / 'read-only-mounted'; mount.mkdir(exist_ok=True)
        subprocess.run(['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', str(mount), str(image)], check=True, capture_output=True)
        app = mount / 'StorageScope.app'; info_file = app / 'Contents/Info.plist'
    events = folder / 'events.log'
    environment = dict(os.environ, STORAGESCOPE_ISOLATED_VALIDATION='1', STORAGESCOPE_UPDATE_VALIDATION_RESULT=str(events))
    if name == 'cancelled': environment['STORAGESCOPE_UPDATE_VALIDATION_CANCEL'] = '1'
    output = (folder / 'process.log').open('w')
    process = subprocess.Popen([str(app / 'Contents/MacOS/StorageScope')], env=environment, stdout=output, stderr=output)
    try:
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            content = events.read_text() if events.exists() else ''
            current = plistlib.loads(info_file.read_bytes())['CFBundleVersion'] if info_file.exists() else ''
            if should_succeed and current == build:
                process.wait(timeout=30)
                subprocess.run([str(app / 'Contents/MacOS/StorageScope'), '--verify-installation'], check=True, timeout=35, stdout=output, stderr=output)
                assert 'accepted' in content and 'ready' in content
                return {'installedVersion':version, 'realSparkleReplacement':True, 'newVersionStarts':True,
                    'previousPublishedExecutable': previous_version if from_published else None}
            if not should_succeed and ('failed:' in content or name == 'cancelled' and 'cancelled' in content):
                assert current == previous_build, 'Failed verification must leave the old application in place'
                return {'rejected':True, 'previousVersionPreserved':True}
            exit_code = process.poll()
            # Sparkle may quit the host normally before its external installer
            # atomically swaps the bundle. Keep observing that verified handoff;
            # abnormal or premature exits still fail, as does a missing replacement.
            expected_handoff = should_succeed and exit_code == 0 and 'ready' in content
            if exit_code is not None and not expected_handoff:
                raise AssertionError(f'{name}: process exited before expected outcome; {content}; { (folder / "process.log").read_text()[-4000:] }')
            time.sleep(.2)
        subprocess.run(['sample', str(process.pid), '1', '-file', str(folder / 'sample.log')], check=False, capture_output=True, timeout=10)
        raise AssertionError(f'{name}: timed out; events={events.read_text() if events.exists() else "none"}; log={(folder / "process.log").read_text()[-5000:]}')
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=15)
        # Only terminate the disposable fixture's relaunched process.
        subprocess.run(['pkill', '-f', str(app / 'Contents/MacOS/StorageScope')], check=False)
        if mount: subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True)
        output.close()

results = {}
try:
    for scenario in ['unsigned', 'invalid-signature', 'altered', 'interrupted', 'cancelled', 'read-only']:
        results[scenario] = launch_scenario(scenario, False)
        (root / 'results.json').write_text(json.dumps(results, indent=2))
    results['valid'] = launch_scenario('valid', True)
finally: server.shutdown()
(root / 'results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
