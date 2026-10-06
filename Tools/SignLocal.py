#!/usr/bin/env python3
"""Keep a private, certificate-backed identity for this Mac's local builds.

No system trust anchors are installed. The signature pins the actual certificate,
so another program cannot inherit access by merely copying the bundle identifier.
"""
import hashlib
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STORE = ROOT / ".signing"
APP_ID = "local.silver.screen-translator"


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        # Never include command arguments: they may contain a keychain password.
        raise RuntimeError(f"{Path(args[0]).name}: {result.stderr.strip()}")
    return result.stdout


def sign(app):
    # Never silently replace a missing signing identity. Doing so breaks the
    # app's existing privacy authorization even if its bundle ID is unchanged.
    password_file = STORE / "password"
    identity_file = STORE / "identity.p12"
    certificate_file = STORE / "certificate.pem"
    if not all(path.exists() for path in (password_file, identity_file, certificate_file)):
        raise RuntimeError("The original local signing identity is missing. Restore .signing; a new identity will not be generated.")
    STORE.chmod(0o700)
    for path in (password_file, identity_file, certificate_file):
        path.chmod(0o600)
    der = subprocess.run(["/usr/bin/openssl", "x509", "-in", str(certificate_file), "-outform", "DER"],
                         capture_output=True, check=True).stdout
    expected = (ROOT / "Tools/local-signing.sha256").read_text().strip()
    if hashlib.sha256(der).hexdigest() != expected:
        raise RuntimeError("The signing certificate changed. Restore the original certificate; signing stopped.")
    password = password_file.read_text().strip()
    with tempfile.TemporaryDirectory(prefix="screen-translator-sign-") as temporary:
        temp = Path(temporary)
        fingerprint = run(["/usr/bin/openssl", "x509", "-in", str(certificate_file),
                           "-noout", "-fingerprint", "-sha1"]).split("=", 1)[1].strip().replace(":", "")
        keychain = temp / "signing.keychain-db"
        original_search = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        try:
            run(["/usr/bin/security", "create-keychain", "-p", password, str(keychain)])
            # Keep the build keychain discoverable while resolving the identity
            # and restore the original search list in finally.
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search, str(keychain)])
            run(["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)])
            run(["/usr/bin/security", "import", str(identity_file), "-k", str(keychain),
                 "-P", password, "-T", "/usr/bin/codesign"])
            run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                 "-s", "-k", password, str(keychain)])
            # The designated requirement pins this certificate directly; no
            # certificate trust settings need to be changed for a local build.
            requirement = f'designated => identifier "{APP_ID}" and certificate leaf = H"{fingerprint}"'
            run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain),
                 "--identifier", APP_ID, "--timestamp=none", "--requirements", "=" + requirement, str(app)])
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        finally:
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search])
            if keychain.exists():
                run(["/usr/bin/security", "delete-keychain", str(keychain)])
    print("Signed with the persistent local certificate; signature verified.")


if __name__ == "__main__":
    try:
        sign(Path(sys.argv[1]).resolve())
    except Exception as error:
        print(f"Local signing failed: {error}", file=sys.stderr)
        sys.exit(1)
