"""Capture Instruments against the installed UI in an isolated CI session."""
import json
import os
from pathlib import Path
import subprocess
import time

assert os.environ.get('GITHUB_ACTIONS') == 'true'
root = Path(os.environ['RUNNER_TEMP'])
output = root / 'storagescope-instruments'
output.mkdir()
binary = Path('/Applications/StorageScope.app/Contents/MacOS/StorageScope')
# A profiler can retain process metadata: never inherit signing keys or CI tokens.
allowed = ['PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', '__CF_USER_TEXT_ENCODING']
environment = {key: os.environ[key] for key in allowed if key in os.environ}
environment.update(GITHUB_ACTIONS='true', RUNNER_TEMP=str(root), STORAGESCOPE_ISOLATED_VALIDATION='1',
    STORAGESCOPE_PROFILE_EXPLORER='1',
    HTTP_PROXY='http://127.0.0.1:9', HTTPS_PROXY='http://127.0.0.1:9', ALL_PROXY='http://127.0.0.1:9')
record = {'template': 'Time Profiler', 'version': '3.6.0', 'captured': False, 'frameRateMeasured': False}
with (output / 'application.log').open('w') as handle:
    process = subprocess.Popen([str(binary), '--verify-live-interface', str(output / 'ui')], env=environment, stdout=handle, stderr=handle)
    try:
        deadline = time.monotonic() + 60
        while not (output / 'ui/profile-ready').exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.1)
        assert process.poll() is None, 'The profiling fixture exited before Instruments attached'
        sample = subprocess.run(['/usr/bin/sample', str(process.pid), '8', '1', '-file', str(output / 'main-thread-sample.log')],
            env=environment, text=True, capture_output=True, timeout=20)
        (output / 'sample.log').write_text(sample.stdout + sample.stderr)
        result = subprocess.run(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--time-limit', '12s',
            '--output', str(output / 'StorageScope.trace'), '--attach', str(process.pid)], env=environment, text=True, capture_output=True, timeout=70)
        (output / 'instruments.log').write_text(result.stdout + result.stderr)
        record.update(captured=result.returncode == 0 and (output / 'StorageScope.trace').exists(), exitCode=result.returncode)
    except (OSError, AssertionError, subprocess.TimeoutExpired) as error:
        record['limitation'] = str(error)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
(output / 'result.json').write_text(json.dumps(record, indent=2))
print(json.dumps(record))
