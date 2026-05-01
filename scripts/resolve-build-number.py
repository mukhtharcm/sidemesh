#!/usr/bin/env python3
import os, sys

VERSION = os.environ.get('BUILD_VERSION', '')
BUILD_NUMBER = os.environ.get('BUILD_NUMBER', '')

def main():
    if not VERSION or not BUILD_NUMBER:
        print("VERSION or BUILD_NUMBER not set; skipping")
        return 0
    print(f"Using build {VERSION} ({BUILD_NUMBER})")
    gh_output = os.environ.get("GITHUB_OUTPUT", "")
    if gh_output:
        with open(gh_output, "a") as f:
            f.write(f"build_number={BUILD_NUMBER}\n")
    print(f"::set-output name=build_number::{BUILD_NUMBER}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
