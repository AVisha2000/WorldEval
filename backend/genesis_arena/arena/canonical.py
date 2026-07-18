from __future__ import annotations

import hashlib
import hmac
import json
from typing import Any

from pydantic import BaseModel

from .models import FactionPlan


def canonical_json(value: Any) -> str:
    """Canonical JSON for v0.2 plan commitments.

    Plans contain no floating point values, so sorted compact JSON is portable to Godot.
    Null-valued fields are retained and UTF-8 text is not ASCII-escaped.
    """

    if isinstance(value, BaseModel):
        value = value.model_dump(mode="json")
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def plan_commit_hash(plan: FactionPlan, salt: str) -> str:
    payload = canonical_json(plan).encode("utf-8") + b"\n" + salt.encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def verify_plan_commit(plan: FactionPlan, salt: str, expected_hash: str) -> bool:
    return hmac.compare_digest(plan_commit_hash(plan, salt), expected_hash)
