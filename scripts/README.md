# scripts/

Operator tools. Neither of these runs as part of the gateway, and neither is
included in the Docker image (see `.dockerignore`). You run them from the host,
against a gateway you control.

---

## `verify-hardening.sh`

Asserts the deployment hardening is still in place on a running stack: that the
repo is not bind-mounted into the gateway container, that `/metrics` refuses a
client token, that Grafana requires a login, and that CORS does not send
credentials cross-origin.

```bash
./scripts/verify-hardening.sh
```

Reads `ADMIN_TOKENS` and `CLIENT_TOKENS` from the environment. Run it after any
change to `docker-compose.yml`, `vis/default.conf.template`, or the auth layer.

---

## `token_exhaustion.py`

A load generator that drives **your own** gateway hard enough to exhaust a
provider key's rate limit, so you can watch automatic key rotation happen.

### Why it exists

`routing/router.py` fails over to the next key when a provider returns 429. That
path is difficult to exercise deliberately — you have to actually burn a real
provider quota to reach it. Unit tests cover the logic with mocks
(`tests/test_token_exhaustion.py`), but only real traffic proves the provider
returns the rate-limit headers `core/key_manager.py` expects to parse.

It sends large, deliberately distinct prompts so the semantic cache misses and
real tokens get consumed. Rough arithmetic: at a 250K tokens-per-minute quota and
~8K tokens per request, roughly 30 requests will exhaust one key.

### Running it

```bash
export CLIENT_TOKENS=...        # required — /v1/* rejects unauthenticated calls
export ADMIN_TOKENS=...         # optional — enables the key-state readout
python scripts/token_exhaustion.py --requests 30
```

Options:

| Flag | Default | |
|---|---|---|
| `--url` | `http://localhost:8000` | Gateway base URL |
| `--model` | `llama-3.1-8b-instant` | Model to request |
| `--requests` | `30` | How many completions to send |
| `--context-tokens` | `6000` | Approximate filler context per request |
| `--client-token` | `$CLIENT_TOKENS` | Falls back to the first entry of the env var |
| `--admin-token` | `$ADMIN_TOKENS` | Falls back to the first entry of the env var |
| `--timeout` | `60` | Per-request timeout, seconds |

### Reading the output

It ends with one of four verdicts:

- **`ROTATION OBSERVED`** — a 429 was hit and later requests still succeeded. The
  gateway moved to another key. This is the outcome you are looking for.
- **`NO ROTATION`** with rate limits hit — every key is exhausted. Add another key,
  or wait for the window to reset.
- **`NO ROTATION`** with no rate limits — you did not send enough traffic. Raise
  `--requests`.
- **`GATEWAY UNREACHABLE`** — nothing answered. Check the gateway is up.

### Please read before running

- **Only point this at a gateway you own.** It exists to consume your own quota.
- **It costs real money** if your provider keys are on a paid plan. Every request
  is a genuine upstream call; the prompts are unique specifically so the cache
  cannot absorb them.
- It will leave keys marked exhausted until their rate-limit window resets. That
  is the point, but do not run it against anything you need working right now.

### Note on a previous version

An earlier version read a ~6K-token file from `tests/` that was never committed,
so it crashed on import for anyone who cloned the repo, and it called
`/admin/keys` with no `Authorization` header, which stopped working when gateway
authentication landed. Both are fixed: the context is generated rather than read
from disk, and both endpoints are called with the right credentials.
