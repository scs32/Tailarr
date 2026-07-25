#!/usr/bin/env python3
"""Post-upload TestFlight release for a Tailarr build.

Run AFTER CI has uploaded the build. Polls for the new build to reach VALID,
submits it for beta review, adds it to the Public Beta group, and sets the
What-to-Test notes. Mutating steps RETRY on transient Apple 5xx errors — the
Public Beta group-add in particular has hit spurious 500s that would otherwise
silently leave the build out of testers' hands (build 29, 2026-07-25). Also
skips the group-add if the build is already a member.

Requires the ASC API key .p8 at KEY_PATH (not committed). KEY_ID / ISSUER_ID /
BETA_GROUP are identifiers, not secrets.

Usage:
  python3 scripts/asc_release.py --skip <PREV_BUILD_ID> --notes-file notes.txt
  python3 scripts/asc_release.py --skip <PREV_BUILD_ID> --notes "..." --revoke-cert

--skip is the id of the CURRENT newest build (the previous release); right after
CI upload the API briefly shows it as newest, so we wait for a DIFFERENT VALID
build. --revoke-cert runs scripts/revoke_oldest_cert.py --revoke once live
(net-flat cert-cap policy; safe — nothing is signing then).
"""
import argparse
import json
import os
import subprocess
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
BETA_GROUP = os.environ.get("ASC_BETA_GROUP", "9d6bdfdb-3c09-48d5-a580-5d7115ed1b21")
HERE = os.path.dirname(os.path.abspath(__file__))


def _token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        open(KEY_PATH).read(), algorithm="ES256", headers={"kid": KEY_ID})


def api(method, path, body=None):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path, method=method,
        headers={"Authorization": f"Bearer {_token()}", "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return r.status, (json.loads(data) if data else {})
    except urllib.error.HTTPError as e:
        data = e.read()
        try:
            return e.code, json.loads(data) if data else {}
        except ValueError:
            return e.code, {}


def api_retry(method, path, body=None, ok=(200, 201, 204), tries=5):
    """Retry a mutating call on transient Apple 5xx errors."""
    for attempt in range(1, tries + 1):
        s, r = api(method, path, body)
        if s in ok:
            return s, r
        if s < 500:  # 4xx = don't retry (real error)
            print(f"  {method} {path} -> HTTP {s} (not retrying): {r}")
            return s, r
        print(f"  {method} {path} -> HTTP {s}, retrying ({attempt}/{tries})...")
        time.sleep(min(5 * attempt, 20))
    return s, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip", required=True, help="previous build id to skip")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--notes")
    g.add_argument("--notes-file")
    ap.add_argument("--revoke-cert", action="store_true")
    args = ap.parse_args()
    whats_new = args.notes if args.notes else open(args.notes_file).read().strip()

    _, apps = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
    app_id = apps["data"][0]["id"]

    build = None
    for _ in range(90):
        _, builds = api("GET",
            f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=1")
        if builds.get("data"):
            c = builds["data"][0]
            state, ver = c["attributes"]["processingState"], c["attributes"]["version"]
            print(f"newest build v{ver} ({c['id']}): {state}", flush=True)
            if c["id"] != args.skip:
                build = c
                if state == "VALID":
                    break
                if state in ("FAILED", "INVALID"):
                    sys.exit(f"processing failed: {state}")
        time.sleep(40)
    else:
        sys.exit("timed out waiting for the new build to be VALID")

    bid = build["id"]
    print("RELEASING", bid, "v" + build["attributes"]["version"], flush=True)

    s, r = api_retry("POST", "/v1/betaAppReviewSubmissions", {
        "data": {"type": "betaAppReviewSubmissions",
                 "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
    print("betaAppReviewSubmission:", s, flush=True)

    # Public Beta group — skip if already a member, retry transient 5xx.
    _, groups = api("GET", f"/v1/builds/{bid}/betaGroups")
    if BETA_GROUP in [g["id"] for g in groups.get("data", [])]:
        print("already in Public Beta group", flush=True)
    else:
        s, _ = api_retry("POST", f"/v1/betaGroups/{BETA_GROUP}/relationships/builds",
                         {"data": [{"type": "builds", "id": bid}]})
        print("added to Public Beta group:", s, flush=True)
        if s not in (201, 204):
            sys.exit(f"FAILED to add to Public Beta group (HTTP {s}) — testers "
                     f"will NOT get this build")

    _, locs = api("GET", f"/v1/builds/{bid}/betaBuildLocalizations")
    if locs.get("data"):
        lid = locs["data"][0]["id"]
        s, _ = api_retry("PATCH", f"/v1/betaBuildLocalizations/{lid}",
            {"data": {"type": "betaBuildLocalizations", "id": lid,
                      "attributes": {"whatsNew": whats_new}}})
    else:
        s, _ = api_retry("POST", "/v1/betaBuildLocalizations",
            {"data": {"type": "betaBuildLocalizations",
                      "attributes": {"whatsNew": whats_new, "locale": "en-US"},
                      "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
    print("what-to-test notes:", s, flush=True)

    if args.revoke_cert:
        print("cert-cap cleanup:", flush=True)
        subprocess.run([sys.executable,
                        os.path.join(HERE, "revoke_oldest_cert.py"), "--revoke"])
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
