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
    contact_first = os.environ.get("SIDEMESH_REVIEW_CONTACT_FIRST", "")
    contact_last = os.environ.get("SIDEMESH_REVIEW_CONTACT_LAST", "")
    contact_email = os.environ.get("SIDEMESH_REVIEW_CONTACT_EMAIL", "")
    contact_phone = os.environ.get("SIDEMESH_REVIEW_CONTACT_PHONE", "")
    demo_account = os.environ.get("SIDEMESH_REVIEW_DEMO_ACCOUNT", "")
    demo_password = os.environ.get("SIDEMESH_REVIEW_DEMO_PASSWORD", "")
    notes = os.environ.get("SIDEMESH_REVIEW_NOTES", "")

    if not contact_email:
        print("No review contact email configured; skipping review details update")
        return 0

    apps = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    app_id = apps[0]["id"]

    # Get or create app review detail
    details = api("GET", f"/apps/{app_id}/appReviewDetail")["data"]
    if details:
        detail_id = details[0]["id"]
    else:
        detail_resp = api("POST", "/appReviewDetails", {"data": {"type": "appReviewDetails", "attributes": {}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        detail_id = detail_resp["data"]["id"]

    attrs = {}
    if contact_first:
        attrs["contactFirstName"] = contact_first
    if contact_last:
        attrs["contactLastName"] = contact_last
    if contact_email:
        attrs["contactEmail"] = contact_email
    if contact_phone:
        attrs["contactPhone"] = contact_phone
    if demo_account:
        attrs["demoAccountName"] = demo_account
    if demo_password:
        attrs["demoAccountPassword"] = demo_password
    if notes:
        attrs["notes"] = notes

    if not attrs:
        print("No review details to update; skipping")
        return 0

    api("PATCH", f"/appReviewDetails/{detail_id}", {"data": {"type": "appReviewDetails", "id": detail_id, "attributes": attrs}})
    print("App review details updated")
    return 0

if __name__ == "__main__":
    sys.exit(main())
