# TODOS

## Security

### Per-caller rate limiting on `/v1/chat/completions`

**What:** Rate-limit completion requests per client token.

**Why:** Authentication answers "may you call this?" but not "how much?" A leaked or misbehaving client token can still exhaust the entire Groq and Google quota at full speed. The auth PR is what makes this possible at all — before it there was no caller identity to limit against.

**Context:** Substantial counting machinery already exists but is pointed at provider keys rather than callers: `core/key_manager.py` parses provider rate-limit headers into `rate_limit_remaining_tokens` / `rate_limit_remaining_requests`, and `core/database.py` maintains usage buckets queryable via `get_usage_stats(minutes=...)` with a background cleanup at `gateway/main.py:67-78`. Redis is already a dependency and is the natural counter store. Open policy question: one global limit, or per-token limits configured alongside the token itself — the latter argues for eventually moving tokens into the DB (see the virtual-keys idea rejected during the auth review).

**Effort:** M
**Priority:** P2
**Depends on:** Gateway auth PR (caller identity)

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
