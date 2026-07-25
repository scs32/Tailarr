# Tailarr Server (podscale) Security Audit — 2026-07-25

Four read-only reviewers (gateway trust model, keys/secrets at rest, API authz,
injection/ACL-fences) over `~/projects/podscale/web/`. Findings merged and
severity-ranked. Fixes belong to the **server session** (podscale), not this
repo.

**Verdict:** defensively well-built. No `shell=True`/`os.system` anywhere (all
subprocess calls use argv lists); secret-at-rest handling is excellent (0600
from first byte, API tokens stored only as SHA-256 hashes, `hmac.compare_digest`
throughout, secrets scrubbed from list/error responses, POST bodies never
logged); the whois gateway model is correct (a user device cannot impersonate
another person); the ACL fence splice engine fails closed. Security rests on two
assumptions the findings below mostly *bound*: (1) the tailnet ACL holds — since
the API bearer is **off by default**; (2) the `tailarr-gate` pod is not
compromised.

## HIGH

- **H1 — The mutating API is authentication-OFF by default.** `token_auth_ok`
  (app.py:2411) returns True whenever `require` is false, and that's the default
  (`.tokens.json` absent → `{"require": false}`). So on a stock install NO
  bearer is checked on any route. Any tailnet device that reaches the controller
  gets unauthenticated **`op_exec`** (arbitrary `sh -c` in any pod — including
  the controller pod, which mounts the podman socket → full fleet/host control)
  and **`op_install` custom** (attacker image + unrestricted host bind mounts →
  host compromise). Tokens are also unscoped (no read-vs-admin tier).
  → Default `require` on + provision a bootstrap admin token; gate
  `op_exec`/`op_install`/`op_controller_upgrade`/`op_tsapi_save` behind an admin
  scope. The only current boundary is the ACL.

- **H2 — Catalog (non-custom) install skips `NAME_RE`; a crafted service name
  injects ACL grants.** `NAME_RE.fullmatch(name)` is inside `if custom:`
  (app.py:3675); a catalog install (`custom=False`) never charset-validates the
  name, and `_valid_service` (app.py:276) checks no charset. That raw name flows
  into `os.path.join(PODS_DIR, name, …)` (path traversal) AND into the HuJSON
  ACL policy generator (`_managed_sections`, app.py:1849). A catalog source
  (admin-added, may be plain `http://`) returning a name like
  `A"], "dst": ["*"], "z": ["B` produces a valid grant `{"src":[...],
  "dst":["*"],"ip":["443"]}` that **passes both fences** (`_sections_prefix_ok`
  only inspects `tag:` matches; `_grants_minimality_ok` never asserts `dst` is a
  `tag:tailarr-svc-*`) and widens badge-holders to `*:443` across the tailnet.
  → Move `NAME_RE` above the `if custom:` block (all install paths); validate
  catalog names on ingest; and in `_grants_minimality_ok` require the single
  `dst` to match `^tag:tailarr-svc-[a-z0-9-]+$` and `ip==["443"]`.

## MEDIUM

- **M1 — Gate compromise harvests EVERY user's credentials.** The controller
  trusts the caller-supplied `ip` in `op_gateway_resolve` (app.py:4980) — only
  `GATEWAY_SECRET` authorizes it. The gate holds that secret AND can enumerate
  every user device IP from its sidecar, so a compromised gate can loop over all
  users and pull every person's live service API keys + ntfy tokens and hijack
  push tokens. Contradicts the docstring's "holds no secrets, can only ask its
  own question."
  → Have the controller cross-check the claimed `ip` is a live `tag:tailarr-u-*`
  peer; rate-limit `/api/gateway/resolve`; make `GATEWAY_SECRET` rotatable;
  correct the docstrings.

- **M2 — Reissuing a person's key does NOT revoke the old one.** No
  `DELETE /tailnet/-/keys/{id}` anywhere; reissue just mints a fresh key
  (app.py:1535 → 1452). A leaked/shared invite key stays enrollable for its 24h
  TTL, and badges are baked in at mint time, so reducing access + reissuing
  doesn't neutralize an outstanding broader key.
  → On reissue/badge-reduction, enumerate and `DELETE` the person's outstanding
  unconsumed keys before minting; at minimum document that reissue ≠ revoke.

- **M3 — NFS share `host_path` is not charset-validated → host export
  injection.** `op_share_add` (app.py:7356) only requires a leading `/`;
  `_render_exports` writes it verbatim into `/etc/exports.d` and runs
  `exportfs -ra` on the host (app.py:7609). A `host_path` with a newline injects
  an extra export line (e.g. `/ *(rw,no_root_squash)`) → host-root NFS export.
  → Validate `host_path` against a strict path charset (reject whitespace/
  newlines/parens).

## LOW / INFO

- **L1** `/metrics` is unauthenticated even when the token gate is on (pod
  names/state/CPU disclosure) — served outside `/api/` (app.py:8246).
- **L2** ntfy account password is passed on the `podman exec` argv (ps/proc
  visible) despite a comment claiming it rides `-e` env (app.py:4587).
- **L3** TOCTOU: `.ntfy.json` (and relay/kuma/server-name) are written at
  umask-default then `chmod 600` — a brief 0644 window for the ntfy
  passwords/tokens. Route through `_write_secret`.
- **L4** `/api/gateway/resolve` is bearer-exempt and reachable by any fleet pod;
  `GATEWAY_SECRET` (256-bit, constant-time) is the sole fence. Consider
  origin-binding or a dedicated scoped token.
- **L5** The `search` badge hands out ALL saved indexer keys (design — surface
  in the grant UI so admins know it's not per-indexer scopeable).
- **L6** Fence-check coverage gaps (`_grants_minimality_ok` doesn't assert `dst`
  shape) — mitigated by the H2 fix; harden to parse-and-assert exact shapes.
- **INFO** APNs `sandbox` flag is device-asserted; 500 responses echo raw
  exception text (both low-risk under the trust model).

## Verified sound (no action)
No `shell=True`/`os.system` anywhere; gateway `ip` regex-validated before
`whois`; person uid = `token_hex`, re-guarded in the ACL splice; push-token
regex-validated; controller self-upgrade version-validated (`^\d+\.\d+\.\d+$`,
registry derived from the current image — NOT arbitrary-image RCE); backup
restore sha256-checked + name/ts-constrained; tsapi/gateway-secret/bearer
storage excellent; whois self-flow strictly uid-scoped (no cross-person leak for
a genuine device); ACL splice fail-closed with `/validate` + last-good backup.

## Fix priority (for the server session)
1. **H1** — default the token gate on + bootstrap admin token (biggest lever;
   it's the compensating control the whole model leans on).
2. **H2** — `NAME_RE` on all install paths + tighten `_grants_minimality_ok`.
3. **M1** — bound gate blast radius (live-peer cross-check + rate-limit +
   rotatable secret).
4. **M2** — revoke outstanding keys on reissue.
5. **M3** — validate NFS `host_path`.
6. L1–L6 hardening.
