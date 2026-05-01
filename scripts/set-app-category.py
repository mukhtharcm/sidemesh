#!/usr/bin/env python3
import base64, json, os, urllib.request, urllib.error, sys

BUNDLE_ID = "dev.sidemesh.mobile"
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
PRIVATE_KEY = base64.b64decode(os.environ["ASC_KEY_BASE64"]).decode("utf-8")

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
        if e.code == 409:
            print(f"ASC 409 Conflict (already exists): {method} {path}")
            return {}
        raise

def main():
    primary_category = os.environ.get("SIDEMESH_PRIMARY_CATEGORY", "")
    secondary_category = os.environ.get("SIDEMESH_SECONDARY_CATEGORY", "")

    if not primary_category:
        print("No primary category configured; skipping category update")
        return 0

    apps = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    app_id = apps[0]["id"]

    # Find category IDs
    categories = api("GET", "/appCategories?limit=200")["data"]
    primary_id = None
    secondary_id = None
    for cat in categories:
        attrs = cat.get("attributes", {})
        name = attrs.get("name", "").lower()
        if name == primary_category.lower():
            primary_id = cat["id"]
        if secondary_category and name == secondary_category.lower():
            secondary_id = cat["id"]

    if not primary_id:
        print(f"Primary category "{primary_category}" not found on ASC")
        return 0

    # Get app info
    infos = api("GET", f"/apps/{app_id}/appInfos")["data"]
    if not infos:
        print("No app info found; skipping")
        return 0

    info_id = infos[0]["id"]
    attrs = {"primaryCategoryId": primary_id}
    if secondary_id:
        attrs["secondaryCategoryId"] = secondary_id

    api("PATCH", f"/appInfos/{info_id}", {"data": {"type": "appInfos", "id": info_id, "attributes": attrs}})
    print(f"App categories updated: primary={primary_category}, secondary={secondary_category or "none"}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
