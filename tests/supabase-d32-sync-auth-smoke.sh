#!/usr/bin/env bash
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${DB_URL:?DB_URL is required}"
: "${ANON_KEY:?ANON_KEY is required}"

PASSWORD='AtackPlus-D32-Auth-2026!'
STORE='d1000000-0000-4000-8000-000000000001'
OWNER_ID='d3000000-0000-4000-8000-000000000001'
SELLER_ID='d3000000-0000-4000-8000-000000000002'
CUSTOMER_ID='d4000000-0000-4000-8000-000000000001'
CATEGORY_ID='d4000000-0000-4000-8000-000000000002'
OWNER_INVOICE='d5000000-0000-4000-8000-000000000001'
SELLER_INVOICE='d5000000-0000-4000-8000-000000000002'
PURCHASE_EVENT='d6000000-0000-4000-8000-000000000001'

signup_identity() {
  local label="$1"
  curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/auth/v1/signup" \
    -H "apikey: ${ANON_KEY}" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg email "d32-auth-${GITHUB_RUN_ID:-local}-${label}@example.test" --arg password "${PASSWORD}" '{email:$email,password:$password}')"
}

rpc_call() {
  local token="$1" function_name="$2" payload="$3"
  local status body
  status="$(curl --silent --show-error -o /tmp/atack-d32-rpc-response.json -w '%{http_code}' \
    -X POST "${API_URL}/rest/v1/rpc/${function_name}" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" --data "${payload}")"
  body="$(cat /tmp/atack-d32-rpc-response.json)"
  if [[ ! "${status}" =~ ^2 ]]; then
    echo "RPC ${function_name} failed with HTTP ${status}: ${body}" >&2
    return 1
  fi
  printf '%s' "${body}"
}

expect_rpc_error() {
  local label="$1" token="$2" function_name="$3" payload="$4" expected_code="$5"
  local status actual_code
  status="$(curl --silent --show-error -o /tmp/atack-d32-rpc-error.json -w '%{http_code}' \
    -X POST "${API_URL}/rest/v1/rpc/${function_name}" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" --data "${payload}")"
  actual_code="$(jq -r '.code // empty' /tmp/atack-d32-rpc-error.json)"
  if [[ "${status}" != "400" && "${status}" != "403" ]] || [[ "${actual_code}" != "${expected_code}" ]]; then
    echo "Expected SQLSTATE ${expected_code} for ${label}, got HTTP ${status} / SQLSTATE ${actual_code}" >&2
    cat /tmp/atack-d32-rpc-error.json >&2
    exit 1
  fi
}

echo "Creating real Supabase Auth identities for D3.2 owner and seller..."
OWNER_RESPONSE="$(signup_identity owner)"
SELLER_RESPONSE="$(signup_identity seller)"
OWNER_AUTH_ID="$(jq -er '.user.id' <<<"${OWNER_RESPONSE}")"
OWNER_TOKEN="$(jq -er '.access_token' <<<"${OWNER_RESPONSE}")"
SELLER_AUTH_ID="$(jq -er '.user.id' <<<"${SELLER_RESPONSE}")"
SELLER_TOKEN="$(jq -er '.access_token' <<<"${SELLER_RESPONSE}")"

echo "Seeding isolated owner/seller business records..."
psql "${DB_URL}" -v ON_ERROR_STOP=1 \
  -v store_id="${STORE}" -v owner_id="${OWNER_ID}" -v owner_auth="${OWNER_AUTH_ID}" \
  -v seller_id="${SELLER_ID}" -v seller_auth="${SELLER_AUTH_ID}" \
  -v customer_id="${CUSTOMER_ID}" -v category_id="${CATEGORY_ID}" \
  -v owner_invoice="${OWNER_INVOICE}" -v seller_invoice="${SELLER_INVOICE}" \
  -v purchase_event="${PURCHASE_EVENT}" <<'SQL'
INSERT INTO public.stores(id,name) VALUES (:'store_id'::uuid,'D3.2 real Auth sync store');
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 (:'owner_id'::uuid,:'owner_auth'::uuid,:'store_id'::uuid,'d32-auth-owner','D3.2 Auth Owner',TRUE),
 (:'seller_id'::uuid,:'seller_auth'::uuid,:'store_id'::uuid,'d32-auth-seller','D3.2 Auth Seller',TRUE);
INSERT INTO public.user_roles(user_id,role_id)
VALUES (:'owner_id'::uuid,'owner'),(:'seller_id'::uuid,'cashier');

INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
VALUES (:'customer_id'::uuid,:'store_id'::uuid,'D32-AUTH-CUSTOMER','D3.2 Auth Customer',0,0,TRUE);
INSERT INTO public.categories(id,store_id,name,code,is_active)
VALUES (:'category_id'::uuid,:'store_id'::uuid,'D3.2 Auth Tombstone Category','D32-AUTH-CATEGORY',TRUE);

INSERT INTO public.invoices(
 id,store_id,invoice_number,type,customer_id,invoice_date,total_amount,
 paid_amount,remaining_amount,created_by,status
) VALUES
 (:'owner_invoice'::uuid,:'store_id'::uuid,'D32-AUTH-OWNER-INVOICE','SALE',
  :'customer_id'::uuid,NOW(),10,0,10,:'owner_id'::uuid,'OPEN'),
 (:'seller_invoice'::uuid,:'store_id'::uuid,'D32-AUTH-SELLER-INVOICE','SALE',
  :'customer_id'::uuid,NOW(),12,0,12,:'seller_id'::uuid,'OPEN');

-- This restricted purchase stream event proves that a seller receives no
-- purchase metadata even though a real Change Log event exists.
SELECT public.log_change(
  :'store_id'::uuid,'purchases',:'purchase_event'::uuid,'INSERT',NULL,
  jsonb_build_object('id',:'purchase_event'::uuid,'store_id',:'store_id'::uuid,'purchase_number','D32-AUTH-HIDDEN')
);
NOTIFY pgrst, 'reload schema';
SQL

sleep 3

echo "Registering one owner device and one seller device through the real JWT RPC..."
OWNER_DEVICE_RESULT="$(rpc_call "${OWNER_TOKEN}" "register_sync_device" \
  "$(jq -nc --arg user "${OWNER_ID}" '{p_target_user_id:$user,p_device_name:"D3.2 Auth Owner Device",p_device_type:"DESKTOP}')")"
SELLER_DEVICE_RESULT="$(rpc_call "${OWNER_TOKEN}" "register_sync_device" \
  "$(jq -nc --arg user "${SELLER_ID}" '{p_target_user_id:$user,p_device_name:"D3.2 Auth Seller Device",p_device_type:"PHONE}')")"
OWNER_DEVICE_ID="$(jq -er '.device_id' <<<"${OWNER_DEVICE_RESULT}")"
OWNER_DEVICE_TOKEN="$(jq -er '.device_token' <<<"${OWNER_DEVICE_RESULT}")"
SELLER_DEVICE_ID="$(jq -er '.device_id' <<<"${SELLER_DEVICE_RESULT}")"
SELLER_DEVICE_TOKEN="$(jq -er '.device_token' <<<"${SELLER_DEVICE_RESULT}")"

echo "Verifying seller Pull is filtered to its own invoices..."
SELLER_PULL_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg token "${SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"invoices",p_device_token:$token}')"
SELLER_PAGE="$(rpc_call "${SELLER_TOKEN}" "get_unsynced_records_page" "${SELLER_PULL_ARGS}")"
[[ "$(jq -r '.event_count' <<<"${SELLER_PAGE}")" == "1" ]] || { echo "Seller Pull returned an unexpected event count: ${SELLER_PAGE}" >&2; exit 1; }
[[ "$(jq -r '.events[0].record_uuid' <<<"${SELLER_PAGE}")" == "${SELLER_INVOICE}" ]] || { echo "Seller Pull exposed the wrong invoice: ${SELLER_PAGE}" >&2; exit 1; }
if jq -e --arg owner "${OWNER_INVOICE}" '.events[] | select(.record_uuid == $owner)' <<<"${SELLER_PAGE}" >/dev/null; then
  echo "Seller Pull leaked the owner's invoice" >&2; exit 1
fi
SELLER_DELIVERY_ID="$(jq -er '.delivery_id' <<<"${SELLER_PAGE}")"
SELLER_RETRY="$(rpc_call "${SELLER_TOKEN}" "get_unsynced_records_page" "${SELLER_PULL_ARGS}")"
[[ "$(jq -r '.delivery_id' <<<"${SELLER_RETRY}")" == "${SELLER_DELIVERY_ID}" ]] || { echo "Pull retry did not return the same delivery ID" >&2; exit 1; }

echo "Verifying invalid, cross-device and valid ACK behavior with real JWTs..."
FAKE_ACK_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg delivery "d7000000-0000-4000-8000-000000000099" --arg token "${SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"invoices",p_delivery_id:$delivery,p_device_token:$token}')"
expect_rpc_error "ACK for a page never delivered" "${SELLER_TOKEN}" "acknowledge_sync_cursor" "${FAKE_ACK_ARGS}" "P0001"

CROSS_DEVICE_ACK_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${OWNER_DEVICE_ID}" --arg delivery "${SELLER_DELIVERY_ID}" --arg token "${OWNER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"invoices",p_delivery_id:$delivery,p_device_token:$token}')"
expect_rpc_error "another device ACKing seller page" "${OWNER_TOKEN}" "acknowledge_sync_cursor" "${CROSS_DEVICE_ACK_ARGS}" "P0001"

SELLER_ACK_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg delivery "${SELLER_DELIVERY_ID}" --arg token "${SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"invoices",p_delivery_id:$delivery,p_device_token:$token}')"
rpc_call "${SELLER_TOKEN}" "acknowledge_sync_cursor" "${SELLER_ACK_ARGS}" >/dev/null
rpc_call "${SELLER_TOKEN}" "acknowledge_sync_cursor" "${SELLER_ACK_ARGS}" >/dev/null

echo "Verifying owner Pull sees all store invoices and restricted purchase events..."
OWNER_INVOICE_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${OWNER_DEVICE_ID}" --arg token "${OWNER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"invoices",p_device_token:$token}')"
OWNER_INVOICE_PAGE="$(rpc_call "${OWNER_TOKEN}" "get_unsynced_records_page" "${OWNER_INVOICE_ARGS}")"
[[ "$(jq -r '.event_count' <<<"${OWNER_INVOICE_PAGE}")" == "2" ]] || { echo "Owner Pull did not return both invoices: ${OWNER_INVOICE_PAGE}" >&2; exit 1; }
OWNER_INVOICE_ACK="$(jq -nc --arg store "${STORE}" --arg device "${OWNER_DEVICE_ID}" --arg delivery "$(jq -r '.delivery_id' <<<"${OWNER_INVOICE_PAGE}")" --arg token "${OWNER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"invoices",p_delivery_id:$delivery,p_device_token:$token}')"
rpc_call "${OWNER_TOKEN}" "acknowledge_sync_cursor" "${OWNER_INVOICE_ACK}" >/dev/null

SELLER_PURCHASE_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg token "${SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"purchases",p_device_token:$token}')"
SELLER_PURCHASE_PAGE="$(rpc_call "${SELLER_TOKEN}" "get_unsynced_records_page" "${SELLER_PURCHASE_ARGS}")"
[[ "$(jq -r '.event_count' <<<"${SELLER_PURCHASE_PAGE}")" == "0" && "$(jq -r '.delivery_id' <<<"${SELLER_PURCHASE_PAGE}")" == "null" && "$(jq -r '.has_more' <<<"${SELLER_PURCHASE_PAGE}")" == "false" ]] || { echo "Seller Pull leaked restricted purchase metadata: ${SELLER_PURCHASE_PAGE}" >&2; exit 1; }

OWNER_PURCHASE_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${OWNER_DEVICE_ID}" --arg token "${OWNER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"purchases",p_device_token:$token}')"
OWNER_PURCHASE_PAGE="$(rpc_call "${OWNER_TOKEN}" "get_unsynced_records_page" "${OWNER_PURCHASE_ARGS}")"
[[ "$(jq -r '.event_count' <<<"${OWNER_PURCHASE_PAGE}")" == "1" ]] || { echo "Owner could not Pull store purchase event: ${OWNER_PURCHASE_PAGE}" >&2; exit 1; }
OWNER_PURCHASE_ACK="$(jq -nc --arg store "${STORE}" --arg device "${OWNER_DEVICE_ID}" --arg delivery "$(jq -r '.delivery_id' <<<"${OWNER_PURCHASE_PAGE}")" --arg token "${OWNER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"purchases",p_delivery_id:$delivery,p_device_token:$token}')"
rpc_call "${OWNER_TOKEN}" "acknowledge_sync_cursor" "${OWNER_PURCHASE_ACK}" >/dev/null

echo "Verifying canonical Tombstone DELETE envelope and credential rotation..."
SOFT_DELETE_ARGS="$(jq -nc --arg record "${CATEGORY_ID}" --arg store "${STORE}" --arg user "${OWNER_ID}" '{p_table_name:"categories",p_record_uuid:$record,p_store_id:$store,p_deleted_by:$user}')"
rpc_call "${OWNER_TOKEN}" "soft_delete_record" "${SOFT_DELETE_ARGS}" >/dev/null

TOMBSTONE_ARGS="$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg token "${SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"tombstones",p_device_token:$token}')"
TOMBSTONE_PAGE="$(rpc_call "${SELLER_TOKEN}" "get_unsynced_records_page" "${TOMBSTONE_ARGS}")"
[[ "$(jq -r '.event_count' <<<"${TOMBSTONE_PAGE}")" == "1" ]] || { echo "Seller did not receive the Tombstone: ${TOMBSTONE_PAGE}" >&2; exit 1; }
[[ "$(jq -r '.events[0].event_type' <<<"${TOMBSTONE_PAGE}")" == "DELETE" \
   && "$(jq -r '.events[0].table_name' <<<"${TOMBSTONE_PAGE}")" == "categories" \
   && "$(jq -r '.events[0].record_uuid' <<<"${TOMBSTONE_PAGE}")" == "${CATEGORY_ID}" \
   && "$(jq -r '.events[0].tombstone_id' <<<"${TOMBSTONE_PAGE}")" != "${CATEGORY_ID}" ]] || {
  echo "Canonical Tombstone event envelope is invalid: ${TOMBSTONE_PAGE}" >&2; exit 1;
}
OLD_TOMBSTONE_DELIVERY="$(jq -er '.delivery_id' <<<"${TOMBSTONE_PAGE}")"

ROTATE_ARGS="$(jq -nc --arg device "${SELLER_DEVICE_ID}" '{p_device_id:$device}')"
ROTATE_RESULT="$(rpc_call "${OWNER_TOKEN}" "rotate_sync_device_credential" "${ROTATE_ARGS}")"
NEW_SELLER_DEVICE_TOKEN="$(jq -er '.device_token' <<<"${ROTATE_RESULT}")"

expect_rpc_error "old device token after rotation" "${SELLER_TOKEN}" "get_unsynced_records_page" \
  "$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg token "${SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"tombstones",p_device_token:$token}')" "P0001"
expect_rpc_error "ACK page issued under previous credential version" "${SELLER_TOKEN}" "acknowledge_sync_cursor" \
  "$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg delivery "${OLD_TOMBSTONE_DELIVERY}" --arg token "${NEW_SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"tombstones",p_delivery_id:$delivery,p_device_token:$token}')" "P0001"

NEW_TOMBSTONE_PAGE="$(rpc_call "${SELLER_TOKEN}" "get_unsynced_records_page" \
  "$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg token "${NEW_SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"tombstones",p_device_token:$token}')")"
[[ "$(jq -r '.events[0].record_uuid' <<<"${NEW_TOMBSTONE_PAGE}")" == "${CATEGORY_ID}" ]] || { echo "Rotated device could not retry Tombstone page" >&2; exit 1; }
NEW_TOMBSTONE_ACK="$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg delivery "$(jq -r '.delivery_id' <<<"${NEW_TOMBSTONE_PAGE}")" --arg token "${NEW_SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"tombstones",p_delivery_id:$delivery,p_device_token:$token}')"
rpc_call "${SELLER_TOKEN}" "acknowledge_sync_cursor" "${NEW_TOMBSTONE_ACK}" >/dev/null

REVOKE_ARGS="$(jq -nc --arg device "${SELLER_DEVICE_ID}" '{p_device_id:$device}')"
rpc_call "${OWNER_TOKEN}" "revoke_sync_device" "${REVOKE_ARGS}" >/dev/null
expect_rpc_error "revoked device credential" "${SELLER_TOKEN}" "get_unsynced_records_page" \
  "$(jq -nc --arg store "${STORE}" --arg device "${SELLER_DEVICE_ID}" --arg token "${NEW_SELLER_DEVICE_TOKEN}" '{p_store_id:$store,p_device_id:$device,p_table_name:"tombstones",p_device_token:$token}')" "P0001"

echo "PASS: real Supabase Auth/PostgREST D3.2 owner/seller Pull, device credentials, delivery ACK and Tombstone contract"
