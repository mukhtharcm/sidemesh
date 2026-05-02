#!/usr/bin/env python3
import base64, json, os, urllib.request, urllib.error, sys

BUNDLE_ID = 'dev.sidemesh.mobile'
KEY_ID = os.environ['ASC_KEY_ID']
ISSUER_ID = os.environ['ASC_ISSUER_ID']
PRIVATE_KEY = base64.b64decode(os.environ['ASC_KEY_BASE64']).decode('utf-8')
KEEP_COUNT = int(os.environ.get('KEEP_BUILD_COUNT', '5'))
DRY_RUN = os.environ.get('DRY_RUN', '') == 'true'

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
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        print(f"ASC API error: {e.code} {e.reason}", file=sys.stderr)
        print(body, file=sys.stderr)
        raise

def main():
    apps = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    app_id = apps[0]["id"]

    builds = api("GET", f"/apps/{app_id}/builds?sort=-uploadedDate\u0026limit=200")["data"]
    if not builds:
        print("No builds found")
        return 0

    print(f"Found {len(builds)} builds")

    for i, build in enumerate(builds):
        attrs = build["attributes"]
        version = attrs.get("version", "")
        build_number = attrs.get("buildNumber", "")
        uploaded = attrs.get("uploadedDate", "")
        expired = attrs.get("expired", False)
        processing = attrs.get("processingState", "")
        print(f"  {i+1}. v{version} ({build_number}) - {processing} - uploaded {uploaded[:10]}{\" [EXPIRED]\" if expired else \"\"}")

    to_expire = builds[KEEP_COUNT:]
    if not to_expire:
        print(f"\nNo builds to expire (keeping {KEEP_COUNT} most recent)")
        return 0

    print(f"\nWill expire {len(to_expire)} builds, keeping {KEEP_COUNT} most recent:")
    for build in to_expire:
        attrs = build["attributes"]
        print(f"  - v{attrs.get(\"version\", \"\")} ({attrs.get(\"buildNumber\", \"\")})")

    if DRY_RUN:
        print("\nDRY RUN - no changes made")
        return 0

    expired_count = 0
    for build in to_expire:
        build_id = build["id"]
        attrs = build["attributes"]
        version = attrs.get("version", "")
        build_number = attrs.get("buildNumber", "")
        if attrs.get("expired", False):
            print(f"  Already expired: v{version} ({build_number})")
            continue
        try:
            api("PATCH", f"/builds/{build_id}", {"data": {"type": "builds", "id": build_id, "attributes": {"expired": True}}})
            print(f"  Expired: v{version} ({build_number})")
            expired_count += 1
        except urllib.error.HTTPError as e:
            print(f"  Failed to expire v{version} ({build_number}): {e.code}")

    print(f"\nExpired {expired_count} builds")
    return 0

if __name__ == '__main__':
    sys.exit(main())
