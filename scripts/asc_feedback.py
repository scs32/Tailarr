#!/usr/bin/env python3
"""Pull TestFlight beta feedback (screenshots + crashes) for Tailarr.

Session-start routine: run this at the start of a working session to see what
testers reported. Screenshot URLs are printed; download with curl to view.

  /usr/bin/python3 scripts/asc_feedback.py            # all feedback, newest first
  /usr/bin/python3 scripts/asc_feedback.py --since 2026-07-27   # only newer

Requires the ASC API key .p8 at KEY_PATH (not committed).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT (use /usr/bin/python3 on this Mac)

KEY_ID = os.environ.get("ASC_KEY_ID", "C9NUZL9HZF")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "aec2db68-0505-4886-832b-c6e1dcd4e0e0")
KEY_PATH = os.environ.get(
    "ASC_KEY_PATH",
    os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_C9NUZL9HZF.p8"),
)
BUNDLE_ID = "com.stephenspeicher.tailarr"


def _token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        open(KEY_PATH).read(), algorithm="ES256", headers={"kid": KEY_ID})


def api(path):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        headers={"Authorization": f"Bearer {_token()}"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} on {path}:", e.read().decode()[:300], file=sys.stderr)
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", help="only feedback on/after this ISO date (YYYY-MM-DD)")
    args = ap.parse_args()

    apps = api(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
    if not apps or not apps.get("data"):
        print("No app found", file=sys.stderr)
        return 1
    app_id = apps["data"][0]["id"]
    print(f"App: {apps['data'][0]['attributes']['name']} ({app_id})\n")

    def show(kind, data):
        rows = (data or {}).get("data", [])
        if args.since:
            rows = [d for d in rows if (d["attributes"].get("createdDate") or "") >= args.since]
        print(f"=== {kind} ({len(rows)}) ===")
        for d in rows:
            a = d["attributes"]
            print(f"\n[{a.get('createdDate')}] {a.get('deviceModel','?')} iOS {a.get('osVersion','?')}")
            if a.get("comment"):
                print(f"  comment: {a['comment']}")
            for i, s in enumerate(a.get("screenshots") or []):
                print(f"  shot[{i}]: {s.get('url')}")

    show("SCREENSHOT FEEDBACK",
         api(f"/v1/apps/{app_id}/betaFeedbackScreenshotSubmissions?limit=200&sort=-createdDate"))
    print()
    show("CRASH FEEDBACK",
         api(f"/v1/apps/{app_id}/betaFeedbackCrashSubmissions?limit=200&sort=-createdDate"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
