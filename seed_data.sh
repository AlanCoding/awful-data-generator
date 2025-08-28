#!/usr/bin/env bash
# seed_data.sh — run me (do not source)

# ---- Safe globals so set -u doesn't explode ----
RESP_STATUS=""
LAST_ID=""

set -euo pipefail
source "$(dirname "$0")/seed_lib.sh"

# 1) Create or get the org
ORG1_ID="$(POST_JSON '{"name":"org1"}' /api/gateway/v1/organizations/ 'name')"
echo "ORG id ${ORG1_ID:-<none>}"

# 2) Create or get users user0..user9 and collect their IDs
declare -a USER_IDS=()          # indexed: 0..9
declare -A USER_ID_BY_NAME=()   # associative: "userN" -> id

for i in $(seq 0 9); do
  uname="user$i"
  email="user$i@example.com"
  pw="password1"

  # Build JSON safely with jq (no fragile quoting)
  payload="$(jq -n --arg u "$uname" --arg e "$email" --arg pw "$pw" '{username:$u, email:$e, password:$pw}')"

  id="$(POST_JSON "$payload" /api/gateway/v1/users/ 'username')"
  echo "$uname -> id=${id:-<none>}"

  USER_IDS+=("${id:-}")
  USER_ID_BY_NAME["$uname"]="${id:-}"
done

# 3) Use the arrays (examples)
printf 'All user IDs: %s\n' "${USER_IDS[*]}"
echo "user2 id: ${USER_ID_BY_NAME[user2]:-<none>}"

# ------
# Get different role ids

roledef_id() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "roledef_id: missing role name" >&2
    return 2
  fi

  local enc body id count
  enc="$(urlencode "$name")"
  body="$(http_json GET "/api/gateway/v1/role_definitions/?name=${enc}")" || {
    echo "roledef_id: GET failed for name='$name' (status: ${RESP_STATUS:-?})" >&2
    return 1
  }

  # optional: warn if multiple matches
  count="$(jq -r '.count // empty' <<<"$body" 2>/dev/null || true)"
  if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 1 ]]; then
    echo "roledef_id: warning: $count matches for '$name'; using first result" >&2
  fi

  # Use shared extractor (handles .results[0].id)
  id="$(extract_id <<<"$body")"

  if [[ -n "$id" && "$id" != "null" ]]; then
    printf '%s\n' "$id"
    return 0
  fi

  echo "roledef_id: no id found for name='$name'. Body:" >&2
  echo "$body" >&2
  return 1
}

ORG_MEMBER_ID="$(roledef_id "Organization Member")"
echo "role_definition 'Organization Member' -> id=$ORG_MEMBER_ID"
INV_ADMIN_ID="$(roledef_id "Inventory Admin")"
echo "role_definition 'Inventory Admin' -> id=$INV_ADMIN_ID"


for uname in "${!USER_ID_BY_NAME[@]}"; do
  uid="${USER_ID_BY_NAME[$uname]}"
  [[ -n "$uid" && -n "${ORG1_ID:-}" ]] || continue
  POST_JSON "{\"user\": $uid, \"role_definition\": $ORG_MEMBER_ID, \"object_id\": \"$ORG1_ID\"}" /api/gateway/v1/role_user_assignments/
  echo "added $uname to org1"
done


CTRL_ORG_ID="$(service_org_id "/controller/v2" "org1")"
echo "controller org id: $CTRL_ORG_ID"

INV_PAYLOAD="$(jq -n --arg name "inv-has-access" --argjson org "$CTRL_ORG_ID" '{name:$name, organization:$org}')"
INV_ID="$(POST_JSON "$INV_PAYLOAD" /api/controller/v2/inventories/ 'name,organization')"
echo "INV id ${INV_ID}"

INV_PAYLOAD="$(jq -n --arg name "inv-no-access" --argjson org "$CTRL_ORG_ID" '{name:$name, organization:$org}')"
INV_NO_ID="$(POST_JSON "$INV_PAYLOAD" /api/controller/v2/inventories/ 'name,organization')"
echo "INV no-access id ${INV_NO_ID}"


for uname in "${!USER_ID_BY_NAME[@]}"; do
  uid="${USER_ID_BY_NAME[$uname]}"
  [[ -n "$uid" && -n "${ORG1_ID:-}" ]] || continue
  POST_JSON "{\"user\": $uid, \"role_definition\": $INV_ADMIN_ID, \"object_id\": \"$INV_ID\"}" /api/gateway/v1/role_user_assignments/
  echo "gave $uname admin to inventory $INV_ID"
done

