"""
Tests for gateway authentication.

Covers the token parser, the fail-closed config validation, both guards, the
scope boundary between them, and the routes that must stay open.

The negative tests here are the point. A suite that only proves authorised
calls succeed would pass whether or not the guard rejects anything.
"""

import pytest

from gateway.auth import (
    _extract_bearer,
    _parse_tokens,
    _token_matches,
    validate_auth_config,
)
from tests.conftest import (
    TEST_ADMIN_TOKEN,
    TEST_CLIENT_TOKEN,
    TEST_CLIENT_TOKEN_2,
)

CHAT_BODY = {"model": "test-model", "messages": [{"role": "user", "content": "hi"}]}

# Every route on the admin router. There are seven — /admin/keys/usage is the
# one that is easy to miss when counting.
ADMIN_ROUTES = [
    ("POST", "/admin/keys"),
    ("GET", "/admin/keys"),
    ("DELETE", "/admin/keys/1"),
    ("PATCH", "/admin/keys/1"),
    ("GET", "/admin/providers"),
    ("GET", "/admin/keys/usage"),
    ("GET", "/admin/stats"),
]


# ---- _parse_tokens ------------------------------------------------------

def test_parse_tokens_empty_string_is_empty_set():
    # This is what makes fail-closed detectable: unset must not mean "any".
    assert _parse_tokens("") == frozenset()


def test_parse_tokens_single():
    assert _parse_tokens("abc") == frozenset({"abc"})


def test_parse_tokens_multiple():
    assert _parse_tokens("a,b,c") == frozenset({"a", "b", "c"})


def test_parse_tokens_strips_whitespace():
    assert _parse_tokens("  a , b  ") == frozenset({"a", "b"})


def test_parse_tokens_drops_empty_entries():
    assert _parse_tokens("a,,b,") == frozenset({"a", "b"})


def test_parse_tokens_collapses_duplicates():
    assert _parse_tokens("a,a,b") == frozenset({"a", "b"})


def test_parse_tokens_whitespace_only_is_empty():
    assert _parse_tokens("  ,  , ") == frozenset()


# ---- validate_auth_config (fail closed) ---------------------------------

def test_validate_raises_when_admin_tokens_missing():
    with pytest.raises(RuntimeError, match="ADMIN_TOKENS"):
        validate_auth_config(frozenset(), frozenset({"c"}))


def test_validate_raises_when_client_tokens_missing():
    with pytest.raises(RuntimeError, match="CLIENT_TOKENS"):
        validate_auth_config(frozenset({"a"}), frozenset())


def test_validate_names_both_when_both_missing():
    with pytest.raises(RuntimeError) as exc:
        validate_auth_config(frozenset(), frozenset())
    assert "ADMIN_TOKENS" in str(exc.value)
    assert "CLIENT_TOKENS" in str(exc.value)


def test_validate_passes_when_both_present():
    validate_auth_config(frozenset({"a"}), frozenset({"c"}))  # must not raise


# ---- header parsing and comparison --------------------------------------

@pytest.mark.parametrize("header", [None, "", "token-only", "Basic abc", "Bearer", "Bearer   "])
def test_extract_bearer_rejects_malformed(header):
    assert _extract_bearer(header) is None


def test_extract_bearer_accepts_valid():
    assert _extract_bearer("Bearer abc123") == "abc123"


def test_extract_bearer_is_case_insensitive_on_scheme():
    assert _extract_bearer("bearer abc123") == "abc123"


def test_token_matches_finds_member():
    assert _token_matches("b", frozenset({"a", "b", "c"})) is True


def test_token_matches_rejects_non_member():
    assert _token_matches("z", frozenset({"a", "b"})) is False


def test_token_matches_on_empty_set_is_false():
    assert _token_matches("a", frozenset()) is False


# ---- admin guard --------------------------------------------------------

@pytest.mark.asyncio
@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
async def test_admin_routes_reject_unauthenticated(raw_client, method, path):
    resp = await raw_client.request(method, path, json={})
    assert resp.status_code == 401, f"{method} {path} did not require auth"


@pytest.mark.asyncio
async def test_admin_route_rejects_malformed_header(raw_client):
    resp = await raw_client.get("/admin/stats", headers={"Authorization": "notbearer"})
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_admin_route_rejects_wrong_token(raw_client):
    resp = await raw_client.get(
        "/admin/stats", headers={"Authorization": "Bearer wrong-token"}
    )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_admin_route_accepts_admin_token(admin_client):
    resp = await admin_client.get("/admin/stats")
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_401_carries_www_authenticate(raw_client):
    resp = await raw_client.get("/admin/stats")
    assert resp.headers.get("www-authenticate") == "Bearer"


# ---- scope boundary -----------------------------------------------------

@pytest.mark.asyncio
async def test_client_token_cannot_reach_admin(client_scope_client):
    """The assertion that makes the two scopes real rather than decorative."""
    resp = await client_scope_client.get("/admin/stats")
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_completions_rejects_unauthenticated(raw_client):
    resp = await raw_client.post("/v1/chat/completions", json=CHAT_BODY)
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_completions_rejects_wrong_token(raw_client):
    resp = await raw_client.post(
        "/v1/chat/completions",
        json=CHAT_BODY,
        headers={"Authorization": "Bearer nope"},
    )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_completions_accepts_client_token(client_scope_client, stub_router):
    """A valid client token clears the guard and reaches the handler body."""
    resp = await client_scope_client.post("/v1/chat/completions", json=CHAT_BODY)
    assert resp.status_code not in (401, 403)
    assert stub_router.await_count == 1


@pytest.mark.asyncio
async def test_completions_accepts_admin_token_superset(admin_client, stub_router):
    """Admin is a superset of client — this is what lets the dashboard's
    test-chat panel work with the single token it holds."""
    resp = await admin_client.post("/v1/chat/completions", json=CHAT_BODY)
    assert resp.status_code not in (401, 403)
    assert stub_router.await_count == 1


@pytest.mark.asyncio
async def test_second_client_token_also_works(raw_client, stub_router):
    """Rotation: both entries in the comma-separated CLIENT_TOKENS are valid."""
    resp = await raw_client.post(
        "/v1/chat/completions",
        json=CHAT_BODY,
        headers={"Authorization": f"Bearer {TEST_CLIENT_TOKEN_2}"},
    )
    assert resp.status_code not in (401, 403)
    assert stub_router.await_count == 1


@pytest.mark.asyncio
async def test_rejected_request_never_reaches_the_router(raw_client, stub_router):
    """The guard must short-circuit BEFORE any provider work happens —
    otherwise an unauthenticated caller could still cost you quota."""
    resp = await raw_client.post("/v1/chat/completions", json=CHAT_BODY)
    assert resp.status_code == 401
    stub_router.assert_not_awaited()


# ---- open routes --------------------------------------------------------

@pytest.mark.asyncio
async def test_health_stays_unauthenticated(raw_client):
    """Regression guard: Docker healthchecks depend on this staying open."""
    resp = await raw_client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_health_reports_cache_status(raw_client):
    resp = await raw_client.get("/health")
    assert resp.json()["cache"] in ("ok", "unavailable", "unknown")


# ---- /metrics -----------------------------------------------------------
#
# The gateway port is published to the host on purpose, so an open /metrics was
# readable by anything that could route here. It leaks per-endpoint request
# counts, latency histograms and the ACTIVE_KEYS gauge per provider.

@pytest.mark.asyncio
async def test_metrics_requires_admin(raw_client):
    resp = await raw_client.get("/metrics")
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_client_token_cannot_read_metrics(client_scope_client):
    resp = await client_scope_client.get("/metrics")
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_metrics_accessible_with_admin_token(admin_client):
    """Prometheus scrapes with an admin token — this is that path."""
    resp = await admin_client.get("/metrics")
    assert resp.status_code == 200
    # Proves the guard wraps the real exporter, not an empty stub.
    assert "http_requests_total" in resp.text


# ---- OpenAPI surface ----------------------------------------------------

@pytest.mark.asyncio
async def test_openapi_schema_requires_admin(raw_client):
    resp = await raw_client.get("/openapi.json")
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_openapi_schema_accessible_with_admin_token(admin_client):
    resp = await admin_client.get("/openapi.json")
    assert resp.status_code == 200
    assert "/admin/keys" in resp.json()["paths"]


@pytest.mark.asyncio
async def test_client_token_cannot_read_schema(client_scope_client):
    resp = await client_scope_client.get("/openapi.json")
    assert resp.status_code == 403


# ---- CORS ---------------------------------------------------------------
#
# The Origin header is mandatory in these tests. CORSMiddleware only emits
# Access-Control-Allow-Origin in response to a request that carries Origin, so
# an assertion made without it passes against the ORIGINAL vulnerable code and
# proves nothing at all.

@pytest.mark.asyncio
async def test_no_cors_header_on_cross_origin_request(raw_client):
    resp = await raw_client.get(
        "/health", headers={"Origin": "https://evil.test"}
    )
    assert "access-control-allow-origin" not in resp.headers


@pytest.mark.asyncio
async def test_no_cors_credentials_header(raw_client):
    resp = await raw_client.get(
        "/health", headers={"Origin": "https://evil.test"}
    )
    assert "access-control-allow-credentials" not in resp.headers


@pytest.mark.asyncio
async def test_preflight_is_not_granted(raw_client):
    resp = await raw_client.request(
        "OPTIONS",
        "/admin/keys",
        headers={
            "Origin": "https://evil.test",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert "access-control-allow-origin" not in resp.headers
