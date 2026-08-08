"""
Bearer-token authentication for the gateway.

Lives in its own module by necessity: ``gateway/main.py`` imports
``admin_router`` from ``gateway/admin.py``, so ``admin.py`` importing a guard
from ``main.py`` would be a circular import.

Two scopes, with admin as a superset of client:

    Authorization: Bearer <token>
              │
              ▼
      _extract_bearer()  ──► absent / not "Bearer x" / empty ──► 401
              │
              ▼
      ┌───────────────────────────────────────────────┐
      │  require_admin   token ∈ ADMIN         ──► pass│
      │                  otherwise             ──► 403 │
      ├───────────────────────────────────────────────┤
      │  require_client  token ∈ CLIENT ∪ ADMIN ─► pass│
      │                  otherwise             ──► 403 │
      └───────────────────────────────────────────────┘

The superset rule exists so the admin dashboard can hold a single credential
and still use the test-chat panel, which calls /v1/chat/completions.

Both token sets are parsed ONCE at import into frozensets — never per request.
Validation also runs at import rather than in the FastAPI lifespan, because
httpx's ASGITransport does not run lifespan, which would leave the fail-closed
behaviour untested. Import time is still startup.

Rotation: both settings accept a comma-separated list, so a token can be added,
callers migrated, and the old one removed without a coordinated cutover. The
new set takes effect on the next restart.
"""

import logging
import secrets
from typing import Optional

from fastapi import Header, HTTPException

from core.config import settings

logger = logging.getLogger("switchboard.auth")


def _parse_tokens(raw: str) -> frozenset:
    """
    Parse a comma-separated token list into a frozenset.

    Strips surrounding whitespace, drops empty entries, and collapses
    duplicates. ``"" -> frozenset()``, which is what makes the config
    validation below able to detect an unset variable.
    """
    if not raw:
        return frozenset()
    return frozenset(part.strip() for part in raw.split(",") if part.strip())


ADMIN_TOKENS = _parse_tokens(settings.ADMIN_TOKENS)
CLIENT_TOKENS = _parse_tokens(settings.CLIENT_TOKENS)


def validate_auth_config(
    admin_tokens: Optional[frozenset] = None,
    client_tokens: Optional[frozenset] = None,
) -> None:
    """
    Fail closed: refuse to start unless both token sets are populated.

    Mirrors the ENCRYPTION_KEY contract in core/key_manager.py — one rule for
    every required secret. An unset token must never mean "auth disabled".

    The optional arguments exist so this can be tested directly without
    reloading the module.
    """
    admin = ADMIN_TOKENS if admin_tokens is None else admin_tokens
    client = CLIENT_TOKENS if client_tokens is None else client_tokens

    missing = []
    if not admin:
        missing.append("ADMIN_TOKENS")
    if not client:
        missing.append("CLIENT_TOKENS")

    if missing:
        raise RuntimeError(
            f"{' and '.join(missing)} not set. The gateway refuses to start "
            "without authentication configured. Run ./setup.sh to generate "
            "tokens, or generate one yourself with: "
            "python -c \"import secrets; print(secrets.token_urlsafe(32))\""
        )


validate_auth_config()


def _extract_bearer(authorization: Optional[str]) -> Optional[str]:
    """Pull the token out of an ``Authorization: Bearer <token>`` header."""
    if not authorization:
        return None
    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    return parts[1].strip() or None


def _token_matches(provided: str, allowed: frozenset) -> bool:
    """
    Constant-time membership check.

    ``provided in allowed`` would be a plain hash lookup and is not
    constant-time, and ``compare_digest`` cannot take a set. The loop
    deliberately does NOT early-exit on a match so that timing does not
    reveal the position of the matching token.
    """
    matched = False
    for token in allowed:
        if secrets.compare_digest(provided, token):
            matched = True
    return matched


def _authorize(authorization: Optional[str], allowed: frozenset, scope: str) -> None:
    token = _extract_bearer(authorization)
    if token is None:
        raise HTTPException(
            status_code=401,
            detail="Missing or malformed Authorization header. "
                   "Expected: Authorization: Bearer <token>",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if not _token_matches(token, allowed):
        logger.warning("Rejected a request with an invalid %s token.", scope)
        raise HTTPException(status_code=403, detail="Invalid credentials")


async def require_admin(authorization: Optional[str] = Header(None)) -> None:
    """Guard for /admin/* and the OpenAPI docs routes."""
    _authorize(authorization, ADMIN_TOKENS, "admin")


async def require_client(authorization: Optional[str] = Header(None)) -> None:
    """Guard for /v1/*. Admin tokens are accepted here too (superset)."""
    _authorize(authorization, CLIENT_TOKENS | ADMIN_TOKENS, "client")
