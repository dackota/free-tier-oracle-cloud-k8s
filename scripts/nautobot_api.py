"""Minimal idempotent REST helpers for the Nautobot seeding scripts.

Every writer here is get-or-create or additive, so the scripts can be re-run
against an instance that is already partly populated.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = os.environ.get("NAUTOBOT_URL", "https://nautobot.dackota.com").rstrip("/")
TOKEN = os.environ.get("NAUTOBOT_TOKEN")

created = []
existing = []


class ApiError(RuntimeError):
    """A Nautobot API call returned a non-2xx response."""


def require_token():
    if not TOKEN:
        sys.exit("NAUTOBOT_TOKEN is not set")


def request(method, path, payload=None):
    url = f"{BASE_URL}/api/{path.lstrip('/')}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Token {TOKEN}")
    req.add_header("Accept", "application/json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise ApiError(f"{method} {url} -> {exc.code}\n{detail}") from exc


def find(endpoint, **filters):
    """Return the single object matching filters, or None."""
    query = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in filters.items())
    result = request("GET", f"{endpoint}/?{query}&limit=2")
    hits = result.get("results", [])
    if len(hits) > 1:
        raise ApiError(f"{endpoint} filter {filters} matched {len(hits)} objects")
    return hits[0] if hits else None


def get_or_create(endpoint, lookup, payload=None, label=None):
    """Fetch the object identified by `lookup`, creating it from `payload` if absent."""
    found = find(endpoint, **lookup)
    name = label or next(iter(lookup.values()))
    if found:
        existing.append(f"{endpoint}: {name}")
        return found
    obj = request("POST", f"{endpoint}/", {**lookup, **(payload or {})})
    created.append(f"{endpoint}: {name}")
    return obj


def patch(endpoint, obj_id, payload):
    return request("PATCH", f"{endpoint}/{obj_id}/", payload)


def add_tag(endpoint, obj, tag_id, label):
    """Append a tag without disturbing tags the object already carries.

    The tag list is re-read from the API rather than taken from the caller's
    copy of the object. Nautobot's tags field is a full replacement on PATCH, so
    applying a second tag from a stale object would silently drop the first.
    """
    fresh = request("GET", f"{endpoint}/{obj['id']}/")
    current = [t["id"] if isinstance(t, dict) else t for t in (fresh.get("tags") or [])]
    if tag_id in current:
        existing.append(f"tag {label}")
        return fresh
    updated = patch(endpoint, obj["id"], {"tags": current + [tag_id]})
    created.append(f"tag {label}")
    return updated


def status_id(name):
    found = find("extras/statuses", name=name)
    if not found:
        raise ApiError(f"status {name!r} not found")
    return found["id"]


def report(title):
    print(f"\n{title}: created {len(created)}, already present {len(existing)}")
    for line in created:
        print(f"  + {line}")
    if existing:
        print(f"  ({len(existing)} objects already existed and were left untouched)")
