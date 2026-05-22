"""
Auth team's integration test (pytest).

Genuinely calls auth-service /authorize over HTTP and asserts the contract:
HTTP 200 + body {authorized: true}. When auth is down (no pod / scaled to 0),
requests.post raises ConnectionError / timeout — that's the honest failure mode.

Standalone run:
    AUTH_URL=http://localhost:3001 pytest tests/auth/test_auth.py -v
"""
import os
import pytest
import requests

AUTH_URL = os.environ.get("AUTH_URL", "http://localhost:3001")
REQUEST_TIMEOUT_S = float(os.environ.get("AUTH_REQUEST_TIMEOUT_S", "5"))


def test_authorize_returns_authorized_true():
    try:
        resp = requests.post(
            f"{AUTH_URL}/authorize",
            json={"orderId": "auth-test-probe"},
            timeout=REQUEST_TIMEOUT_S,
        )
    except requests.RequestException as exc:
        pytest.fail(
            f"AUTH-SERVICE UNREACHABLE at {AUTH_URL}: {exc}. "
            "The service is down, the pod is terminating, or there's a "
            "network/DNS problem."
        )

    assert resp.status_code == 200, (
        f"expected HTTP 200 from {AUTH_URL}/authorize, got {resp.status_code} "
        f"(body: {resp.text!r})"
    )

    body = resp.json()
    assert body.get("authorized") is True, (
        f"expected body {{authorized: true}}, got {body}"
    )
