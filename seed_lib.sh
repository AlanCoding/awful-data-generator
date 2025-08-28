#!/usr/bin/env bash
# seed_lib.sh — SAFE library: defines helpers; no shell options changed, no commands run.
# deps: curl, jq

# Guard to avoid re-defining if sourced multiple times
if [[ -n "${__SEED_LIB_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__SEED_LIB_SOURCED=1

############################################
# CONFIG (can be overridden by env vars BEFORE sourcing)
############################################
: "${BASE_URL:=http://localhost:44926}"
: "${AUTH_USER:=admin}"
: "${AUTH_PASS:=password1}"
HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json")

############################################
# INTERNAL UTIL
############################################
__seed_need() { command -v "$1" >/dev/null 2>&1; }

# URL-encode a string (for query building)
urlencode() {
  local LC_ALL=C s="${1-}" i c out=""
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c"
    esac
  done
  printf '%s' "$out"
}

# Accepts METHOD, ENDPOINT (starting with /), JSON (or @/path/to.json or - for stdin)
# Prints response body to stdout; writes HTTP status to global RESP_STATUS
http_json() {
  # Lazy dependency check (only when you actually call a helper)
  if ! __seed_need curl || ! __seed_need jq; then
    echo "Missing dependency: curl and/or jq. Install them first." >&2
    return 127
  fi

  local method="${1-}" endpoint="${2-}" data="${3-}"
  if [[ -z "$method" || -z "$endpoint" ]]; then
    echo "http_json usage: METHOD ENDPOINT [JSON|-|@file]" >&2
    return 2
  fi

  local url="${BASE_URL}${endpoint}"
  local curl_args=(-sS -u "${AUTH_USER}:${AUTH_PASS}" "${HEADERS[@]}" -X "$method" "$url")

  local body_arg=()
  if [[ -n "${data-}" ]]; then
    if [[ "$data" == "@"* && -f "${data#@}" ]]; then
      body_arg=(--data-binary "$data")
    elif [[ "$data" == "-" ]]; then
      local stdin_payload
      stdin_payload="$(cat)"
      body_arg=(--data-binary "$stdin_payload")
    else
      body_arg=(--data-binary "$data")
    fi
  fi

  local resp status
  resp="$(curl "${curl_args[@]}" "${body_arg[@]}" -w $'\n%{http_code}')" || return 1
  status="${resp##*$'\n'}"
  RESP_STATUS="$status"
  printf '%s' "${resp%$'\n'$status}"
}

# Extract a best-effort ID from response JSON (supports object or paginated list)
extract_id() {
  jq -r '(
      .id
      // .data.id
      // (.results[0].id)
      // (.items[0].id)
      // empty
    )'
}

# Build a query string from JSON payload using a comma-separated list of fields.
build_qs_from_payload() {
  local payload="${1-}" csv_fields="${2-}"
  local qs=""
  IFS=',' read -r -a fields <<< "$csv_fields"
  for f in "${fields[@]}"; do
    f="$(echo "$f" | xargs)"
    [[ -z "$f" ]] && continue
    local jq_expr
    if [[ "$f" == *.* ]]; then jq_expr=".$f"; else jq_expr=".\"$f\""; fi
    local val
    val="$(jq -r "$jq_expr // empty" <<<"$payload")"
    if [[ -n "$val" && "$val" != "null" ]]; then
      local key_enc val_enc
      key_enc="$(urlencode "$f")"
      val_enc="$(urlencode "$val")"
      if [[ -z "$qs" ]]; then qs="?${key_enc}=${val_enc}"; else qs="${qs}&${key_enc}=${val_enc}"; fi
    fi
  done
  printf '%s' "$qs"
}

# Return 0 if body/STATUS indicate a duplicate/integrity error
looks_like_integrity_conflict() {
  local status="${1-}" body="${2-}"

  # If status clearly indicates conflict
  if [[ "$status" == "409" || "$status" == "400" || "$status" == "422" ]]; then
    return 0
  fi

  # Fall back to body text match (handles blank/unknown statuses)
  if grep -qiE 'already exists|unique constraint|duplicate key|conflict' <<<"$body"; then
    return 0
  fi

  return 1
}

############################################
# PUBLIC HELPERS
############################################

# Create (POST) and return ID.
# If duplicate/integrity error, perform a GET lookup using fields from the payload.
create_or_get_id() {
  local endpoint="${1-}" payload="${2-}" unique_fields_csv="${3-}"

  # 1) Try POST
  local body
  body="$(http_json POST "$endpoint" "$payload")" || {
    echo "HTTP error while POSTing $endpoint" >&2
    return 1
  }
  local status="${RESP_STATUS:-}"

  # --- NEW: if response body already contains an id, treat as success regardless of status ---
  local id
  id="$(extract_id <<<"$body")"
  if [[ -n "$id" && "$id" != "null" ]]; then
    LAST_ID="$id"
    printf '%s\n' "$id"
    return 0
  fi

  # 2) If it looks like a duplicate/integrity conflict, try GET lookup
  if looks_like_integrity_conflict "$status" "$body"; then
    if [[ -z "$unique_fields_csv" ]]; then
      echo "Duplicate detected, but no lookup fields provided." >&2
      printf '\n'
      return 0
    fi

    local qs get_body
    qs="$(build_qs_from_payload "$payload" "$unique_fields_csv")"
    get_body="$(http_json GET "${endpoint}${qs}")" || {
      echo "Lookup GET errored for ${endpoint}${qs}" >&2
      return 1
    }

    # Extract id from lookup body (ignore status; some envs don’t propagate it)
    id="$(extract_id <<<"$get_body")"
    if [[ -z "$id" || "$id" == "null" ]]; then
      # last-ditch extractor if list shape differs
      id="$(jq -r '(.results[0].id // .items[0].id // empty)' <<<"$get_body" 2>/dev/null || true)"
    fi

    if [[ -n "$id" && "$id" != "null" ]]; then
      LAST_ID="$id"
      printf '%s\n' "$id"
      return 0
    fi

    echo "Lookup did not yield an id. Body was:" >&2
    echo "$get_body" >&2
    printf '\n'
    return 1
  fi

  # 3) Some other error
  echo "POST ${endpoint} failed (${status:-}). Body:" >&2
  echo "$body" >&2
  return 1
}

service_org_id() {
  local service="${1:-}" name="${2:-}"
  if [[ -z "$service" || -z "$name" ]]; then
    echo "usage: service_org_id <service-prefix> <org-name>" >&2
    return 2
  fi

  # normalize: single leading slash, no trailing slash
  service="${service#/}"
  service="${service%/}"

  local endpoint="/api/${service}/organizations/?name=$(urlencode "$name")"
  local body id
  body="$(http_json GET "$endpoint")" || {
    echo "service_org_id: GET failed for $endpoint (status ${RESP_STATUS:-})" >&2
    return 1
  }

  id="$(extract_id <<<"$body")"
  if [[ -n "$id" && "$id" != "null" ]]; then
    printf '%s\n' "$id"
    return 0
  fi

  echo "service_org_id: no org named '$name' at /api/${service}" >&2
  echo "$body" >&2
  return 1
}


# Low-noise helpers
POST_JSON() { create_or_get_id "$2" "$1" "${3-}"; }   # POST_JSON DATA ENDPOINT UNIQUE_FIELDS
POST()      { create_or_get_id "$1" "$2" "${3-}"; }   # POST ENDPOINT DATA UNIQUE_FIELDS
GET()       { http_json GET "$1" ""; echo; }
PUT()       { http_json PUT "$1" "$2"; echo; }
PATCH()     { http_json PATCH "$1" "$2"; echo; }
DELETE()    { http_json DELETE "$1" ""; echo; }

# Nothing executes on source; only functions are defined.
