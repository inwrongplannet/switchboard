#!/usr/bin/env bash
#
# SwitchBoard — one-command setup
#
#   ./setup.sh              interactive setup + launch
#   ./setup.sh --help       all options
#
# Safe to re-run: existing .env values are reused and backed up, never clobbered.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

readonly ENV_FILE=".env"
readonly ENV_EXAMPLE=".env.example"
# Bind-mounted into the Prometheus container, which authenticates its scrape of
# the admin-guarded /metrics. Holds a copy of the first ADMIN_TOKENS entry, so
# it is gitignored and chmod 600 like .env.
readonly SCRAPE_TOKEN_FILE="prometheus/scrape_token"
readonly HEALTH_TIMEOUT=150   # seconds to wait for the gateway to answer /health

# Host ports, as "ENV_VAR:default:label". Each is overridable in .env, so a busy
# port is remapped rather than fought over. Container-internal ports never change.
# REDIS_PORT is deliberately absent: Redis is no longer published to the host
# (see docker-compose.yml), so there is no host port to resolve. Leaving it here
# would make resolve_ports probe a port nothing binds and, in interactive mode,
# die if the user declined to remap it — setup refusing to run over a phantom
# conflict.
PORT_SPECS=(
    "GATEWAY_PORT:8000:Gateway"
    "ADMIN_UI_PORT:3000:Admin UI"
    "PROMETHEUS_PORT:9090:Prometheus"
    "GRAFANA_PORT:3001:Grafana"
)
# Deliberately NOT pre-initialised: resolve_ports reads each name with ${!var:-},
# so assigning defaults here would shadow both an exported override and the value
# saved in .env, and the script would silently ignore the user's chosen port.
CHOSEN_PORTS=""
GATEWAY_URL="http://localhost:8000"
ENV_SNAPSHOT=""

# Flags
ASSUME_YES=0
MINIMAL=0
REBUILD=0
DRY_RUN=0
USE_COLOR=1
KEEP_ON_FAILURE=0

# Runtime state
COMPOSE=""
STEP=0
TOTAL_STEPS=5
LAUNCHED=0        # set once we've asked Compose to start containers
SERVICES=()
WARNINGS=()

# ─────────────────────────────────────────────────────────────────────────────
# Style
# ─────────────────────────────────────────────────────────────────────────────

setup_colors() {
    if [[ $USE_COLOR -eq 0 ]] || [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]] || [[ "${TERM:-dumb}" == "dumb" ]]; then
        BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" MAGENTA="" GREY=""
        USE_COLOR=0
    else
        BOLD=$'\033[1m'    DIM=$'\033[2m'     RESET=$'\033[0m'
        RED=$'\033[31m'    GREEN=$'\033[32m'  YELLOW=$'\033[33m'
        BLUE=$'\033[34m'   CYAN=$'\033[36m'   MAGENTA=$'\033[35m'
        GREY=$'\033[90m'
    fi

    # Unicode is safe on modern terminals (and when the locale is simply unset);
    # only fall back when the locale explicitly names a non-UTF-8 charset.
    local locale_hint="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ -z "$locale_hint" || "$locale_hint" == *[Uu][Tt][Ff]* ]]; then
        TICK="✔" CROSS="✘" WARN="▲" ARROW="→" BULLET="•"
        SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
        UNICODE=1
    else
        TICK="OK" CROSS="XX" WARN="!!" ARROW="->" BULLET="*"
        SPIN_FRAMES=('|' '/' '-' '\')
        UNICODE=0
    fi
}

banner() {
    if [[ $UNICODE -eq 0 ]]; then
        printf '\n%s== SWITCHBOARD ==%s\n' "$BOLD" "$RESET"
        printf '%sSelf-hosted LLM gateway%s\n\n' "$DIM" "$RESET"
        return
    fi

    local art=(
'████ █   █ ███ ███ ████ █  █ ███  ████ ████ ████ ███ '
'█    █   █  █   █  █    █  █ █  █ █  █ █  █ █  █ █  █'
'████ █ █ █  █   █  █    ████ ███  █  █ ████ ███  █  █'
'   █ ██ ██  █   █  █    █  █ █  █ █  █ █  █ █ █  █  █'
'████ █   █ ███  █  ████ █  █ ███  ████ █  █ █  █ ███ '
    )
    # Vertical gradient: cyan → blue.
    local grad=("$CYAN" "$CYAN" "$BLUE" "$BLUE" "$BLUE")

    printf '\n'
    local i
    for i in "${!art[@]}"; do
        printf '  %s%s%s%s\n' "$BOLD" "${grad[$i]}" "${art[$i]}" "$RESET"
    done
    printf '\n  %sOpen-source LLM gateway%s %s%s%s %ssemantic cache %s smart routing %s observability%s\n\n' \
        "$BOLD" "$RESET" "$GREY" "$BULLET" "$RESET" "$DIM" "$BULLET" "$BULLET" "$RESET"
}

step()    { STEP=$((STEP + 1)); printf '\n%s%s[%d/%d]%s %s%s%s\n' "$BOLD" "$MAGENTA" "$STEP" "$TOTAL_STEPS" "$RESET" "$BOLD" "$1" "$RESET"; }
ok()      { printf '  %s%s%s %s\n' "$GREEN" "$TICK" "$RESET" "$1"; }
info()    { printf '  %s%s%s %s\n' "$CYAN" "$BULLET" "$RESET" "$1"; }
note()    { printf '    %s%s%s\n' "$GREY" "$1" "$RESET"; }
warn()    { printf '  %s%s%s %s\n' "$YELLOW" "$WARN" "$RESET" "$1"; WARNINGS+=("$1"); }
fail()    { printf '  %s%s%s %s\n' "$RED" "$CROSS" "$RESET" "$1" >&2; }

# Leave no scratch files behind, however we exit.
cleanup_temp() {
    [[ -n "${ENV_SNAPSHOT:-}" && -f "${ENV_SNAPSHOT:-}" ]] && rm -f "$ENV_SNAPSHOT"
    return 0
}

# Undo a failed launch. Anything running at this point was started by *this* run —
# preflight already cleared any pre-existing stack — so tearing it down is safe and
# never touches containers we didn't create. Logs are kept so the rollback doesn't
# cost you the evidence.
cleanup_failed_launch() {
    [[ $LAUNCHED -eq 1 ]] || return 0
    [[ $DRY_RUN -eq 1 ]] && return 0
    LAUNCHED=0   # never run twice

    if [[ $KEEP_ON_FAILURE -eq 1 ]]; then
        printf '  %s%s%s Containers left running (--keep-on-failure). Inspect with:\n' "$CYAN" "$BULLET" "$RESET"
        printf '    %s%s logs -f gateway%s\n' "$GREY" "$COMPOSE" "$RESET"
        return 0
    fi

    local logfile="setup-failure-$(date +%Y%m%d-%H%M%S).log"
    $COMPOSE logs --no-color > "$logfile" 2>&1 || true

    # A single `down` can lose a race: if an interrupted `up` is still mid-flight it
    # keeps creating containers behind us. Tear down until nothing is left.
    local attempt=0
    while [[ $attempt -lt 3 ]]; do
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
        [[ -z "$($COMPOSE ps -aq 2>/dev/null || true)" ]] && break
        sleep 2
        attempt=$((attempt + 1))
    done

    if [[ -z "$($COMPOSE ps -aq 2>/dev/null || true)" ]]; then
        printf '  %s%s%s Rolled back — every container this run started has been removed.\n' "$CYAN" "$BULLET" "$RESET"
        printf '    %sFull logs saved to %s%s%s\n' "$GREY" "$BOLD" "$logfile" "$RESET"
        printf '    %sKeep them running next time with: ./setup.sh --keep-on-failure%s\n' "$GREY" "$RESET"
    else
        printf '  %s%s%s Rollback was incomplete — clean up manually with: %s%s down%s\n' \
            "$YELLOW" "$WARN" "$RESET" "$BOLD" "$COMPOSE" "$RESET"
    fi
}

die() {
    cleanup_failed_launch
    printf '\n%s%s Setup stopped.%s %s\n\n' "$BOLD$RED" "$CROSS" "$RESET" "$1" >&2
    [[ $# -gt 1 ]] && printf '%sFix:%s %s\n\n' "$BOLD" "$RESET" "$2" >&2
    cleanup_temp
    # This is a handled, explained exit — don't let the crash handler fire on top of it.
    trap - EXIT
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}SwitchBoard setup${RESET}

  ${DIM}Checks your Docker install, writes .env, and brings the stack up.${RESET}

${BOLD}USAGE${RESET}
  ./setup.sh [options]

${BOLD}OPTIONS${RESET}
  -y, --yes        Non-interactive. Reuse .env / environment values, prompt for nothing.
      --minimal    Gateway + Redis + Admin UI only (skip Prometheus & Grafana).
      --rebuild    Force a clean image rebuild (no cache).
      --dry-run    Run every check and write .env, but don't start containers.
      --no-color   Plain output, no ANSI escapes.
  -h, --help       Show this help.

${BOLD}ON FAILURE${RESET}
  ${DIM}If setup fails, containers it started are rolled back automatically and the
  full logs are written to ./setup-failure-<timestamp>.log. Pass${RESET}
  --keep-on-failure ${DIM}to leave them running and debug live instead.${RESET}

${BOLD}ENVIRONMENT${RESET}
  ${DIM}Pre-set any of these to skip its prompt (useful with --yes / in CI):${RESET}
  GROQ_API_KEY   GOOGLE_API_KEY   ANTHROPIC_API_KEY   ENCRYPTION_KEY
  ADMIN_TOKENS   CLIENT_TOKENS    REDIS_PASSWORD

${BOLD}EXAMPLES${RESET}
  ./setup.sh                              ${DIM}# guided first-time setup${RESET}
  ./setup.sh --minimal                    ${DIM}# lighter stack, no metrics UI${RESET}
  GROQ_API_KEY=gsk_... ./setup.sh --yes   ${DIM}# unattended${RESET}
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)    ASSUME_YES=1 ;;
            --minimal)   MINIMAL=1 ;;
            --rebuild)   REBUILD=1 ;;
            --dry-run)   DRY_RUN=1 ;;
            --keep-on-failure) KEEP_ON_FAILURE=1 ;;
            --no-color)  USE_COLOR=0 ;;
            -h|--help)   setup_colors; usage; exit 0 ;;
            *)           setup_colors; fail "Unknown option: $1"; printf '\n'; usage; exit 2 ;;
        esac
        shift
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Prompts
# ─────────────────────────────────────────────────────────────────────────────

interactive() { [[ $ASSUME_YES -eq 0 && -t 0 ]]; }

# ask_yes_no <question> <default:y|n>
ask_yes_no() {
    local question="$1" default="${2:-y}" hint reply
    if ! interactive; then [[ "$default" == "y" ]]; return; fi
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    while true; do
        printf '  %s?%s %s %s[%s]%s ' "$BOLD$CYAN" "$RESET" "$question" "$DIM" "$hint" "$RESET"
        read -r reply || reply=""
        reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
        [[ -z "$reply" ]] && reply="$default"
        case "$reply" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     note "Please answer y or n." ;;
        esac
    done
}

# ask_secret <label> <hint>  →  echoes the entered value on stdout
ask_secret() {
    local label="$1" hint="$2" value=""
    printf '  %s?%s %s\n' "$BOLD$CYAN" "$RESET" "$label" >&2
    printf '    %s%s%s\n' "$GREY" "$hint" "$RESET" >&2
    printf '    %s%s%s ' "$GREY" "$ARROW" "$RESET" >&2
    read -rs value || value=""
    printf '\n' >&2
    printf '%s' "$value"
}

mask() {
    local v="$1" n=${#1}
    if [[ $n -eq 0 ]]; then printf '%s(empty)%s' "$GREY" "$RESET"
    elif [[ $n -le 10 ]]; then printf '%s%s%s' "$DIM" "$(printf '%*s' "$n" '' | tr ' ' '*')" "$RESET"
    else printf '%s%s…%s%s' "$DIM" "${v:0:6}" "${v: -4}" "$RESET"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# .env handling
# ─────────────────────────────────────────────────────────────────────────────

# read_env_value <key> <file> — value of KEY= in an env file, quotes stripped
read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    KEY="$key" awk '
        BEGIN { k = ENVIRON["KEY"] }
        $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
            sub("^[[:space:]]*"k"[[:space:]]*=[[:space:]]*", "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            sub(/[[:space:]]+$/, "")
            print; exit
        }
    ' "$file"
}

# upsert_env <key> <value> <file> — replace KEY= in place, or append it
upsert_env() {
    local key="$1" value="$2" file="$3" tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    KEY="$key" VALUE="$value" awk '
        BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; found = 0 }
        $0 ~ "^[[:space:]]*"k"[[:space:]]*=" && !found { print k "=" v; found = 1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "$file" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

# A Fernet key is urlsafe-base64 of 32 random bytes: 43 chars + "=".
generate_fernet_key() {
    local key=""
    if command -v openssl >/dev/null 2>&1; then
        key="$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')"
    elif command -v python3 >/dev/null 2>&1; then
        key="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
    elif [[ -r /dev/urandom ]] && command -v base64 >/dev/null 2>&1; then
        key="$(head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_')"
    fi
    printf '%s' "$key"
}

is_valid_fernet_key() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{43}=$ ]]
}

# Auth tokens and the Redis password are opaque high-entropy strings. Unlike a
# Fernet key they have no required shape, so the same generator serves.
generate_token() {
    generate_fernet_key
}

# Generate-if-absent, keep-if-present. Result lands in ENSURED_SECRET rather
# than on stdout, because ok() prints there and command substitution would
# swallow the message into the value.
#
# Keeping an existing value is the whole point: regenerating a token on every
# run would silently lock out every client already holding the old one, and
# rotating ENCRYPTION_KEY would make the stored provider keys unreadable.
ENSURED_SECRET=""
ensure_secret() {
    local var="$1" label="$2" existing
    existing="${!var:-$(read_env_value "$var" "$ENV_FILE")}"
    if [[ -n "$existing" ]]; then
        upsert_env "$var" "$existing" "$ENV_FILE"
        ok "$label already set — keeping it $(mask "$existing")"
    else
        existing="$(generate_token)"
        [[ -n "$existing" ]] || die \
            "Could not generate $label (no openssl, python3, or /dev/urandom)." \
            "Install OpenSSL, or set $var yourself in $ENV_FILE"
        upsert_env "$var" "$existing" "$ENV_FILE"
        ok "Generated $label $(mask "$existing")"
    fi
    ENSURED_SECRET="$existing"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — preflight
# ─────────────────────────────────────────────────────────────────────────────

port_in_use() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    else
        return 1
    fi
}

# Describe what is holding a port, in terms a human can act on.
# Docker-published ports are held by the Docker daemon itself, so lsof alone
# would just say "com.docker.backend" — ask Docker which container it is first.
port_holder_desc() {
    local port="$1" cname proj pname pid

    cname="$(docker ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -1)"
    if [[ -n "$cname" ]]; then
        proj="$(docker inspect "$cname" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
        if [[ -n "$proj" ]]; then
            printf 'container %s (compose project "%s")' "$cname" "$proj"
        else
            printf 'container %s' "$cname"
        fi
        return
    fi

    if command -v lsof >/dev/null 2>&1; then
        pname="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -F c 2>/dev/null | sed -n 's/^c//p' | head -1)"
        pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -F p 2>/dev/null | sed -n 's/^p//p' | head -1)"
        if [[ -n "$pname" ]]; then
            printf '%s (pid %s)' "$pname" "$pid"
            return
        fi
    fi
    printf 'an unidentified process'
}

port_already_claimed() {
    case " $CHOSEN_PORTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Is $1 the default port of some *other* service? Remapping onto a sibling's
# default just pushes the collision down the line (admin-ui onto Grafana's 3001,
# and so on), so those stay off-limits.
is_other_service_default() {
    local candidate="$1" own_var="$2" spec var rest default
    for spec in "${PORT_SPECS[@]}"; do
        var="${spec%%:*}"; rest="${spec#*:}"; default="${rest%%:*}"
        [[ "$var" == "$own_var" ]] && continue
        [[ "$candidate" == "$default" ]] && return 0
    done
    return 1
}

# First usable port at or after $1, for the service owning $2.
find_free_port() {
    local candidate="$1" own_var="$2" limit=$(( $1 + 60 ))
    while [[ $candidate -lt $limit ]]; do
        if ! port_in_use "$candidate" \
            && ! port_already_claimed "$candidate" \
            && ! is_other_service_default "$candidate" "$own_var"; then
            printf '%s' "$candidate"
            return 0
        fi
        candidate=$((candidate + 1))
    done
    return 1
}

# Containers left over from an interrupted or partially-failed run keep holding
# their ports. They're ours, so clear them out — but never touch anything else.
# `down` without -v leaves the switchboard-data volume (and your database) intact.
reclaim_previous_stack() {
    local existing
    existing="$($COMPOSE ps -aq 2>/dev/null || true)"
    [[ -z "$existing" ]] && return 0

    info "Containers from a previous run are present — clearing them so ports are released."
    note "Your data volume (switchboard-data) is left untouched."
    if $COMPOSE down --remove-orphans >/dev/null 2>&1; then
        ok "Previous stack cleared"
    else
        warn "Could not fully stop the previous stack — a port may still be held."
    fi
}

# Decide the host port for every service: keep the preferred one when it's free,
# otherwise remap. Nothing is ever killed.
resolve_ports() {
    local spec var rest default label desired chosen holder

    for spec in "${PORT_SPECS[@]}"; do
        var="${spec%%:*}"; rest="${spec#*:}"; default="${rest%%:*}"; label="${rest#*:}"

        # Skip services this run won't start.
        if [[ $MINIMAL -eq 1 ]] && { [[ "$var" == "PROMETHEUS_PORT" ]] || [[ "$var" == "GRAFANA_PORT" ]]; }; then
            continue
        fi

        # Preference order: exported env var > a port already saved in .env > default.
        desired="${!var:-}"
        [[ -z "$desired" ]] && desired="$(read_env_value "$var" "$ENV_FILE")"
        [[ -z "$desired" ]] && desired="$default"

        if ! port_in_use "$desired" && ! port_already_claimed "$desired"; then
            chosen="$desired"
        else
            if port_in_use "$desired"; then
                holder="$(port_holder_desc "$desired")"
            else
                holder="another SwitchBoard service"
            fi
            chosen="$(find_free_port $((desired + 1)) "$var")" || die \
                "Port $desired is taken by $holder, and no free port was found near it." \
                "Free the port, or set $var=<port> in $ENV_FILE yourself."

            printf '  %s%s%s %s port %s is in use by %s%s%s.\n' \
                "$YELLOW" "$WARN" "$RESET" "$label" "$desired" "$BOLD" "$holder" "$RESET"

            if interactive; then
                if ask_yes_no "Use port $chosen for $label instead?" "y"; then
                    WARNINGS+=("$label moved from port $desired to $chosen (saved in $ENV_FILE).")
                else
                    die "$label cannot bind port $desired." \
                        "Stop whatever is using that port, or set $var=<port> in $ENV_FILE. This script will not kill other processes for you."
                fi
            else
                warn "$label moved to port $chosen (saved in $ENV_FILE)."
            fi
        fi

        printf -v "$var" '%s' "$chosen"
        CHOSEN_PORTS="$CHOSEN_PORTS $chosen"
        upsert_env "$var" "$chosen" "$ENV_FILE"
    done

    GATEWAY_URL="http://localhost:${GATEWAY_PORT}"
}

preflight() {
    step "Checking your environment"

    [[ -f docker-compose.yml ]] || die \
        "docker-compose.yml not found in $SCRIPT_DIR." \
        "Run this script from inside the cloned SwitchBoard repo."

    command -v docker >/dev/null 2>&1 || die \
        "Docker is not installed." \
        "Install Docker Desktop: ${BOLD}https://docs.docker.com/get-docker/${RESET}"
    ok "Docker CLI found $(printf '%s%s%s' "$GREY" "$(docker --version 2>/dev/null | sed 's/,.*//')" "$RESET")"

    if ! docker info >/dev/null 2>&1; then
        local hint="Start the Docker daemon and re-run this script."
        [[ "$(uname -s)" == "Darwin" ]] && hint="Open Docker Desktop (${BOLD}open -a Docker${RESET}), wait for it to finish starting, then re-run."
        die "Docker is installed but the daemon isn't responding." "$hint"
    fi
    ok "Docker daemon is running"

    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
        ok "Docker Compose v2 available"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
        warn "Using legacy docker-compose v1 — v2 is recommended."
        note "Upgrade: https://docs.docker.com/compose/install/"
    else
        die "Docker Compose is not available." \
            "Install the Compose plugin: ${BOLD}https://docs.docker.com/compose/install/${RESET}"
    fi

    command -v curl >/dev/null 2>&1 || warn "curl not found — health checks will be skipped."
    [[ -f "$ENV_EXAMPLE" ]] || warn "$ENV_EXAMPLE is missing — a fresh $ENV_FILE will be created from scratch."

    # Do this before any port check: our own leftovers are the most common squatter,
    # and clearing them first makes the check below meaningful.
    reclaim_previous_stack
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — configure
# ─────────────────────────────────────────────────────────────────────────────

configure() {
    step "Configuring environment"

    # Snapshot first, compare later: a run that changes nothing shouldn't litter
    # the repo with identical backups.
    ENV_SNAPSHOT=""
    if [[ -f "$ENV_FILE" ]]; then
        ENV_SNAPSHOT="$(mktemp "${ENV_FILE}.snapshot.XXXXXX")"
        cp "$ENV_FILE" "$ENV_SNAPSHOT"
        info "Found an existing $ENV_FILE — reusing the values in it"
    else
        if [[ -f "$ENV_EXAMPLE" ]]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            ok "Created $ENV_FILE from $ENV_EXAMPLE"
        else
            : > "$ENV_FILE"
            ok "Created an empty $ENV_FILE"
        fi
        chmod 600 "$ENV_FILE"
    fi

    # ── Encryption key ──────────────────────────────────────────────────────
    # Mandatory: the gateway encrypts provider keys at rest with this.
    local enc_key
    enc_key="${ENCRYPTION_KEY:-$(read_env_value ENCRYPTION_KEY "$ENV_FILE")}"

    if is_valid_fernet_key "$enc_key"; then
        upsert_env ENCRYPTION_KEY "$enc_key" "$ENV_FILE"
        ok "Encryption key already set — keeping it $(mask "$enc_key")"
        note "Rotating it would make every API key already in the database unreadable."
    else
        [[ -n "$enc_key" ]] && warn "The existing ENCRYPTION_KEY isn't a valid Fernet key — generating a new one."
        enc_key="$(generate_fernet_key)"
        is_valid_fernet_key "$enc_key" || die \
            "Could not generate an encryption key (no openssl, python3, or /dev/urandom)." \
            "Install OpenSSL, or set ENCRYPTION_KEY yourself in $ENV_FILE"
        upsert_env ENCRYPTION_KEY "$enc_key" "$ENV_FILE"
        ok "Generated a fresh Fernet encryption key $(mask "$enc_key")"
    fi

    # ── Gateway auth tokens and Redis password ──────────────────────────────
    # Mandatory: gateway/auth.py refuses to start without ADMIN_TOKENS and
    # CLIENT_TOKENS, and docker-compose aborts without REDIS_PASSWORD. Both
    # token settings accept a comma-separated list, so rotation is add-new,
    # migrate-callers, remove-old rather than a hard cutover.
    ensure_secret ADMIN_TOKENS  "Admin token"
    ADMIN_TOKEN_VALUE="$ENSURED_SECRET"
    ensure_secret CLIENT_TOKENS "Client token"
    CLIENT_TOKEN_VALUE="$ENSURED_SECRET"

    # Prometheus scrapes the admin-guarded /metrics, and cannot read .env — it
    # does not expand env vars in prometheus.yml. Written unconditionally (not
    # only when missing) so a rotated ADMIN_TOKENS does not leave a stale token
    # here, and even in --minimal mode, because a missing file makes Docker
    # create a directory at the bind-mount path.
    printf '%s' "${ADMIN_TOKEN_VALUE%%,*}" > "$SCRAPE_TOKEN_FILE"
    chmod 600 "$SCRAPE_TOKEN_FILE"
    ok "Wrote the Prometheus scrape token to $SCRAPE_TOKEN_FILE"
    ensure_secret REDIS_PASSWORD "Redis password"

    # Grafana's admin password. Generated even in --minimal mode, because
    # Compose interpolates the whole file regardless of which services start,
    # so an unset value aborts `up` on the :? in docker-compose.yml.
    ensure_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password"
    GRAFANA_PASSWORD_VALUE="$ENSURED_SECRET"

    # ── Provider keys (all optional) ────────────────────────────────────────
    printf '\n'
    info "Provider API keys are ${BOLD}optional${RESET} — you can also add them later in the Admin UI."
    printf '\n'

    configure_provider_key GROQ_API_KEY      "Groq"      "console.groq.com/keys"               "serves chat completions"
    configure_provider_key GOOGLE_API_KEY    "Google AI" "aistudio.google.com/app/apikey"      "embeddings for the semantic cache"
    configure_provider_key ANTHROPIC_API_KEY "Anthropic" "console.anthropic.com/settings/keys"  "optional extra provider"

    # Keep the default provider explicit so routing stays predictable.
    [[ -n "$(read_env_value SWITCHBOARD_PROVIDER "$ENV_FILE")" ]] \
        || upsert_env SWITCHBOARD_PROVIDER "groq" "$ENV_FILE"

    printf '\n'
    resolve_ports
    ok "Host ports settled $(printf '%sgateway %s %s admin %s %s redis %s%s' \
        "$GREY" "$GATEWAY_PORT" "$BULLET" "$ADMIN_UI_PORT" "$BULLET" "$REDIS_PORT" "$RESET")"

    chmod 600 "$ENV_FILE"

    # Only keep a backup if this run actually changed something.
    if [[ -n "$ENV_SNAPSHOT" ]]; then
        if cmp -s "$ENV_SNAPSHOT" "$ENV_FILE"; then
            rm -f "$ENV_SNAPSHOT"
            ok "$ENV_FILE unchanged $(printf '%s(no backup needed)%s' "$GREY" "$RESET")"
        else
            local backup="${ENV_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
            mv "$ENV_SNAPSHOT" "$backup"
            chmod 600 "$backup"
            ok "Updated $ENV_FILE $(printf '%s(previous version saved as %s)%s' "$GREY" "$backup" "$RESET")"
        fi
    else
        ok "Wrote $(printf '%s%s%s' "$BOLD" "$ENV_FILE" "$RESET") $(printf '%s(mode 600 — gitignored, keep it that way)%s' "$GREY" "$RESET")"
    fi

    mkdir -p data
}

# configure_provider_key <VAR> <label> <url> <purpose>
configure_provider_key() {
    local var="$1" label="$2" url="$3" purpose="$4"
    local current value

    # Precedence: exported env var > existing .env > prompt.
    current="${!var:-}"
    [[ -z "$current" ]] && current="$(read_env_value "$var" "$ENV_FILE")"

    if [[ -n "$current" ]]; then
        upsert_env "$var" "$current" "$ENV_FILE"
        ok "$label key set $(mask "$current")"
        return
    fi

    if ! interactive; then
        note "$label key not set — add it later via the Admin UI."
        return
    fi

    value="$(ask_secret "$label API key ${DIM}— ${purpose}${RESET}" "paste it, or press Enter to skip  ${BULLET}  ${url}")"
    if [[ -z "$value" ]]; then
        note "Skipped $label."
        return
    fi
    if [[ "$var" == "GROQ_API_KEY" && "$value" != gsk_* ]]; then
        warn "That doesn't look like a Groq key (they normally start with 'gsk_') — saving it anyway."
    fi
    upsert_env "$var" "$value" "$ENV_FILE"
    ok "$label key saved $(mask "$value")"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — launch
# ─────────────────────────────────────────────────────────────────────────────

launch() {
    step "Building and starting containers"

    SERVICES=(redis gateway admin-ui)
    if [[ $MINIMAL -eq 1 ]]; then
        info "Minimal mode — skipping Prometheus and Grafana."
    else
        SERVICES+=(prometheus grafana)
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "--dry-run: not starting anything."
        note "Would run: $COMPOSE up -d --build ${SERVICES[*]}"
        return
    fi

    info "First run pulls base images and builds the gateway — this can take a few minutes."
    printf '\n'

    if [[ $REBUILD -eq 1 ]]; then
        $COMPOSE build --no-cache "${SERVICES[@]}" || die \
            "Image rebuild failed." "Scroll up for the build error, then re-run ./setup.sh"
    fi

    # From here on, containers may exist — anything that goes wrong must roll them back.
    LAUNCHED=1

    if ! $COMPOSE up -d --build "${SERVICES[@]}"; then
        printf '\n'
        fail "Docker Compose could not start the stack."
        note "Recent gateway logs:"
        $COMPOSE logs --tail 40 gateway 2>&1 | sed "s/^/    /" || true
        printf '\n'
        die "The stack did not start." "Fix the error above, then re-run ./setup.sh"
    fi

    printf '\n'
    ok "Containers started"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — health
# ─────────────────────────────────────────────────────────────────────────────

# wait_for_http <url> <label> <timeout-seconds>
wait_for_http() {
    local url="$1" label="$2" timeout="$3"
    local elapsed=0 frame=0 spinner

    while [[ $elapsed -lt $timeout ]]; do
        if curl -fsS -m 3 "$url" >/dev/null 2>&1; then
            [[ -t 1 ]] && printf '\r\033[2K'
            ok "$label is healthy $(printf '%s(%ss)%s' "$GREY" "$elapsed" "$RESET")"
            return 0
        fi

        if [[ -t 1 ]]; then
            spinner="${SPIN_FRAMES[$((frame % ${#SPIN_FRAMES[@]}))]}"
            printf '\r  %s%s%s Waiting for %s… %s%ss/%ss%s' \
                "$CYAN" "$spinner" "$RESET" "$label" "$GREY" "$elapsed" "$timeout" "$RESET"
        fi
        frame=$((frame + 1))
        sleep 1
        elapsed=$((elapsed + 1))
    done

    [[ -t 1 ]] && printf '\r\033[2K'
    return 1
}

verify() {
    step "Waiting for services to come up"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "--dry-run: nothing to verify."
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        warn "curl is unavailable — skipping health checks."
        return
    fi

    if ! wait_for_http "$GATEWAY_URL/health" "Gateway" "$HEALTH_TIMEOUT"; then
        fail "The gateway did not answer $GATEWAY_URL/health within ${HEALTH_TIMEOUT}s."
        printf '\n'
        note "Recent gateway logs:"
        $COMPOSE logs --tail 40 gateway 2>&1 | sed "s/^/    /" || true
        printf '\n'
        die "The gateway is not healthy." "Check the logs above — a bad ENCRYPTION_KEY or a port clash is the usual cause."
    fi

    if $COMPOSE exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
        ok "Redis answered PONG"
    else
        warn "Redis did not answer PONG — the semantic cache may be degraded."
    fi

    wait_for_http "http://localhost:${ADMIN_UI_PORT}" "Admin UI" 30 \
        || warn "Admin UI isn't responding on port ${ADMIN_UI_PORT} yet — give it a moment."

    if [[ $MINIMAL -eq 0 ]]; then
        wait_for_http "http://localhost:${PROMETHEUS_PORT}/-/ready" "Prometheus" 30 || warn "Prometheus isn't ready yet."
        wait_for_http "http://localhost:${GRAFANA_PORT}/api/health" "Grafana" 45 || warn "Grafana isn't ready yet (it boots slowest)."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — summary
# ─────────────────────────────────────────────────────────────────────────────

# row <name> <url> <note>
row() { printf '  %s%-14s%s %s%-30s%s %s%s%s\n' "$BOLD" "$1" "$RESET" "$CYAN" "$2" "$RESET" "$GREY" "$3" "$RESET"; }

summary() {
    step "You're ready"

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '\n'
        ok "Dry run complete — $ENV_FILE is configured and every check passed."
        printf '\n  Start the stack with:\n\n    %s%s up -d --build%s\n\n' "$BOLD" "$COMPOSE" "$RESET"
        return
    fi

    printf '\n'
    row "Gateway API"  "$GATEWAY_URL"                          "OpenAI-compatible endpoint"
    row "API Docs"     "$GATEWAY_URL/docs"                     "Swagger UI — prompts for the admin token"
    row "Admin UI"     "http://localhost:${ADMIN_UI_PORT}"     "add keys, watch traffic"
    if [[ $MINIMAL -eq 0 ]]; then
        row "Prometheus" "http://localhost:${PROMETHEUS_PORT}" "raw metrics"
        row "Grafana"    "http://localhost:${GRAFANA_PORT}"    "dashboards — log in as admin"
    fi

    # Every route except /health now needs a bearer token, so the operator
    # cannot do anything with the URLs above without seeing these first.
    local admin_tok client_tok
    admin_tok="${ADMIN_TOKEN_VALUE:-$(read_env_value ADMIN_TOKENS "$ENV_FILE")}"
    client_tok="${CLIENT_TOKEN_VALUE:-$(read_env_value CLIENT_TOKENS "$ENV_FILE")}"

    printf '\n  %sYour access tokens%s %s(also in %s)%s\n\n' \
        "$BOLD" "$RESET" "$DIM" "$ENV_FILE" "$RESET"
    printf '    %sAdmin%s   %s\n' "$DIM" "$RESET" "$admin_tok"
    printf '    %s        paste this into the Admin UI to manage keys%s\n' "$DIM" "$RESET"
    printf '    %sClient%s  %s\n' "$DIM" "$RESET" "$client_tok"
    printf '    %s        hand this to API callers; it cannot touch /admin%s\n' "$DIM" "$RESET"
    if [[ $MINIMAL -eq 0 ]]; then
        local grafana_pw
        grafana_pw="${GRAFANA_PASSWORD_VALUE:-$(read_env_value GRAFANA_ADMIN_PASSWORD "$ENV_FILE")}"
        printf '    %sGrafana%s %s\n' "$DIM" "$RESET" "$grafana_pw"
        printf '    %s        log in at :%s as admin with this%s\n' "$DIM" "$GRAFANA_PORT" "$RESET"
    fi

    printf '\n  %sSend your first request:%s\n\n' "$BOLD" "$RESET"
    printf '%s' "$GREY"
    cat <<EOF
    curl -s $GATEWAY_URL/v1/chat/completions \\
      -H 'Authorization: Bearer $client_tok' \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"llama-3.1-8b-instant","provider":"groq",
           "messages":[{"role":"user","content":"Say hi in five words."}]}'
EOF
    printf '%s' "$RESET"

    if [[ -z "$(read_env_value GROQ_API_KEY "$ENV_FILE")" ]]; then
        printf '\n'
        info "No Groq key configured yet — add one at ${BOLD}http://localhost:${ADMIN_UI_PORT}${RESET} before that first request."
    fi

    printf '\n  %sManage the stack:%s\n' "$BOLD" "$RESET"
    note "$COMPOSE logs -f gateway    # follow gateway logs"
    note "$COMPOSE ps                 # container status"
    note "$COMPOSE stop               # pause everything"
    note "$COMPOSE down               # stop and remove containers"
    note "$COMPOSE down -v            # ...and wipe the database volume"

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf '\n  %s%s %d warning(s) worth a look:%s\n' "$BOLD" "$WARN" "${#WARNINGS[@]}" "$RESET"
        local w
        for w in "${WARNINGS[@]}"; do printf '    %s%s%s %s\n' "$YELLOW" "$WARN" "$RESET" "$w"; done
    fi

    printf '\n%s%s SwitchBoard is live.%s %sHappy routing.%s\n\n' "$BOLD$GREEN" "$TICK" "$RESET" "$DIM" "$RESET"
}

# ─────────────────────────────────────────────────────────────────────────────

on_error() {
    local code=$?
    [[ $code -eq 0 ]] && { cleanup_temp; return; }
    printf '\n%s%s Unexpected failure%s (exit %d, line %s).\n' "$BOLD$RED" "$CROSS" "$RESET" "$code" "${BASH_LINENO[0]:-?}" >&2
    cleanup_failed_launch
    cleanup_temp
    printf '%sIf this looks like a bug, please open an issue with the output above.%s\n\n' "$GREY" "$RESET" >&2
}

# Ctrl-C mid-build leaves half a stack behind too — roll that back as well.
on_interrupt() {
    printf '\n\n%s%s Interrupted.%s\n' "$BOLD$YELLOW" "$WARN" "$RESET" >&2
    # Stop any in-flight `compose up` first — otherwise it keeps starting containers
    # while we're tearing them down, and survivors are left behind.
    if command -v pkill >/dev/null 2>&1; then
        pkill -P $$ >/dev/null 2>&1 || true
        sleep 1
    fi
    cleanup_failed_launch
    cleanup_temp
    trap - EXIT
    exit 130
}

main() {
    parse_args "$@"
    setup_colors
    trap on_error EXIT
    trap on_interrupt INT TERM
    banner
    preflight
    configure
    launch
    verify
    summary
    trap - EXIT
}

main "$@"
