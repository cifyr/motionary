"""Minimal App Store Connect client.

Signs ES256 with openssl because the system Python has no cryptography
backend. Configuration comes from the environment so no account identifier
lands in this repository:

    export ASC_KEY_ID=...        # the .p8 key's id
    export ASC_ISSUER_ID=...     # the team's issuer id
    export ASC_APP_ID=...        # the app record's numeric id

The key itself is read from ~/.appstoreconnect/private_keys/AuthKey_<id>.p8,
which is where altool and xcodebuild also look for it.
"""
import base64, json, os, subprocess, time, urllib.error, urllib.request

BASE = "https://api.appstoreconnect.apple.com"


def _required(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is not set; see the docstring in Tools/asc.py")
    return value


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def _der_to_raw(der):
    """openssl emits a DER SEQUENCE of two INTEGERs; a JWS wants r||s raw."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        ln = der[i + 1]
        out += der[i + 2:i + 2 + ln].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + ln
    return out


def token():
    key_id, issuer = _required("ASC_KEY_ID"), _required("ASC_ISSUER_ID")
    key = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not os.path.exists(key):
        raise SystemExit(f"no private key at {key}")
    hdr = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    pay = _b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200,
                           "aud": "appstoreconnect-v1"}).encode())
    signing = hdr + b"." + pay
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=signing,
                         capture_output=True, check=True).stdout
    return (signing + b"." + _b64(_der_to_raw(der))).decode()


_TOKEN = None


def call(method, path, body=None, retries=3):
    """Returns (status, decoded body). An HTTP error is a status, not a raise:
    the API answers 409 and 422 with the reason, which is the useful part."""
    global _TOKEN
    _TOKEN = _TOKEN or token()
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + _TOKEN)
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, {"raw": raw.decode(errors="replace")[:800]}
        except (urllib.error.URLError, OSError) as e:
            if attempt == retries - 1:
                raise RuntimeError(f"{method} {url} failed after {retries} attempts") from e
            time.sleep(2)


def errors(body):
    return "; ".join(f"{e.get('code')}: {e.get('detail', '')[:200]}"
                     for e in body.get("errors", []))


def app_id():
    return _required("ASC_APP_ID")
