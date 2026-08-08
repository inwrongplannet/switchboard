"""
Shared fixtures and the suite's environment bootstrap.

ORDERING IS LOAD-BEARING. Two module-level side effects make it so:

    core/config.py:32   settings = Settings()          <- reads env at import
    gateway/auth.py     _parse_tokens(); validate_auth_config()

pytest imports conftest.py BEFORE any test module, so every variable the app
needs must be set here, above any import that reaches core.config.

Previously tests/test_admin_api.py did this bootstrap itself, and that worked
only because it happened to be the alphabetically first module and the only
importer of the app. Now that fixtures here import the app, that accident is
gone and the bootstrap has to live at this level.

If ADMIN_TOKENS / CLIENT_TOKENS are unset before gateway.auth is imported,
validate_auth_config() raises and the whole suite fails to collect. That is
the fail-closed behaviour working as intended, not a broken test setup.
"""

import os
import tempfile

from cryptography.fernet import Fernet

_tmpdir = tempfile.mkdtemp()
os.environ.setdefault("SQLITE_DB_PATH", os.path.join(_tmpdir, "test_switchboard.db"))
os.environ.setdefault("ENCRYPTION_KEY", Fernet.generate_key().decode())
os.environ.setdefault("GROQ_API_KEY", "")
os.environ.setdefault("GOOGLE_API_KEY", "")
os.environ.setdefault("ANTHROPIC_API_KEY", "")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")

TEST_ADMIN_TOKEN = "test-admin-4a1f9c2e8b7d6053a1f9c2e8b7d6"
TEST_CLIENT_TOKEN = "test-client-9e3b7a5d1c4f8206e3b7a5d1c4f8"
# A second client token, so the comma-separated rotation path is exercised by
# the real app config rather than only in the _parse_tokens unit tests.
TEST_CLIENT_TOKEN_2 = "test-client-rotation-partner-00112233"

os.environ.setdefault("ADMIN_TOKENS", TEST_ADMIN_TOKEN)
os.environ.setdefault("CLIENT_TOKENS", f"{TEST_CLIENT_TOKEN},{TEST_CLIENT_TOKEN_2}")

# ---- nothing above this line may import anything reaching core.config ----

from unittest.mock import AsyncMock  # noqa: E402

import pytest  # noqa: E402
import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402

from core.database import get_db, init_db  # noqa: E402
from gateway import main as gateway_main  # noqa: E402
from gateway.main import app  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def _close_db_at_session_end():
    """
    Close the shared aiosqlite connection once, after the whole session.

    aiosqlite services each connection from a non-daemon background thread.
    Because clean_db deliberately never closes the singleton (see the note
    there), nothing would reap that thread and the interpreter hangs at exit
    after the test summary has already printed — tests pass, pytest never
    returns. Closing here gives the connection exactly one owner: the session.
    """
    yield
    import asyncio

    from core import database

    if database._db_conn is not None:
        try:
            asyncio.run(database._db_conn.close())
        finally:
            database._db_conn = None


@pytest.fixture
def stub_router(monkeypatch):
    """
    Replace the provider router with a stub that raises immediately.

    Auth tests need to know whether a request cleared the guard and reached the
    handler body — not whether provider routing works. Without this the handler
    calls a real provider and the test hangs on a network timeout.

    The handler catches the exception and returns 502, so "not 401/403" is a
    precise signal that authorisation succeeded. Returning the mock also lets a
    test assert the router was never awaited, which is how we prove the guard
    short-circuits before any provider work can cost quota.
    """
    stub = AsyncMock(side_effect=RuntimeError("stubbed router: no provider call"))
    monkeypatch.setattr(gateway_main.router, "route_request", stub)
    return stub


@pytest_asyncio.fixture
async def clean_db():
    """
    Fresh schema, empty tables. Deliberately NOT autouse — the six test modules
    that never boot the app manage their own database state, and a suite-wide
    autouse fixture would reach into them for no reason.
    """
    await init_db()
    db = await get_db()
    await db.execute("DELETE FROM api_keys")
    await db.execute("DELETE FROM provider_config")
    await db.commit()
    # Deliberately NOT closed. core/database.py:64 caches the connection in a
    # module-level singleton and returns it without checking whether it is
    # still open, so closing here leaves every later get_db() handing back a
    # dead connection ("ValueError: no active connection"). The previous
    # fixture did close it, which is why tests/test_admin_api.py was already
    # red on main before any auth work — see TODOS.md.
    yield


def _client(headers=None):
    return AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
        headers=headers or {},
    )


@pytest_asyncio.fixture
async def admin_client(clean_db):
    """Authenticated as admin. What an authorised operator can do."""
    async with _client({"Authorization": f"Bearer {TEST_ADMIN_TOKEN}"}) as c:
        yield c


@pytest_asyncio.fixture
async def client_scope_client(clean_db):
    """A CLIENT token only. Must reach /v1/* but never /admin/*."""
    async with _client({"Authorization": f"Bearer {TEST_CLIENT_TOKEN}"}) as c:
        yield c


@pytest_asyncio.fixture
async def raw_client(clean_db):
    """
    No credential at all.

    This fixture is the point of the whole arrangement: if every client in the
    suite were silently authenticated, the tests would pass whether or not the
    guard worked, and the security change would ship with zero real coverage.
    """
    async with _client() as c:
        yield c
