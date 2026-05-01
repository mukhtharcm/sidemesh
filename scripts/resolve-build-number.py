#!/usr/bin/env python3
import base64, json, os, urllib.request, urllib.error, sys

BUNDLE_ID = 'dev.sidemesh.mobile'
KEY_ID = os.environ['ASC_KEY_ID']
ISSUER_ID = os.environ['ASC_ISSUER_ID']
PRIVATE_KEY = base64.b64decode(os.environ['ASC_KEY_BASE64']).decode('utf-8')
VERSION = os.environ.get('BUILD_VERSION', '')
BUILD_NUMBER = os.environ.get('BUILD_NUMBER', '')

try:
    import jwt
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pyjwt", "--quiet"])
    import jwt

def make_token():
    now = int(__import__("time").time())
    headers = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, PRIVATE_KEY, algorithm="ES256", headers=headers)

def api(method, path, data=None):
    url = f"https://api.appstoreconnect.apple.com/v1{path}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {make_token()}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(data).encode("utf-8")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))

def main():
    if not VERSION or not BUILD_NUMBER:
        print("VERSION or BUILD_NUMBER not set; skipping conflict check")
        return 0
    apps = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    app_id = apps[0]["id"]
    builds = api("GET", f"/builds?filter[app]={app_id}\u0026filter[version]={VERSION}\u0026filter[buildNumber]={BUILD_NUMBER}\u0026limit=1")["data"]
    if builds:
        print(f"Build {VERSION} ({BUILD_NUMBER}) already exists on ASC.")
        all_builds = api("GET", f"/builds?filter[app]={app_id}\u0026filter[version]={VERSION}\u0026limit=200")["data"]
        existing = {int(b["attributes"]["buildNumber"]) for b in all_builds}
        next_num = int(BUILD_NUMBER) + 1
        while next_num in existing:
            next_num += 1
        print(f"Resolved next available build number: {next_num}")
        gh_output = os.environ.get("GITHUB_OUTPUT", "")
        if gh_output:
            with open(gh_output, "a") as f:
                f.write(f"build_number={next_num}\\n")
        print(f"::set-output name=build_number::{next_num}")
        return 0
    print(f"Build number {BUILD_NUMBER} is available for version {VERSION}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
