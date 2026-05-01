#!/usr/bin/env python3
import os, re, subprocess, sys

def get_commits():
    try:
        tag = subprocess.check_output(["git", "describe", "--tags", "--abbrev=0"], text=True).strip()
    except subprocess.CalledProcessError:
        tag = ""
    cmd = ["git", "log", f"{tag}..HEAD", "--oneline"] if tag else ["git", "log", "--oneline", "-30"]
    try:
        return [c.strip() for c in subprocess.check_output(cmd, text=True).strip().splitlines() if c.strip()]
    except subprocess.CalledProcessError:
        return []

def categorize(commits):
    cats = {"New": [], "Improved": [], "Fixed": [], "Other": []}
    for c in commits:
        msg = re.sub(r"^[a-f0-9]+\s+", "", c)
        msg = re.sub(r"\s*\(#[0-9]+\)$", "", msg)
        if msg.startswith("Merge pull request") or msg.startswith("Merge branch"):
            continue
        l = msg.lower()
        if l.startswith(("feat", "add", "introduce")):
            cats["New"].append(msg)
        elif l.startswith(("fix", "bug", "revert", "resolve")):
            cats["Fixed"].append(msg)
        elif l.startswith(("refactor", "improve", "optimize", "enhance", "update", "polish", "clean", "tighten", "redesign")):
            cats["Improved"].append(msg)
        else:
            cats["Other"].append(msg)
    return cats

def format_notes(cats):
    lines = []
    for title, items in cats.items():
        if not items: continue
        lines.append(f"## {title}")
        for item in items:
            item = item[0].upper() + item[1:] if item else item
            lines.append(f"- {item}")
        lines.append("")
    return '\n'.join(lines).strip()

def main():
    commits = get_commits()
    notes = format_notes(categorize(commits)) if commits else "Maintenance and stability improvements."
    with open("release-notes.txt", "w") as f:
        f.write(notes)
    summary = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if summary:
        with open(summary, "a") as f:
            f.write("\n### Release Notes\n\n" + notes + "\n\n")
    print(notes)
    return 0

if __name__ == '__main__':
    sys.exit(main())
