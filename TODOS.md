# TODOS

## Security

### Guard or unpublish `/metrics`

**What:** Put the admin guard on `/metrics`, or drop the gateway's published host port so only Prometheus reaches it over the compose network.

**Why:** After the auth PR, `/metrics` and `/health` are the only unauthenticated routes on the gateway. `/metrics` exposes per-endpoint request counts, latency histograms, and the `ACTIVE_KEYS` gauge per provider — enough to infer traffic volume, which providers are in use, and how many keys are held.

**Context:** Mounted at `gateway/main.py:101` via `Instrumentator().instrument(app).expose(app, endpoint="/metrics")`. `prometheus/prometheus.yml` scrapes `gateway:8000/metrics` over the internal Docker network and does not need the published host port. Two possible shapes: (a) guard the route and add bearer-token scrape config to `prometheus.yml`, which means keeping a token in sync in a second place; or (b) delete the gateway `ports:` mapping in `docker-compose.yml:4-5`, which is cheaper but breaks direct API clients and the post-install curl at `setup.sh:751-755`. Option (b) only works if nobody calls the gateway from the host.

**Effort:** S
**Priority:** P2
**Depends on:** None

### Narrow the compose bind-mount so `.env` is not inside the container

**What:** Replace `volumes: - .:/app` with a dev/prod compose split so the production gateway container does not mount the whole repo.

**Why:** That mount carries `ENCRYPTION_KEY`, every provider key, and (after the auth PR) `ADMIN_TOKENS` and `CLIENT_TOKENS` into the container filesystem. Any code execution inside the gateway reads every secret in the project, including the Fernet key that decrypts the key database — which defeats the encryption-at-rest in `core/key_manager.py`.

**Context:** `docker-compose.yml:16-18`. The bind-mount exists for hot-reload during development; `Dockerfile` already copies the application in, so it is a dev-convenience layer rather than a requirement. `.dockerignore` does not apply to bind-mounts. Likely shape: keep `docker-compose.yml` production-clean and add a `docker-compose.override.yml` carrying the bind-mount for local dev, which Compose merges automatically.

**Effort:** M
**Priority:** P2
**Depends on:** None, but easiest alongside a dev/prod compose split

### Per-caller rate limiting on `/v1/chat/completions`

**What:** Rate-limit completion requests per client token.

**Why:** Authentication answers "may you call this?" but not "how much?" A leaked or misbehaving client token can still exhaust the entire Groq and Google quota at full speed. The auth PR is what makes this possible at all — before it there was no caller identity to limit against.

**Context:** Substantial counting machinery already exists but is pointed at provider keys rather than callers: `core/key_manager.py` parses provider rate-limit headers into `rate_limit_remaining_tokens` / `rate_limit_remaining_requests`, and `core/database.py` maintains usage buckets queryable via `get_usage_stats(minutes=...)` with a background cleanup at `gateway/main.py:67-78`. Redis is already a dependency and is the natural counter store. Open policy question: one global limit, or per-token limits configured alongside the token itself — the latter argues for eventually moving tokens into the DB (see the virtual-keys idea rejected during the auth review).

**Effort:** M
**Priority:** P2
**Depends on:** Gateway auth PR (caller identity)

## Testing

### Closing the DB singleton poisons every test that runs after it

**What:** Stop `await db.close()` in test fixtures from breaking the rest of the suite — either by removing it from the four fixtures that call it, or by making `get_db()` reopen a closed connection.

**Why:** The suite is effectively non-functional. Measured on `main` at commit `7677d31`: **0 passed, 2 failed, 31 errors**. Nearly every error is `ValueError: no active connection`. This is not an auth problem — it predates the auth branch entirely.

**Context:** `core/database.py:64-71` caches the connection in a module-level `_db_conn` singleton and returns it without checking whether it is still open:

```python
async def get_db() -> aiosqlite.Connection:
    global _db_conn
    if _db_conn is not None:
        return _db_conn          # no liveness check
```

`tests/test_key_manager.py`, `tests/test_routing.py`, `tests/test_provider_routing.py`, and `tests/test_usage_tracking.py` each close the connection in their own fixture. The first one to do so leaves `_db_conn` pointing at a dead object, and every subsequent `get_db()` — in any test file — returns it.

Two possible fixes:
1. **Test-side (smaller):** drop `await db.close()` from those four fixtures, matching what `tests/conftest.py` now does. Note that something must still close the connection once at session end or the interpreter hangs at exit on aiosqlite's non-daemon thread — `conftest.py` has a session-scoped fixture for exactly this, so the four files could simply rely on it.
2. **Source-side (more robust):** have `get_db()` detect a closed connection and reopen, which makes the singleton resilient regardless of caller behaviour.

The auth branch (`security/gateway-auth-hardening`) took approach 1 for the two files it touches, bringing the suite to 56 passed / 1 failed / 25 errors. The remaining 25 errors are the four untouched files.

**Effort:** S
**Priority:** P1
**Depends on:** None

## Performance

### Replace the semantic cache keyspace scan with a vector index

**What:** Stop scanning and downloading the entire Redis keyspace on every completion request.

**Why:** Every cache lookup issues `KEYS nexus:cache:*`, then one `GET` per key, then computes cosine similarity in Python for each. That is O(cache size) network round trips plus O(cache size) numpy operations before the request can even be routed. `KEYS` additionally blocks the whole Redis server for the duration of the scan, so one slow lookup degrades every other caller. Cost grows silently as the cache fills.

**Context:** `cache/redis_client.py:72-90`, and the existing comment at `:70-71` already flags it as an MVP shortcut. Entries are written at `:132` with a 1h TTL, so the keyspace grows with every unique prompt. Note the security link: before the auth PR this was also a DoS amplification vector — an anonymous caller could inflate the keyspace with unique prompts and slow every subsequent request. Authentication closed the attacker-driven half; the performance ceiling for legitimate traffic remains.

Two increments, in order:
1. **Cheap:** swap `KEYS` for `SCAN` (two lines). Removes the server-blocking behaviour. Does not reduce the O(N) fetch-and-compare.
2. **Real:** Redis Stack with a vector index, so similarity search is one indexed query. Requires a new Redis image, an index schema, and a migration path for existing cache entries.

**Effort:** S (step 1) / L (step 2)
**Priority:** P2
**Depends on:** None
