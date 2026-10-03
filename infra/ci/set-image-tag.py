#!/usr/bin/env python3
"""Rewrite the image.tag parameter in an Argo CD Application.

Line based rather than a YAML round trip, on purpose: a YAML library would
reformat the file and strip every comment, and those comments are most of what
makes the file understandable. This changes one value and leaves the rest of
the file byte for byte identical.

Usage:
    set-image-tag.py gitops/apps/staging/fastapi-app.yaml 9465cd15

Exits 0 and reports when the tag is already correct, so re-running a pipeline
is harmless.
"""
import pathlib
import sys

if len(sys.argv) != 3:
    sys.exit("usage: set-image-tag.py <application.yaml> <tag>")

path = pathlib.Path(sys.argv[1])
tag = sys.argv[2].strip()

if not tag:
    sys.exit("Refusing to write an empty tag.")
if not path.exists():
    sys.exit(f"{path} does not exist.")

lines = path.read_text(encoding="utf-8").splitlines()

# Find "- name: image.tag", then the "value:" belonging to it. Anchored on the
# name so a different parameter with the same value cannot be hit by accident.
target = None
for i, line in enumerate(lines):
    if line.strip() == "- name: image.tag":
        for j in range(i + 1, min(i + 5, len(lines))):
            if lines[j].strip().startswith("value:"):
                target = j
                break
        break

if target is None:
    sys.exit(
        f"No 'image.tag' parameter with a following 'value:' found in {path}. "
        "The Application layout has changed and this script needs updating "
        "rather than silently doing nothing."
    )

indent = len(lines[target]) - len(lines[target].lstrip())
previous = lines[target].strip()
replacement = " " * indent + f'value: "{tag}"'

if lines[target] == replacement:
    print(f"image.tag is already {tag} in {path}. Nothing to do.")
    sys.exit(0)

lines[target] = replacement
path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
print(f'{path}: {previous} -> value: "{tag}"')
