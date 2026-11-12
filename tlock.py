"""Optional true time-lock, via drand's tlock (https://github.com/drand/tlock).

By default lubdub is a promise, not a padlock: letters sit in plaintext in
data/letters.json, and anyone with a shell on this machine can read them
early. For most households that is the right design — see the README.

With tlock enabled, each letter is encrypted the moment it arrives, to a
future round of the drand randomness beacon. Until that round is published,
the decryption key exists nowhere — not on this machine, not anywhere. The
plaintext is dropped immediately:

- even the writer can't re-read a locked letter (keep your own copy);
- retracting a locked letter destroys the ciphertext for good;
- the server needs network access to a drand relay when encrypting and
  again when decrypting (reveals retry every 5 minutes if the relay is
  unreachable at the moment the letter comes due).

Needs the `tle` binary on PATH (or set tlock.tle_bin):

    go install github.com/drand/tlock/cmd/tle@latest

The one hole no cryptography can close: the letter arrives at this server as
plaintext, on a machine your agent may live on. tlock stops anyone from
opening the envelope early; it cannot stop someone who rewired the mailbox
before you posted it. If that is your threat model, the problem is not the
lock.
"""
import base64
import subprocess
import time


def enabled(cfg):
    return bool(cfg.get("tlock", {}).get("enabled"))


def _bin(cfg):
    return cfg.get("tlock", {}).get("tle_bin", "tle")


def encrypt(cfg, plaintext: str, reveal_at: int) -> str:
    secs = max(1, int(reveal_at - time.time()))
    p = subprocess.run([_bin(cfg), "-e", "-D", f"{secs}s"],
                       input=plaintext.encode(), capture_output=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode().strip() or "tle encrypt failed")
    return base64.b64encode(p.stdout).decode()


def decrypt(cfg, ciphertext: str) -> str:
    p = subprocess.run([_bin(cfg), "-d"],
                       input=base64.b64decode(ciphertext), capture_output=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode().strip() or "tle decrypt failed")
    return p.stdout.decode()
