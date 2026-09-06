#!/usr/bin/env python3
"""Run with python3 scripts/speedflight-test.py. No signing or network calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'scripts').mkdir()
    (root / 'apps/mobile').mkdir(parents=True)
    (root / 'bin').mkdir()
    shutil.copyfile(Path(__file__).with_name('speedflight.sh'), root / 'scripts/speedflight.sh')
    key = root / 'key.p8'
    key.touch()
    mock = root / 'bin/mock'
    mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open('calls.jsonl', 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name == 'git':
    if args[0] == 'status': print(os.environ.get('MOCK_DIRTY', ''))
    elif args[:2] == ['remote', 'get-url']: print('git@example.com:owner/repo.git')
    elif '--abbrev-ref' in args: print('codex/speedflight')
    elif args[0] == 'rev-parse': print('a' * 40)
elif name == 'xcodebuild' and '-exportArchive' in args:
    output = pathlib.Path(args[args.index('-exportPath') + 1])
    output.mkdir(parents=True)
    (output / 'app.ipa').write_bytes(b'test')
elif name == 'curl' and 'POST' in args:
    print(json.dumps({'buildId':'test-build', 'pageUrl':'https://speedflight.dev/a/test-page'}))
''')
    mock.chmod(0o755)
    for name in ('git', 'flutter', 'xcodebuild', 'curl'):
        (root / 'bin' / name).symlink_to(mock)
    env = {**os.environ, 'PATH': f'{root}/bin:{os.environ["PATH"]}',
           'CI': '', 'ASC_KEY_ID': 'test', 'ASC_ISSUER_ID': 'test',
           'ASC_PRIVATE_KEY_PATH': str(key), 'SPEEDFLIGHT_TEAM_ID': 'test',
           'SPEEDFLIGHT_SECRET': 'a' * 48, 'SPEEDFLIGHT_AUTHOR': 'test',
           'SPEEDFLIGHT_DEEP_LINK': 'sidemesh://', 'FLUTTER_BIN': 'flutter'}
    command = ['bash', 'scripts/speedflight.sh', 'Preview', 'Test sessions']
    result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().endswith('Build page: https://speedflight.dev/a/test-page')
    calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
    archive = next(call for call in calls if call[0] == 'xcodebuild' and 'archive' in call)
    assert '-workspace' in archive and 'Release-prod' in archive
    assert 'CODE_SIGN_STYLE=Automatic' in archive and 'PROVISIONING_PROFILE_SPECIFIER=' in archive
    assert 'generic/platform=iOS' in archive
    assert any(call[0] == 'curl' and 'PUT' in call for call in calls)
    (root / 'calls.jsonl').unlink()
    result = subprocess.run(command, cwd=root, env={**env, 'MOCK_DIRTY': ' M file'}, capture_output=True, text=True)
    assert result.returncode != 0 and 'working tree is dirty' in result.stderr
    assert 'curl' not in (root / 'calls.jsonl').read_text()
print('Speedflight checks passed.')
