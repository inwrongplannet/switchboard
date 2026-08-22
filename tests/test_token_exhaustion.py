"""
Tests for scripts/token_exhaustion.py.

Two tiers, matching the reason this file exists at all: the script previously
crashed on its second executable line because it read a data file that was never
committed. A smoke test catches that class of bug. A transport-level test catches
the thing the script is actually for.

The 429 test uses httpx.MockTransport rather than patching the script's own
functions, so the real request-building and header-parsing code runs. The only
fake thing is the network.
"""

import json
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import token_exhaustion as te  # noqa: E402


# --- generate_payload --------------------------------------------------------

def test_generate_payload_hits_the_requested_size():
    """~4 chars per token, so 6000 tokens should land within a token of 24000 chars."""
    text = te.generate_payload(6000)
    assert len(text) == 6000 * te.CHARS_PER_TOKEN
    assert len(text) // te.CHARS_PER_TOKEN == 6000


def test_generate_payload_is_deterministic():
    """Two runs must send identical context, or cache behaviour differs between runs."""
    assert te.generate_payload(500) == te.generate_payload(500)


def test_generate_payload_scales():
    assert len(te.generate_payload(2000)) < len(te.generate_payload(8000))


def test_generate_payload_rejects_nonsense():
    for bad in (0, -1):
        with pytest.raises(ValueError):
            te.generate_payload(bad)


def test_generate_payload_needs_no_files_on_disk():
    """
    The regression this file exists for. The old script did:
        FILE_PATH = "tests/sankalp-happy-victim-repo-....txt"
        with open(FILE_PATH) as f: ...
    at import time, against a file not in the repo.
    """
    assert "Section 1." in te.generate_payload(200)


# --- argument parsing --------------------------------------------------------

def test_parser_defaults():
    args = te.build_parser().parse_args([])
    assert args.url == "http://localhost:8000"
    assert args.requests == te.DEFAULT_REQUESTS
    assert args.context_tokens == te.DEFAULT_CONTEXT_TOKENS
    assert args.client_token is None


def test_parser_accepts_overrides():
    args = te.build_parser().parse_args(
        ["--url", "http://gw:9000", "--requests", "3", "--client-token", "abc", "--model", "m"]
    )
    assert (args.url, args.requests, args.client_token, args.model) == ("http://gw:9000", 3, "abc", "m")


def test_parser_help_does_not_crash(capsys):
    """`--help` must print usage rather than traceback. It is the first thing anyone runs."""
    with pytest.raises(SystemExit) as exc:
        te.build_parser().parse_args(["--help"])
    assert exc.value.code == 0
    assert "SwitchBoard" in capsys.readouterr().out


def test_first_token_prefers_explicit_over_env(monkeypatch):
    monkeypatch.setenv("CLIENT_TOKENS", "from-env,second")
    assert te._first_token("explicit", "CLIENT_TOKENS") == "explicit"


def test_first_token_takes_first_of_a_rotation_list(monkeypatch):
    monkeypatch.setenv("CLIENT_TOKENS", " first , second ")
    assert te._first_token(None, "CLIENT_TOKENS") == "first"


def test_first_token_none_when_unset(monkeypatch):
    monkeypatch.delenv("CLIENT_TOKENS", raising=False)
    assert te._first_token(None, "CLIENT_TOKENS") is None


def test_main_exits_cleanly_without_a_client_token(monkeypatch, capsys):
    """No token must produce a message and exit 2, not a traceback."""
    monkeypatch.delenv("CLIENT_TOKENS", raising=False)
    assert te.main([]) == 2
    assert "no client token" in capsys.readouterr().err


# --- rotation behaviour, over a mocked transport -----------------------------

def _completion_body(total_tokens: int = 1000) -> dict:
    return {
        "id": "cmpl-1",
        "object": "chat.completion",
        "created": 0,
        "model": "llama-3.1-8b-instant",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
        "usage": {"total_tokens": total_tokens},
    }


def _keys_body(enabled_second: bool = True) -> dict:
    return {
        "keys": [
            {"id": 1, "label": "groq-a", "is_enabled": False,
             "rate_limit_remaining_tokens": 0, "rate_limit_remaining_requests": 0, "last_used_at": "now"},
            {"id": 2, "label": "groq-b", "is_enabled": enabled_second,
             "rate_limit_remaining_tokens": 250000, "rate_limit_remaining_requests": 1000, "last_used_at": None},
        ]
    }


def _run_with(statuses, admin_token="admin-tok"):
    """
    Drive run() against a MockTransport that returns `statuses` in order for
    /v1/chat/completions. Returns the Summary.
    """
    calls = iter(statuses)

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/admin/keys":
            assert request.headers["Authorization"] == f"Bearer {admin_token}"
            return httpx.Response(200, json=_keys_body())
        assert request.url.path == "/v1/chat/completions"
        assert request.headers["Authorization"] == "Bearer client-tok"
        status = next(calls)
        if status == 200:
            return httpx.Response(
                200,
                json=_completion_body(),
                headers={"X-Cache": "MISS", "X-Provider": "groq", "X-Latency-Ms": "120.0"},
            )
        return httpx.Response(status, text="rate limited")

    args = te.build_parser().parse_args(["--requests", str(len(statuses)), "--context-tokens", "50"])
    with httpx.Client(transport=httpx.MockTransport(handler), base_url="http://gw") as client:
        return te.run(client, args, "client-tok", admin_token)


def test_rotation_is_reported_when_a_429_is_followed_by_a_success():
    """The behaviour the script exists to demonstrate: 429, then recovery."""
    summary = _run_with([200, 429, 200, 200])

    assert summary.rotation_observed is True
    assert summary.rate_limited == 1
    assert summary.successes == 3
    assert summary.total_tokens == 3000


def test_no_rotation_when_every_key_is_exhausted():
    """429s with no later success means all keys are gone, which is not rotation."""
    summary = _run_with([200, 429, 429])

    assert summary.rotation_observed is False
    assert summary.rate_limited == 2
    assert summary.successes == 1


def test_no_rotation_when_no_limit_was_ever_hit():
    summary = _run_with([200, 200, 200])

    assert summary.rotation_observed is False
    assert summary.rate_limited == 0
    assert summary.failures == 0


def test_response_headers_are_read_off_the_wire():
    summary = _run_with([200])
    attempt = summary.attempts[0]

    assert attempt.provider == "groq"
    assert attempt.cache == "MISS"
    assert attempt.tokens == 1000


def test_key_states_are_captured_before_and_after():
    summary = _run_with([200])

    assert [k["id"] for k in summary.keys_before] == [1, 2]
    assert [k["id"] for k in summary.keys_after] == [1, 2]


def test_admin_endpoint_failure_degrades_instead_of_raising():
    """
    /admin/keys is diagnostic. A 401 there must not abort the load test — this is
    exactly what the previous version got wrong, calling it with no auth header at all.
    """
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/admin/keys":
            return httpx.Response(401, text="unauthorized")
        return httpx.Response(200, json=_completion_body(), headers={"X-Provider": "groq"})

    args = te.build_parser().parse_args(["--requests", "1", "--context-tokens", "50"])
    with httpx.Client(transport=httpx.MockTransport(handler), base_url="http://gw") as client:
        summary = te.run(client, args, "client-tok", "bad-admin-token")

    assert summary.successes == 1
    assert summary.keys_before == []


def test_connection_error_is_recorded_not_raised():
    """A gateway that is not running must produce a clear line, not a traceback."""
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    args = te.build_parser().parse_args(["--requests", "2", "--context-tokens", "50"])
    with httpx.Client(transport=httpx.MockTransport(handler), base_url="http://gw") as client:
        summary = te.run(client, args, "client-tok", None)

    assert summary.successes == 0
    assert summary.failures == 2
    assert all(a.status == 0 and "refused" in a.error for a in summary.attempts)
    # Must diagnose "gateway is down", not "send more requests".
    assert summary.unreachable is True


def test_unreachable_is_not_confused_with_rate_limiting():
    """A mix of connection errors and real responses is not an unreachable gateway."""
    summary = _run_with([200, 429])
    assert summary.unreachable is False
    assert summary.connection_errors == 0


def test_prompts_are_distinct_so_the_semantic_cache_misses():
    """
    Identical prompts would hit the cache and burn no provider tokens, which would
    make the whole exercise measure nothing.
    """
    rendered = [t.format(n=i) for i, t in enumerate(te.PROMPT_TEMPLATES, 1)]
    assert len(set(rendered)) == len(rendered)
