#!/usr/bin/env python3
import base64, json, os, time, urllib.request, urllib.error, sys

BUNDLE_ID = 'dev.sidemesh.mobile'
KEY_ID = os.environ['ASC_KEY_ID']
ISSUER_ID = os.environ['ASC_ISSUER_ID']
PRIVATE_KEY = base64.b64decode(os.environ['ASC_KEY_BASE64']).decode('utf-8')
BUILD_VERSION = os.environ.get('BUILD_VERSION', '')
BUILD_NUMBER = os.environ.get('BUILD_NUMBER', '')

try:
    import jwt
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pyjwt', '--quiet'])
    import jwt

def make_token():
    now = int(time.time())
    headers = {'alg': 'ES256', 'kid': KEY_ID, 'typ': 'JWT'}
    payload = {'iss': ISSUER_ID, 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'}
    return jwt.encode(payload, PRIVATE_KEY, algorithm='ES256', headers=headers)

def api(method, path, data=None):
    url = f'https://api.appstoreconnect.apple.com/v1{path}'
    req = urllib.request.Request(url, method=method)
    req.add_header('Authorization', f'Bearer {make_token()}')
    req.add_header('Accept', 'application/json')
    if data is not None:
        req.add_header('Content-Type', 'application/json')
        req.data = json.dumps(data).encode('utf-8')
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        print(f'ASC API error: {e.code} {e.reason}', file=sys.stderr)
        print(body, file=sys.stderr)
        raise

def main():
    apps = api('GET', f'/apps?filter[bundleId]={BUNDLE_ID}')['data']
    app_id = apps[0]['id']

    start = time.time()
    timeout = 600
    build_id = None
    while time.time() - start < timeout:
        builds = api('GET', f'/builds?filter[app]={app_id}&filter[version]={BUILD_VERSION}&filter[buildNumber]={BUILD_NUMBER}&limit=1')['data']
        if builds:
            state = builds[0].get('attributes', {}).get('processingState', '')
            print(f'Build processing state: {state}')
            if state == 'VALID':
                build_id = builds[0]['id']
                break
            if state == 'FAILED':
                raise RuntimeError('Build processing failed')
        time.sleep(20)

    if not build_id:
        print('Timeout waiting for build processing; skipping beta group assignment')
        return 0

    print(f'Build ID: {build_id}')

    groups = api('GET', '/betaGroups?limit=200')['data']
    assigned = False
    for group in groups:
        attrs = group.get('attributes', {})
        name = attrs.get('name', '')
        is_internal = attrs.get('isInternalGroup', False)
        if is_internal or 'internal' in name.lower():
            group_id = group['id']
            try:
                api('POST', f'/betaGroups/{group_id}/relationships/builds', {'data': [{'type': 'builds', 'id': build_id}]})
                print(f'Added build to beta group: {name}')
                assigned = True
            except urllib.error.HTTPError as e:
                if e.code == 409:
                    print(f'Build already in beta group: {name}')
                    assigned = True
                else:
                    raise

    if not assigned:
        print('No internal beta groups found')
    return 0

if __name__ == '__main__':
    sys.exit(main())
