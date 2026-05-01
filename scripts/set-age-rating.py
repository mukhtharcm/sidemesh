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
    apps = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    app_id = apps[0]["id"]

    try:
        declarations = api("GET", f"/apps/{app_id}/ageRatingDeclaration")["data"]
        if declarations:
            decl_id = declarations[0]["id"]
        else:
            decl_resp = api("POST", "/ageRatingDeclarations", {"data": {"type": "ageRatingDeclarations", "attributes": {}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
            decl_id = decl_resp["data"]["id"]
    except urllib.error.HTTPError as e:
        if e.code == 404:
            decl_resp = api("POST", "/ageRatingDeclarations", {"data": {"type": "ageRatingDeclarations", "attributes": {}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
            decl_id = decl_resp["data"]["id"]
        else:
            raise

    attrs = {
        "alcoholTobaccoOrDrugUseOrReferences": "NONE",
        "gamblingSimulated": "NONE",
        "medicalOrTreatmentInformation": "NONE",
        "profanityOrCrudeHumor": "NONE",
        "sexualContentGraphicAndNudity": "NONE",
        "sexualContentOrSuggestive": "NONE",
        "horrorOrFearThemes": "NONE",
        "matureOrSuggestiveThemes": "NONE",
        "violenceCartoonOrFantasy": "NONE",
        "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        "violenceRealistic": "NONE",
        "unrestrictedWebAccess": True,
        "gambling": False,
        "kidsAgeBand": None,
    }

    api("PATCH", f"/ageRatingDeclarations/{decl_id}", {"data": {"type": "ageRatingDeclarations", "id": decl_id, "attributes": attrs}})
    print("Age rating declaration updated")
    return 0

if __name__ == "__main__":
    sys.exit(main())
