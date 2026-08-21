# SwitchBoard

**A highly available, multi-provider LLM operations gateway with semantic caching, automatic key rotation, and production-grade observability.**

SwitchBoard sits between your client applications and upstream LLM providers, offering a unified OpenAI-compatible API while reducing cost via semantic caching and improving reliability through intelligent multi-key routing with automatic failover.

---

## Features

- **OpenAI-Compatible API** — Drop-in `/v1/chat/completions` endpoint that works with any OpenAI client library.
- **Semantic Caching** — Embedding-based similarity cache (powered by Google Gemini embeddings + Redis) that returns cached responses for semantically similar prompts, saving tokens and latency.
- **Automatic Key Rotation** — Register multiple API keys per provider; the router picks the key with the most remaining quota and automatically fails over on 429 rate limits or auth errors.
- **Per-Request Provider Selection** — Optionally set `provider` in the request body to target a specific vendor.
- **Encrypted Key Storage** — API keys are encrypted at rest with Fernet (AES-128-CBC) and stored in SQLite.
- **Rate-Limit Awareness** — Parses provider rate-limit headers in real time, tracks per-key quotas, and runs a background sweeper to reset expired windows.
- **Admin API & Dashboard** — Full CRUD for API keys, provider health summaries, and stats via REST endpoints + a retro-industrial web dashboard (static HTML/CSS/JS served by nginx).
- **Prometheus + Grafana Observability** — Pre-configured dashboards tracking cache hit rates, provider latency, key switches, and token throughput.

---

## Tech Stack

| Layer               | Technology                                  |
| ------------------- | ------------------------------------------- |
| API Framework       | FastAPI + Uvicorn                           |
| Cache               | Redis 7 (async via `redis-py`)              |
| Embeddings          | Google Gemini (`gemini-embedding-001`)      |
| LLM Provider        | Groq, Google, Anthropic                      |
| Key Storage         | SQLite + Fernet encryption (`cryptography`) |
| Schemas / Validation| Pydantic v2                                 |
| Admin UI            | Static HTML/CSS/JS + nginx (reverse proxy)  |
| Metrics             | Prometheus + Grafana                        |
| HTTP Client         | HTTPX (async)                               |
| Testing             | pytest + pytest-asyncio                     |
| Containerisation    | Docker + Docker Compose                     |
| Language            | Python 3.11                                 |

---

## Architecture

```
┌──────────────┐
│  Client App  │
└──────┬───────┘
       │  POST /v1/chat/completions
       ▼
┌──────────────────────────────────────────────┐
│              SwitchBoard Gateway              │
│                                              │
│  ┌────────────┐   ┌───────────────────────┐  │
│  │  Semantic   │──▶│  Redis (embeddings +  │  │
│  │   Cache     │◀──│   cached responses)   │  │
│  └─────┬──────┘   └───────────────────────┘  │
│        │ miss                                │
│        ▼                                     │
│  ┌────────────┐   ┌───────────────────────┐  │
│  │   Router    │──▶│  Key Manager (SQLite  │  │
│  │  (failover) │◀──│   + Fernet encrypt)   │  │
│  └─────┬──────┘   └───────────────────────┘  │
│        │                                     │
│        ▼                                     │
│  ┌────────────┐                              │
│  │  Provider   │  Groq API                   │
│  │  Adapter    │─────────────────────────▶   │
│  └────────────┘                              │
└──────────────────────────────────────────────┘
       │
       ▼
┌──────────────┐   ┌──────────────┐
│  Prometheus  │──▶│   Grafana    │
└──────────────┘   └──────────────┘
```

---

## Prerequisites

- **Docker** and **Docker Compose v2** — that's all you need for the Quick Start below
- **Python 3.11+** — only for local development without Docker

Provider keys are optional at install time; you can add them any time from the Admin UI:

- **Groq** — [console.groq.com](https://console.groq.com) (chat completions)
- **Google AI** — [aistudio.google.com](https://aistudio.google.com) (semantic-cache embeddings)
- **Anthropic** — [console.anthropic.com](https://console.anthropic.com) (optional extra provider)

Without `GOOGLE_API_KEY` the gateway still starts and serves requests — it just runs with
the semantic cache disabled, and every response reports `X-Cache: MISS`.

---

## Quick Start (one command)

```bash
git clone https://github.com/<your-org>/switchboard.git
cd switchboard
./setup.sh
```

`setup.sh` verifies your Docker install, generates the Fernet `ENCRYPTION_KEY` for you,
prompts for any provider keys you want to seed, writes `.env`, brings the stack up, and
waits until every service reports healthy.

It is safe to re-run. Existing `.env` values are reused (never overwritten), and the file
is backed up only when something actually changes.

**Upgrading an existing checkout?** `GRAFANA_ADMIN_PASSWORD` is now required — a bare
`docker compose up` aborts with a named error until it is set. Re-run `./setup.sh` to
generate it; every value already in your `.env` is kept as-is.

| Flag                | Effect                                                       |
| ------------------- | ------------------------------------------------------------ |
| `--minimal`         | Gateway + Redis + Admin UI only (skips Prometheus & Grafana)  |
| `--yes`             | Non-interactive; reads keys from the environment or `.env`    |
| `--rebuild`         | Force a no-cache image rebuild                                |
| `--dry-run`         | Run all checks and write `.env`, but don't start containers   |
| `--keep-on-failure` | Leave containers running after a failure, for live debugging  |
| `--no-color`        | Plain output, no ANSI escapes                                 |

### Port conflicts

If a port it needs is already taken, setup **remaps** rather than fighting for it. It never
kills another process — including Docker itself, which owns every published port on macOS.

```
▲ Gateway port 8000 is in use by Python (pid 68964).
▲ Gateway moved to port 8001 (saved in .env).
```

The chosen ports are written to `.env` as `GATEWAY_PORT`, `ADMIN_UI_PORT`,
`PROMETHEUS_PORT` and `GRAFANA_PORT`, and the summary prints the real URLs. They persist
across runs so your URLs stay stable — edit `.env` to move a service back.

Containers left behind by an earlier interrupted run are *ours*, so setup clears them
automatically before starting (`docker compose down --remove-orphans`). Your database
volume is never touched.

### If setup fails

Containers started by the run are rolled back automatically, so a failed install never
leaves ports occupied. The full logs are written to `setup-failure-<timestamp>.log` first,
so the cleanup doesn't cost you the evidence. Use `--keep-on-failure` to debug live instead.

<details>
<summary>Manual setup (without the script)</summary>

```bash
cp .env.example .env
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# paste the result as ENCRYPTION_KEY in .env, then:
docker compose up --build
```

</details>

### Verify

| Service         | URL                          |
| --------------- | ---------------------------- |
| Gateway API     | http://localhost:8000        |
| Health Check    | http://localhost:8000/health  |
| API Docs (Swagger) | http://localhost:8000/docs |
| Admin UI        | http://localhost:3000         |
| Prometheus      | http://localhost:9090         |
| Grafana         | http://localhost:3001         |

Grafana logs in as `admin` with the password `setup.sh` generates into `.env` as
`GRAFANA_ADMIN_PASSWORD` and prints in the summary. Anonymous dashboard access is off.

---

## Local Development (without Docker)

### 1. Create a virtual environment

```bash
python3.11 -m venv .venv
source .venv/bin/activate
```

### 2. Install dependencies

```bash
pip install -r requirements.txt
```

### 3. Start Redis

```bash
# Using Docker
docker run -d --name switchboard-redis -p 6379:6379 redis:7-alpine

# Or use a locally installed Redis
redis-server
```

### 4. Set environment variables

```bash
export GROQ_API_KEY="gsk_..."
export GOOGLE_API_KEY="AIza..."
export ANTHROPIC_API_KEY="sk-ant-..."
export ENCRYPTION_KEY="$(python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
export REDIS_URL="redis://localhost:6379/0"

# Required. The gateway refuses to start without these — an unset token must
# never silently mean "no authentication". setup.sh generates them for you on
# the Docker path; on this path, generate them yourself:
export ADMIN_TOKENS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export CLIENT_TOKENS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"

# Print them — you will need the admin token to unlock the dashboard.
echo "admin:  $ADMIN_TOKENS"
echo "client: $CLIENT_TOKENS"
```

**Authentication.** Every route except `/health` requires a bearer token.
`ADMIN_TOKENS` guards `/admin/*` and `/openapi.json` and also works on `/v1/*`;
`CLIENT_TOKENS` guards `/v1/*` only, so a client token can never read or modify
your provider keys. Both accept a comma-separated list, so you can rotate
without downtime: add the new token, migrate callers, then remove the old one.

### 5. Run the gateway

```bash
uvicorn gateway.main:app --host 0.0.0.0 --port 8000 --reload
```

---

## Usage

### Send a Chat Completion Request

SwitchBoard exposes an OpenAI-compatible endpoint, so any standard OpenAI client works:

```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer $CLIENT_TOKENS" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b-instant",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "temperature": 0.7,
    "provider": "groq"
  }'
```

**Response headers** include cache and routing metadata:

| Header                  | Description                                         |
| ----------------------- | --------------------------------------------------- |
| `X-Cache`               | `HIT` if served from semantic cache, `MISS` otherwise |
| `X-Semantic-Similarity` | Cosine similarity score of the closest cached prompt |
| `X-Provider`            | The provider that served the request                |
| `X-Latency-Ms`          | Provider response time in milliseconds              |

The cache matches on meaning, not on exact text. Asking the same thing a different way
still hits:

```text
"Say hi in five words."     → X-Cache: MISS   X-Provider: groq   X-Latency-Ms: 424.0
"Say hi in five words."     → X-Cache: HIT    X-Semantic-Similarity: 1.0000
"Greet me using five words."→ X-Cache: HIT    X-Semantic-Similarity: 0.9144
```

### Using the Python OpenAI Client

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="not-needed",  # auth is handled by SwitchBoard
)

response = client.chat.completions.create(
    model="llama-3.1-8b-instant",
    messages=[{"role": "user", "content": "Explain quantum computing in one sentence."}],
)
print(response.choices[0].message.content)
```

---

## Admin API

All admin endpoints are mounted under `/admin`. Full interactive docs are available at `/docs`.

| Method   | Endpoint               | Description                                |
| -------- | ---------------------- | ------------------------------------------ |
| `POST`   | `/admin/keys`          | Add a new API key for a provider           |
| `GET`    | `/admin/keys`          | List all keys (masked), filter by provider |
| `DELETE` | `/admin/keys/{key_id}` | Delete a key by ID                         |
| `PATCH`  | `/admin/keys/{key_id}` | Enable or disable a key                    |
| `GET`    | `/admin/providers`     | List providers with key counts and health  |
| `GET`    | `/admin/stats`         | Key totals and rate-limit status           |

### Example: Add a new API key

```bash
curl -X POST http://localhost:8000/admin/keys \
  -H "Authorization: Bearer $ADMIN_TOKENS" \
  -H "Content-Type: application/json" \
  -d '{"provider": "groq", "api_key": "gsk_...", "label": "personal-key"}'
```

---

## Observability

### Prometheus Metrics

The gateway auto-exposes metrics at `/metrics`. Key counters and histograms:

| Metric                                  | Type      | Description                          |
| --------------------------------------- | --------- | ------------------------------------ |
| `switchboard_cache_hits_total`          | Counter   | Semantic cache hits                  |
| `switchboard_cache_misses_total`        | Counter   | Semantic cache misses                |
| `switchboard_provider_requests_total`   | Counter   | Requests per provider/key/status     |
| `switchboard_provider_latency_seconds`  | Histogram | Provider response latency            |
| `switchboard_key_switches_total`        | Counter   | Key rotation events                  |
| `switchboard_tokens_processed_total`    | Counter   | Tokens processed (input / output)    |
| `switchboard_active_keys`              | Gauge     | Enabled keys per provider            |

### Grafana

A pre-built dashboard is provisioned automatically when running via Docker Compose. Access it at [http://localhost:3001](http://localhost:3001) and log in as `admin` with `GRAFANA_ADMIN_PASSWORD` from `.env`.

---

## Running Tests

```bash
# Run the full test suite
pytest

# Run a specific test file
pytest tests/test_routing.py
pytest tests/test_provider_routing.py

# Run with verbose output
pytest -v
```

Test modules:

| File                        | Coverage Area                        |
| --------------------------- | ------------------------------------ |
| `tests/test_admin_api.py`   | Admin CRUD endpoints                 |
| `tests/test_key_manager.py` | Key encryption, rotation, rate limits|
| `tests/test_routing.py`     | Router failover and key selection    |
| `tests/test_semantic_cache.py` | Embedding-based cache logic       |
| `tests/test_provider_routing.py` | Provider selection via request  |
| `tests/test_token_exhaustion.py` | Rate-limit exhaustion scenarios |

---

## Project Structure

```
switchboard/
├── gateway/
│   ├── main.py              # FastAPI app, lifespan, /v1/chat/completions
│   └── admin.py             # Admin API router (/admin/*)
├── core/
│   ├── config.py            # Pydantic settings (env vars)
│   ├── database.py          # SQLite async setup
│   ├── key_manager.py       # Key CRUD, encryption, rate-limit tracking
│   ├── metrics.py           # Prometheus metric definitions
│   └── schemas.py           # Pydantic models (request/response)
├── routing/
│   └── router.py            # Key-availability-based routing + failover
├── providers/
│   ├── base.py              # Abstract LLMProvider interface
│   └── groq_provider.py     # Groq (OpenAI-compatible) adapter
├── cache/
│   └── redis_client.py      # Semantic cache (embeddings + Redis)
├── vis/
│   ├── index.html            # Static web dashboard (retro-industrial UI)
│   ├── default.conf.template # nginx config with reverse proxy to gateway
│   └── Dockerfile           # nginx:alpine dashboard container
├── prometheus/
│   └── prometheus.yml       # Prometheus scrape config
├── grafana/
│   ├── dashboards/          # Pre-built Grafana dashboard JSON
│   └── provisioning/        # Auto-provisioning for datasources & dashboards
├── tests/                   # pytest test suite
├── docker-compose.yml       # Full-stack orchestration
├── Dockerfile               # Gateway container
├── requirements.txt         # Python dependencies
└── project_info.md          # Detailed technical documentation
```

---

## Environment Variables

| Variable          | Required | Default                    | Description                                      |
| ----------------- | -------- | -------------------------- | ------------------------------------------------ |
| `ENCRYPTION_KEY`  | Yes      | —                          | Fernet key for encrypting API keys at rest        |
| `ADMIN_TOKENS`    | Yes      | —                          | Comma-separated. Guards `/admin/*` + `/openapi.json`; also valid on `/v1/*` |
| `CLIENT_TOKENS`   | Yes      | —                          | Comma-separated. Guards `/v1/*` only              |
| `REDIS_PASSWORD`  | Yes      | —                          | Redis `requirepass`; required by docker compose   |
| `GROQ_API_KEY`    | No       | `""`                       | Default Groq key (can also add via Admin API)     |
| `GOOGLE_API_KEY`  | No       | `""`                       | Google AI key for embedding generation            |
| `ANTHROPIC_API_KEY` | No     | `""`                       | Anthropic API key for provider routing            |
| `SWITCHBOARD_PROVIDER` | No  | `"groq"`                  | Default provider when request omits `provider`    |
| `REDIS_URL`       | No       | `redis://localhost:6379/0` | Redis connection URL                              |
| `SQLITE_DB_PATH`  | No       | `data/switchboard.db`      | Path to the SQLite database file                  |
| `PORT`            | No       | `8000`                     | Gateway listen port *inside* the container        |
| `HOST`            | No       | `0.0.0.0`                  | Gateway bind address                              |

### Host port mappings

These control the ports published on your machine by Docker Compose. `setup.sh` sets them
automatically, remapping any that are already in use; set them yourself to pin a service.

| Variable           | Default | Service    |
| ------------------ | ------- | ---------- |
| `GATEWAY_PORT`     | `8000`  | Gateway    |
| `ADMIN_UI_PORT`    | `3000`  | Admin UI   |
| `REDIS_PASSWORD`   | generated | Redis auth — required by docker compose |
| `GRAFANA_ADMIN_PASSWORD` | generated | Grafana admin login — required by docker compose |
| `PROMETHEUS_PORT`  | `9090`  | Prometheus |
| `GRAFANA_PORT`     | `3001`  | Grafana    |

---

## License

This project is provided as-is for educational and internal use.
