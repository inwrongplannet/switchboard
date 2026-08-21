#!/usr/bin/env bash
#
# Asserts the gateway's security posture against a RUNNING stack.
#
# These are the claims that cannot be checked from inside pytest, because they
# are about the real containers and the real host network rather than an ASGI
# transport: which ports are bound, whether Redis actually authenticates, and
# whether a cross-origin request gets a CORS header.
#
# Re-run this after ANY change to docker-compose.yml. Re-adding the Redis
# ports: mapping is a three-character edit that silently reopens the cache to
# the whole host; this script is what turns that into a loud failure.
#
#   ./scripts/verify-hardening.sh
#
# Reads GATEWAY_PORT / ADMIN_TOKENS / CLIENT_TOKENS from .env unless already
# exported. Exits non-zero on the first failed assertion.

set -uo pipefail

ENV_FILE="${ENV_FILE:-.env}"
PASS=0
FAIL=0

if [[ -t 1 ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; RESET=""
fi

read_env_value() {
    [[ -f "$ENV_FILE" ]] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1
}

pass() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"
    [[ $# -gt 1 ]] && printf '    %s%s%s\n' "$DIM" "$2" "$RESET"
    FAIL=$((FAIL + 1))
}

GATEWAY_PORT="${GATEWAY_PORT:-$(read_env_value GATEWAY_PORT)}"
GATEWAY_PORT="${GATEWAY_PORT:-8000}"
BASE="http://localhost:${GATEWAY_PORT}"

ADMIN_TOKENS="${ADMIN_TOKENS:-$(read_env_value ADMIN_TOKENS)}"
CLIENT_TOKENS="${CLIENT_TOKENS:-$(read_env_value CLIENT_TOKENS)}"
# Only the first entry is needed; the rest exist for rotation.
ADMIN_TOKEN="${ADMIN_TOKENS%%,*}"
CLIENT_TOKEN="${CLIENT_TOKENS%%,*}"

printf '\n%sVerifying gateway hardening at %s%s\n\n' "$BOLD" "$BASE" "$RESET"

if [[ -z "$ADMIN_TOKEN" ]]; then
    fail "No ADMIN_TOKENS found in environment or $ENV_FILE" \
         "Run ./setup.sh, or export ADMIN_TOKENS before this script."
    printf '\n%s%d passed, %d failed%s\n\n' "$BOLD" "$PASS" "$FAIL" "$RESET"
    exit 1
fi

# status <method> <path> [header...]
status() {
    local method="$1" path="$2"; shift 2
    curl -s -o /dev/null -w '%{http_code}' -X "$method" "${BASE}${path}" \
        --max-time 10 "$@" 2>/dev/null
}

# ---- 1. Redis must not be reachable from the host ------------------------
REDIS_PORT_CHECK="${REDIS_PORT_CHECK:-6379}"
if command -v nc >/dev/null 2>&1; then
    if nc -z -G 2 localhost "$REDIS_PORT_CHECK" 2>/dev/null || \
       nc -z -w 2 localhost "$REDIS_PORT_CHECK" 2>/dev/null; then
        fail "Redis is listening on host port ${REDIS_PORT_CHECK}" \
             "Remove the ports: mapping from the redis service in docker-compose.yml."
    else
        pass "Redis is not reachable from the host (port ${REDIS_PORT_CHECK} closed)"
    fi
else
    printf '  %s- skipped host-port check (nc not installed)%s\n' "$DIM" "$RESET"
fi

# ---- 2. /health is open and reports cache liveness -----------------------
HEALTH_BODY="$(curl -s --max-time 10 "${BASE}/health" 2>/dev/null)"
if [[ "$(status GET /health)" == "200" ]]; then
    pass "/health answers without a credential (healthchecks keep working)"
else
    fail "/health did not return 200" "Docker healthchecks depend on this staying open."
fi

# A closed port proves Redis is not exposed; it does NOT prove Redis works.
# Without this, a wrong REDIS_PASSWORD looks identical to a healthy stack.
case "$HEALTH_BODY" in
    *'"cache":"ok"'*|*'"cache": "ok"'*)
        pass "Redis is authenticated and the semantic cache is live" ;;
    *'"cache":"unavailable"'*|*'"cache": "unavailable"'*)
        fail "Gateway cannot reach Redis" \
             "Check REDIS_PASSWORD matches between the gateway and redis services." ;;
    *)
        fail "/health did not report cache status" \
             "Expected a \"cache\" field. Is this gateway running the hardened build?" ;;
esac

# ---- 3. Admin API rejects anonymous callers -----------------------------
for path in /admin/keys /admin/stats /admin/providers /admin/keys/usage; do
    code="$(status GET "$path")"
    if [[ "$code" == "401" ]]; then
        pass "${path} rejects an anonymous request (401)"
    else
        fail "${path} returned ${code}, expected 401" \
             "Anyone who can reach this port can read or modify your provider keys."
    fi
done

# ---- 4. Admin API accepts a valid admin token ---------------------------
code="$(status GET /admin/stats -H "Authorization: Bearer ${ADMIN_TOKEN}")"
if [[ "$code" == "200" ]]; then
    pass "/admin/stats accepts a valid admin token (200)"
else
    fail "/admin/stats returned ${code} with a valid admin token" \
         "The guard is rejecting legitimate callers — check ADMIN_TOKENS in .env."
fi

# ---- 5. Scope separation is real ----------------------------------------
if [[ -n "$CLIENT_TOKEN" ]]; then
    code="$(status GET /admin/stats -H "Authorization: Bearer ${CLIENT_TOKEN}")"
    if [[ "$code" == "403" ]]; then
        pass "A client token cannot reach /admin (403)"
    else
        fail "/admin/stats returned ${code} for a client token, expected 403" \
             "The two scopes are decorative if a client token opens the admin API."
    fi
fi

# ---- 6. Completions require a credential --------------------------------
code="$(status POST /v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"x","messages":[{"role":"user","content":"hi"}]}')"
if [[ "$code" == "401" ]]; then
    pass "/v1/chat/completions rejects an anonymous request (401)"
else
    fail "/v1/chat/completions returned ${code}, expected 401" \
         "Anyone who can reach this port can spend your provider quota."
fi

# ---- 7. OpenAPI schema is not anonymously readable ----------------------
code="$(status GET /openapi.json)"
if [[ "$code" == "401" ]]; then
    pass "/openapi.json requires a credential (401)"
else
    fail "/openapi.json returned ${code}, expected 401" \
         "The full admin API map, including request bodies, is readable anonymously."
fi

# ---- 8. No CORS headers on a cross-origin request ------------------------
#
# The Origin header is MANDATORY here. CORSMiddleware only emits
# Access-Control-Allow-Origin in response to a request that carries Origin, so
# checking without it passes against the old vulnerable config and proves
# nothing whatsoever.
HEADERS="$(curl -s -D - -o /dev/null --max-time 10 \
    -H 'Origin: https://evil.test' "${BASE}/health" 2>/dev/null)"
if printf '%s' "$HEADERS" | grep -qi '^access-control-allow-origin'; then
    got="$(printf '%s' "$HEADERS" | grep -i '^access-control-allow-origin' | tr -d '\r')"
    fail "Gateway sent a CORS header to a cross-origin request" "$got"
else
    pass "No Access-Control-Allow-Origin sent to https://evil.test"
fi

if printf '%s' "$HEADERS" | grep -qi '^access-control-allow-credentials'; then
    fail "Gateway sent Access-Control-Allow-Credentials to a cross-origin request"
else
    pass "No Access-Control-Allow-Credentials sent to a cross-origin request"
fi

# ---- 9. Grafana requires a login ----------------------------------------
#
# Static check first: the compose file is the only place anonymous access can
# come back from, and it is a one-line edit. The live check below only runs if
# Grafana is actually up, so --minimal stacks don't fail here.
if grep -qE '^[[:space:]]*-[[:space:]]*GF_AUTH_ANONYMOUS_ENABLED=true' docker-compose.yml 2>/dev/null; then
    fail "docker-compose.yml re-enables Grafana anonymous access" \
         "Remove GF_AUTH_ANONYMOUS_ENABLED=true from the grafana service."
else
    pass "docker-compose.yml does not enable Grafana anonymous access"
fi

if grep -qE '^[[:space:]]*-[[:space:]]*GF_SECURITY_ADMIN_PASSWORD=[^$]' docker-compose.yml 2>/dev/null; then
    fail "Grafana admin password is hardcoded in docker-compose.yml" \
         "Use \${GRAFANA_ADMIN_PASSWORD:?...} and let ./setup.sh generate it."
else
    pass "Grafana admin password comes from the environment, not the compose file"
fi

GRAFANA_PORT="${GRAFANA_PORT:-$(read_env_value GRAFANA_PORT)}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"
GRAFANA_BASE="http://localhost:${GRAFANA_PORT}"
# /api/search is 200 for an anonymous viewer and 401 when a login is required.
gf_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${GRAFANA_BASE}/api/search" 2>/dev/null)"
case "$gf_code" in
    401)  pass "Grafana requires a login (/api/search returns 401)" ;;
    000)  printf '  %s- skipped live Grafana check (nothing listening on %s)%s\n' "$DIM" "$GRAFANA_PORT" "$RESET" ;;
    *)    fail "Grafana /api/search returned ${gf_code}, expected 401" \
               "Anyone who reaches port ${GRAFANA_PORT} can read every dashboard." ;;
esac

# ---- summary -------------------------------------------------------------
printf '\n'
if [[ $FAIL -eq 0 ]]; then
    printf '%s%s%d passed, 0 failed%s — posture verified.\n\n' "$BOLD" "$GREEN" "$PASS" "$RESET"
    exit 0
fi
printf '%s%s%d passed, %d failed%s\n\n' "$BOLD" "$RED" "$PASS" "$FAIL" "$RESET"
exit 1
