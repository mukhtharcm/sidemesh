#!/usr/bin/env python3
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import jwt
except ImportError:
    print("PyJWT is required. Run: python3 -m pip install pyjwt", file=sys.stderr)
    raise

BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "dev.sidemesh.mobile")
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
PRIVATE_KEY = base64.b64decode(os.environ["ASC_KEY_BASE64"]).decode("utf-8")
BUILD_VERSION = os.environ.get("BUILD_VERSION", "")
BUILD_NUMBER = os.environ.get("BUILD_NUMBER", "")


def parse_version(value, strict=True):
    parts = value.split(".")
    if strict and len(parts) != 3:
        raise ValueError(f"Version must use X.Y.Z, got {value!r}")
    if not strict and len(parts) not in (1, 2, 3):
        raise ValueError(f"Version must use one to three numeric segments, got {value!r}")
    if any(part != "0" and part.startswith("0") for part in parts):
        raise ValueError(f"Version segments must not use leading zeroes, got {value!r}")
    try:
        parsed = tuple(int(part) for part in parts)
    except ValueError as error:
        raise ValueError(f"Version must use numeric segments, got {value!r}") from error
    if any(part < 0 for part in parsed):
        raise ValueError(f"Version segments must be non-negative, got {value!r}")
    return parsed + (0,) * (3 - len(parsed))


def parse_build_number(value):
    if not value.isdigit() or value.startswith("0") or int(value) < 1:
        raise ValueError(f"Build number must be a positive integer without leading zeroes, got {value!r}")
    return int(value)


def compare_versions(left, right):
    if left == right:
        return 0
    return -1 if left < right else 1


def make_token():
    now = int(time.time())
    headers = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    token = jwt.encode(payload, PRIVATE_KEY, algorithm="ES256", headers=headers)
    return token.decode("utf-8") if isinstance(token, bytes) else token


def make_path(endpoint, params):
    return f"{endpoint}?{urllib.parse.urlencode(params)}"


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
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8")
        print(f"ASC API error: {error.code} {error.reason}", file=sys.stderr)
        print(body, file=sys.stderr)
        raise


def pages(path):
    next_path = path
    while next_path:
        response = api("GET", next_path)
        yield from response.get("data", [])
        next_url = response.get("links", {}).get("next")
        if not next_url:
            return
        parsed = urllib.parse.urlsplit(next_url)
        next_path = parsed.path.removeprefix("/v1")
        if parsed.query:
            next_path = f"{next_path}?{parsed.query}"


def find_app_id():
    path = make_path("/apps", {"filter[bundleId]": BUNDLE_ID, "limit": "1"})
    apps = api("GET", path).get("data", [])
    if not apps:
        raise RuntimeError(f"No App Store Connect app record exists for {BUNDLE_ID}.")
    return apps[0]["id"]


def parse_remote_version(value):
    try:
        return parse_version(value, strict=False)
    except ValueError:
        print(f"Skipping non-stable App Store Connect version {value!r}")
        return None


def known_marketing_versions(app_id):
    versions = set()

    prerelease_path = make_path(
        f"/apps/{app_id}/preReleaseVersions",
        {"limit": "200", "fields[preReleaseVersions]": "version"},
    )
    for prerelease in pages(prerelease_path):
        version = parse_remote_version(prerelease.get("attributes", {}).get("version", ""))
        if version is not None:
            versions.add(version)

    app_store_path = make_path(
        f"/apps/{app_id}/appStoreVersions",
        {"limit": "200", "fields[appStoreVersions]": "versionString,platform"},
    )
    for app_store_version in pages(app_store_path):
        attributes = app_store_version.get("attributes", {})
        if attributes.get("platform") not in (None, "IOS"):
            continue
        version = parse_remote_version(attributes.get("versionString", ""))
        if version is not None:
            versions.add(version)

    return versions


def uploaded_build_numbers(app_id, version):
    build_numbers = []
    builds_path = make_path(
        "/builds",
        {
            "filter[app]": app_id,
            "filter[preReleaseVersion.version]": version,
            "limit": "200",
            "fields[builds]": "version,processingState,uploadedDate",
        },
    )
    for build in pages(builds_path):
        attributes = build.get("attributes", {})
        if attributes.get("processingState") == "FAILED":
            continue
        build_value = str(attributes.get("version", ""))
        try:
            build_numbers.append(parse_build_number(build_value))
        except ValueError:
            print(f"Skipping non-integer App Store Connect build number {build_value!r}")
    return build_numbers


def write_outputs(build_number):
    gh_output = os.environ.get("GITHUB_OUTPUT", "")
    if gh_output:
        with open(gh_output, "a", encoding="utf-8") as output:
            output.write(f"build_number={build_number}\n")


def main():
    if not BUILD_VERSION or not BUILD_NUMBER:
        raise RuntimeError("BUILD_VERSION and BUILD_NUMBER must be set.")

    current_version = parse_version(BUILD_VERSION)
    current_build_number = parse_build_number(BUILD_NUMBER)
    app_id = find_app_id()

    versions = known_marketing_versions(app_id)
    latest_version = max(versions) if versions else None
    if latest_version is not None and compare_versions(current_version, latest_version) < 0:
        latest = ".".join(str(part) for part in latest_version)
        raise RuntimeError(
            f"Refusing to upload TestFlight version {BUILD_VERSION} because App Store Connect already has {latest}."
        )

    build_numbers = uploaded_build_numbers(app_id, BUILD_VERSION)
    latest_build_number = max(build_numbers) if build_numbers else None
    if latest_build_number is not None and current_build_number <= latest_build_number:
        raise RuntimeError(
            f"Refusing to upload TestFlight {BUILD_VERSION} ({BUILD_NUMBER}); "
            f"latest existing build for this version is {latest_build_number}."
        )

    print(f"Validated TestFlight version {BUILD_VERSION} ({BUILD_NUMBER}) for {BUNDLE_ID}")
    write_outputs(BUILD_NUMBER)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)
