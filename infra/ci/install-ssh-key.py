#!/usr/bin/env python3
"""Write the CI SSH private key where ssh will look for it.

Not a one-line cp, for two reasons.

A key pasted into a GitLab File variable from a Windows machine carries CRLF
line endings, and OpenSSH rejects the whole file with "error in libcrypto" --
a message about the crypto library, not about line endings, which sends people
looking in the wrong place entirely. A key missing its trailing newline fails
the same way.

Doing it in a script rather than inline also keeps the carriage return out of
the pipeline definition. Escaping one through YAML, then the shell, then a
command has gone wrong twice in this project already: see
docs/learning/18-who-parses-it-first.md.
"""
import os
import stat
import sys

source = os.environ.get("ANSIBLE_SSH_PRIVATE_KEY")
if not source:
    sys.exit("ANSIBLE_SSH_PRIVATE_KEY is not set. It must be a File type variable.")
if not os.path.exists(source):
    sys.exit(
        f"ANSIBLE_SSH_PRIVATE_KEY points at {source!r}, which does not exist. "
        "A Variable type holds the key itself; a File type holds a path to it, "
        "which is what ssh needs."
    )

destination = os.path.expanduser("~/.ssh/id_ed25519")
os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)

data = open(source, "rb").read()
had_crlf = b"\r\n" in data
data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
missing_newline = not data.endswith(b"\n")
if missing_newline:
    data += b"\n"

open(destination, "wb").write(data)
os.chmod(destination, stat.S_IRUSR | stat.S_IWUSR)

print(f"Wrote {len(data)} bytes to {destination}")
if had_crlf:
    print("Converted CRLF line endings. The variable was saved from a Windows editor.")
if missing_newline:
    print("Added the missing trailing newline.")
