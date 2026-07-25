#!/usr/bin/env python3
"""Cert-cap maintenance for the TestFlight release flow.

Apple caps the number of development certificates (~11). Every CI build signs
with `-allowProvisioningUpdates`, which mints a fresh "Created via API" cert, so
they accumulate and eventually the Archive step fails with "account has reached
the maximum number of certificates".

Policy (net-flat): run this with --revoke as the FINAL step of every release,
AFTER the build is live on TestFlight (nothing is signing then, so it's safe).
It revokes exactly the OLDEST orphan cert while KEEPING:
  - the local signing identity (LOCAL_CERT_ID, never a "Created via API" cert), and
  - the NEWEST "Created via API" cert (what the just-live build is provisioned
    against — must not be touched).
One build adds ~1 cert; this removes 1, so the cap is never reached again.

Requires the App Store Connect API key .p8 at KEY_PATH (not committed). The
KEY_ID / ISSUER_ID here are identifiers, not secrets. Dry-run unless --revoke.

Usage:
  python3 scripts/revoke_oldest_cert.py           # dry-run (show + plan)
  python3 scripts/revoke_oldest_cert.py --revoke   # actually revoke the oldest
"""
import json
import os
import sys
import time
import urllib.request

import jwt  # PyJWT (use /usr/bin/python3 on this Mac)

KEY_ID = os.environ.get("ASC_KEY_ID", "C9NUZL9HZF")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "aec2db68-0505-4886-832b-c6e1dcd4e0e0")
KEY_PATH = os.environ.get(
    "ASC_KEY_PATH",
    os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_C9NUZL9HZF.p8"),
)
LOCAL_CERT_ID = os.environ.get("ASC_LOCAL_CERT_ID", "FL7LS84W49")
API_MARKER = "Created via API"
DEV_TYPES = ("IOS_DEVELOPMENT", "DEVELOPMENT", "MAC_APP_DEVELOPMENT")


def _token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        open(KEY_PATH).read(), algorithm="ES256", headers={"kid": KEY_ID})


def _api(method, path):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path, method=method,
        headers={"Authorization": f"Bearer {_token()}"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read() or b"{}") if method == "GET" else r.status


def main():
    do = "--revoke" in sys.argv
    certs = _api("GET", "/v1/certificates?limit=200")["data"]
    dev = [c for c in certs
           if c["attributes"]["certificateType"] in DEV_TYPES]
    orphans = [c for c in dev
               if API_MARKER in (c["attributes"].get("name", "")
                                 + c["attributes"].get("displayName", ""))
               and c["id"] != LOCAL_CERT_ID]
    orphans.sort(key=lambda c: c["attributes"].get("expirationDate", ""))
    print(f"certs total={len(certs)} development={len(dev)} orphans={len(orphans)}")
    for c in orphans:
        a = c["attributes"]
        print(f"  {c['id']}  {a.get('displayName')}  exp={a.get('expirationDate')}")
    if len(orphans) <= 1:
        print("nothing to revoke (<=1 orphan; keeping the in-use one)")
        return
    newest, oldest = orphans[-1], orphans[0]
    print(f"KEEP newest (in use): {newest['id']}")
    verb = "REVOKING" if do else "WOULD REVOKE (dry-run; pass --revoke)"
    print(f"{verb} oldest: {oldest['id']} "
          f"exp={oldest['attributes'].get('expirationDate')}")
    if do:
        print("  DELETE ->", _api("DELETE", f"/v1/certificates/{oldest['id']}"))


if __name__ == "__main__":
    main()
