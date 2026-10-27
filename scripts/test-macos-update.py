"""Exercise Sparkle with signed local feeds and the actual packaged application.

No real user installation is touched. The private Ed25519 seed stays in the process
environment/stdin; fixture packages, logs and reports contain public metadata only.
"""
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import threading
import time

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

def sign(path, verify=False, signature=None):
    args = [str(signer), '--ed-key-file', '-'] + (['--verify'] if verify else []) + [str(path)]
    if signature: args.append(signature)
    return subprocess.run(args, input=secret, text=True, capture_output=True)

archive = assets / 'StorageScope-universal.zip'
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

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'

def feed(name, filename, edsignature):
    path = root / name
    path.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated validation</title>
<item><title>StorageScope {version}</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{base}/{filename}" sparkle:edSignature="{edsignature}" length="{(root / filename).stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>''', encoding='utf-8')
    assert sign(path).returncode == 0
    return path

feed('valid.xml', 'update.zip', signature)
feed('altered.xml', 'altered.zip', signature)
feed('invalid-signature.xml', 'update.zip', 'A' * 86 + '==')
unsigned = root / 'unsigned.xml'; unsigned.write_bytes((root / 'valid.xml').read_bytes().replace(b'Isolated validation', b'Tampered metadata'))

def launch_scenario(name, should_succeed):
    folder = root / name; folder.mkdir(exist_ok=True)
    app = folder / 'StorageScope.app'
    subprocess.run(['ditto', 'dist/StorageScope.app', str(app)], check=True)
    info_file = app / 'Contents/Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    info.update(CFBundleVersion=previous_build, CFBundleShortVersionString='0.0.1',
        StorageScopeValidationFeedURL=base + '/' + name + '.xml',
        NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    info_file.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    events = folder / 'events.log'
    environment = dict(os.environ, STORAGESCOPE_ISOLATED_VALIDATION='1', STORAGESCOPE_UPDATE_VALIDATION_RESULT=str(events))
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
                return {'installedVersion':version, 'realSparkleReplacement':True, 'newVersionStarts':True}
            if not should_succeed and 'failed:' in content:
                assert current == previous_build, 'Failed verification must leave the old application in place'
                return {'rejected':True, 'previousVersionPreserved':True}
            if process.poll() is not None:
                raise AssertionError(f'{name}: process exited before expected outcome; {content}; { (folder / "process.log").read_text()[-4000:] }')
            time.sleep(.2)
        raise AssertionError(f'{name}: timed out; events={events.read_text() if events.exists() else "none"}; log={(folder / "process.log").read_text()[-5000:]}')
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=15)
        # Only terminate the disposable fixture's relaunched process.
        subprocess.run(['pkill', '-f', str(app / 'Contents/MacOS/StorageScope')], check=False)
        output.close()

results = {}
try:
    for scenario in ['unsigned', 'invalid-signature', 'altered']:
        results[scenario] = launch_scenario(scenario, False)
    results['valid'] = launch_scenario('valid', True)
finally: server.shutdown()
(root / 'results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
