#!/usr/bin/env python3
"""
Load-generator that drives a SwitchBoard gateway until a provider key hits its
rate limit, so you can watch automatic key rotation actually happen.

This points at YOUR OWN gateway. It is a way to exercise the failover path in
routing/router.py, which is otherwise hard to trigger on purpose: you have to
burn a real provider quota to see it.

    ┌────────────┐  large prompt   ┌───────────┐  429   ┌─────────────┐
    │ this script│ ──────────────► │  gateway  │ ─────► │ key A       │
    └────────────┘   xN            └─────┬─────┘        │ exhausted   │
          ▲                              │ rotate       └─────────────┘
          │      200 OK                  ▼
          └────────────────────────  key B

Rotation is observed two ways: a 429 followed by a later success, and a change
in what /admin/keys reports before versus after.

Usage:
    export ADMIN_TOKENS=...        # or pass --admin-token
    export CLIENT_TOKENS=...       # or pass --client-token
    python scripts/token_exhaustion.py --requests 30

See scripts/README.md.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

import httpx

# Rough industry heuristic: English text runs about 4 characters per token. Exact
# enough to size a payload, not exact enough to bill anyone.
CHARS_PER_TOKEN = 4

DEFAULT_URL = "http://localhost:8000"
DEFAULT_MODEL = "llama-3.1-8b-instant"
DEFAULT_REQUESTS = 30
DEFAULT_CONTEXT_TOKENS = 6000

# Neutral long-context questions. The point is to burn tokens with cache-missing
# prompts, so they need to be distinct from each other and nothing more.
PROMPT_TEMPLATES = [
    "Summarise section {n} of the document above in one paragraph.",
    "List the three main ideas in section {n} of the document above.",
    "What is the tone of section {n} of the document above?",
    "Rewrite section {n} of the document above for a beginner.",
    "What questions does section {n} of the document above leave unanswered?",
    "Compare section {n} of the document above to section 1.",
    "Extract every noun phrase from section {n} of the document above.",
    "Write a one-line title for section {n} of the document above.",
]


def generate_payload(target_tokens: int = DEFAULT_CONTEXT_TOKENS) -> str:
    """
    Build a deterministic filler document of roughly ``target_tokens`` tokens.

    Generated rather than read from disk on purpose. The previous version of this
    script read a file that was never committed, so it crashed on line one for
    anyone who cloned the repo.

    Deterministic so two runs send identical context, which keeps the semantic
    cache behaviour consistent between runs.
    """
    if target_tokens <= 0:
        raise ValueError("target_tokens must be positive")

    target_chars = target_tokens * CHARS_PER_TOKEN
    chunks = []
    length = 0
    section = 1
    while length < target_chars:
        para = (
            f"Section {section}. The gateway sits between client applications and "
            f"upstream providers. It selects a key, forwards the request, and records "
            f"the rate-limit headers that come back. When a key is exhausted the "
            f"router marks it and retries against the next one. Section {section} "
            f"exists to occupy context window space during a load test.\n\n"
        )
        chunks.append(para)
        length += len(para)
        section += 1
    return "".join(chunks)[:target_chars]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Drive a SwitchBoard gateway until a key rate-limits, to observe rotation.",
        epilog="Tokens are read from ADMIN_TOKENS / CLIENT_TOKENS if the flags are omitted.",
    )
    parser.add_argument("--url", default=DEFAULT_URL, help=f"gateway base URL (default: {DEFAULT_URL})")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"model to request (default: {DEFAULT_MODEL})")
    parser.add_argument(
        "--requests", type=int, default=DEFAULT_REQUESTS,
        help=f"how many completions to send (default: {DEFAULT_REQUESTS})",
    )
    parser.add_argument(
        "--context-tokens", type=int, default=DEFAULT_CONTEXT_TOKENS,
        help=f"approximate size of the filler context per request (default: {DEFAULT_CONTEXT_TOKENS})",
    )
    parser.add_argument("--client-token", default=None, help="defaults to the first entry of $CLIENT_TOKENS")
    parser.add_argument("--admin-token", default=None, help="defaults to the first entry of $ADMIN_TOKENS")
    parser.add_argument("--timeout", type=float, default=60.0, help="per-request timeout in seconds")
    return parser


def _first_token(explicit: Optional[str], env_var: str) -> Optional[str]:
    """Both settings are comma-separated lists to allow rotation; take the first."""
    if explicit:
        return explicit
    raw = os.environ.get(env_var, "")
    return raw.split(",")[0].strip() or None


@dataclass
class Attempt:
    index: int
    status: int
    tokens: int = 0
    provider: str = "?"
    cache: str = "?"
    elapsed_s: float = 0.0
    error: str = ""


@dataclass
class Summary:
    attempts: list[Attempt] = field(default_factory=list)
    keys_before: list[dict] = field(default_factory=list)
    keys_after: list[dict] = field(default_factory=list)

    @property
    def successes(self) -> int:
        return sum(1 for a in self.attempts if a.status == 200)

    @property
    def rate_limited(self) -> int:
        return sum(1 for a in self.attempts if a.status == 429)

    @property
    def failures(self) -> int:
        return sum(1 for a in self.attempts if a.status != 200)

    @property
    def total_tokens(self) -> int:
        return sum(a.tokens for a in self.attempts)

    @property
    def connection_errors(self) -> int:
        return sum(1 for a in self.attempts if a.status == 0)

    @property
    def unreachable(self) -> bool:
        """Every request failed to connect — the gateway is down, not rate-limited."""
        return bool(self.attempts) and self.connection_errors == len(self.attempts)

    @property
    def rotation_observed(self) -> bool:
        """
        True when a rate limit was hit and a later request still succeeded.

        That ordering is the whole signal: it means the gateway moved to a
        different key rather than surfacing the 429 to the caller. A 429 with no
        subsequent success means every key was exhausted, which is a different
        (and also interesting) outcome.
        """
        seen_limit = False
        for attempt in self.attempts:
            if attempt.status == 429:
                seen_limit = True
            elif seen_limit and attempt.status == 200:
                return True
        return False


def fetch_key_states(client: httpx.Client, admin_token: Optional[str]) -> list[dict]:
    """Read /admin/keys. Returns [] rather than raising — this is diagnostic, not the test."""
    if not admin_token:
        return []
    try:
        res = client.get("/admin/keys", headers={"Authorization": f"Bearer {admin_token}"})
        if res.status_code != 200:
            print(f"  (could not read /admin/keys: HTTP {res.status_code})", file=sys.stderr)
            return []
        return res.json().get("keys", [])
    except httpx.HTTPError as exc:
        print(f"  (could not read /admin/keys: {exc})", file=sys.stderr)
        return []


def send_completion(
    client: httpx.Client, client_token: str, model: str, context: str, prompt: str, index: int
) -> Attempt:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": f"Reference document:\n\n{context}"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.3,
    }
    start = time.monotonic()
    try:
        res = client.post(
            "/v1/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {client_token}"},
        )
    except httpx.HTTPError as exc:
        return Attempt(index=index, status=0, elapsed_s=time.monotonic() - start, error=str(exc))

    elapsed = time.monotonic() - start
    if res.status_code != 200:
        return Attempt(index=index, status=res.status_code, elapsed_s=elapsed, error=res.text[:200])

    body = res.json()
    return Attempt(
        index=index,
        status=200,
        tokens=body.get("usage", {}).get("total_tokens", 0),
        provider=res.headers.get("X-Provider", "?"),
        cache=res.headers.get("X-Cache", "?"),
        elapsed_s=elapsed,
    )


def print_keys(keys: list[dict]) -> None:
    if not keys:
        print("  (no key states available — pass --admin-token to see them)")
        return
    for k in keys:
        print(
            f"  key {k['id']} ({str(k.get('label', '')):15.15s}) "
            f"enabled={str(k.get('is_enabled')):5s} "
            f"tokens_left={str(k.get('rate_limit_remaining_tokens', '-')):>8s} "
            f"reqs_left={str(k.get('rate_limit_remaining_requests', '-')):>6s} "
            f"last_used={k.get('last_used_at') or 'never'}"
        )


def run(client: httpx.Client, args: argparse.Namespace, client_token: str, admin_token: Optional[str]) -> Summary:
    context = generate_payload(args.context_tokens)
    summary = Summary()

    print("=" * 74)
    print("SwitchBoard key-rotation load test")
    print("=" * 74)
    print(f"gateway   : {args.url}")
    print(f"model     : {args.model}")
    print(f"context   : {len(context)} chars (~{len(context) // CHARS_PER_TOKEN} tokens) per request")
    print(f"requests  : {args.requests}")
    print("\n--- key states before ---")
    summary.keys_before = fetch_key_states(client, admin_token)
    print_keys(summary.keys_before)
    print()

    for i in range(1, args.requests + 1):
        template = PROMPT_TEMPLATES[(i - 1) % len(PROMPT_TEMPLATES)]
        attempt = send_completion(client, client_token, args.model, context, template.format(n=i), i)
        summary.attempts.append(attempt)

        if attempt.status == 200:
            print(
                f"  req={i:3d} 200  tokens={attempt.tokens:6d} running={summary.total_tokens:8d} "
                f"cache={attempt.cache:4s} provider={attempt.provider:10s} {attempt.elapsed_s:.1f}s"
            )
        elif attempt.status == 0:
            print(f"  req={i:3d} ---  connection error: {attempt.error}")
        else:
            print(f"  req={i:3d} {attempt.status}  {attempt.elapsed_s:.1f}s  {attempt.error}")

        if i % 10 == 0:
            print(f"\n--- key states after {i} requests ---")
            print_keys(fetch_key_states(client, admin_token))
            print()

    summary.keys_after = fetch_key_states(client, admin_token)

    print("\n" + "=" * 74)
    print(
        f"RESULT: {summary.successes} ok, {summary.failures} failed "
        f"({summary.rate_limited} rate-limited), {summary.total_tokens} tokens"
    )
    if summary.unreachable:
        # Say the true thing. Telling someone to send more requests when nothing
        # is listening is the kind of advice that wastes an afternoon.
        print(f"GATEWAY UNREACHABLE: nothing answered at {args.url}.")
        print(f"                     Is it running? Try: curl {args.url}/health")
    elif summary.rotation_observed:
        print("ROTATION OBSERVED: a rate limit was hit and later requests still succeeded.")
    elif summary.rate_limited:
        print("NO ROTATION: rate limits were hit and nothing recovered — every key may be exhausted.")
    else:
        print("NO ROTATION: no rate limit was reached. Try --requests with a higher number.")
    print("=" * 74)
    print("\n--- key states after ---")
    print_keys(summary.keys_after)

    return summary


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    client_token = _first_token(args.client_token, "CLIENT_TOKENS")
    if not client_token:
        print(
            "error: no client token. Pass --client-token or set CLIENT_TOKENS.\n"
            "       The gateway rejects unauthenticated calls to /v1/*.",
            file=sys.stderr,
        )
        return 2
    admin_token = _first_token(args.admin_token, "ADMIN_TOKENS")

    try:
        with httpx.Client(base_url=args.url, timeout=args.timeout) as client:
            summary = run(client, args, client_token, admin_token)
    except httpx.ConnectError:
        print(
            f"error: could not reach a gateway at {args.url}.\n"
            f"       Is it running? Try: curl {args.url}/health",
            file=sys.stderr,
        )
        return 1

    return 0 if summary.successes else 1


if __name__ == "__main__":
    raise SystemExit(main())
