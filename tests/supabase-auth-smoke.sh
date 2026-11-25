#!/usr/bin/env bash
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${DB_URL:?DB_URL is required}"
: "${ANON_KEY:?ANON_KEY is required}"

EMAIL="auth-smoke-${GITHUB_RUN_ID:-local}@example.test"
PASSWORD="AtackPlus-Auth-Smoke-2026!"
STORE_A="a1000000-0000-4000-8000-000000000001"
STORE_B="b1000000-0000-4000-8000-000000000002"
PRODUCT_A="a2000000-0000-4000-8000-000000000001"
PRODUCT_B="b2000000-0000-4000-8000-000000000002"
USER_A="a3000000-0000-4000-8000-000000000001"
OWNER_USER="a3000000-0000-4000-8000-000000000002"
CASHIER_USER="a3000000-0000-4000-8000-000000000003"
STOCK_USER="a3000000-0000-4000-8000-000000000004"
STORE_B_USER="b3000000-0000-4000-8000-000000000003"
SALE_ID="a5000000-0000-4000-8000-000000000001"
SALE_ITEM_ID="a5000000-0000-4000-8000-000000000002"
SALE_OPERATION="a5000000-0000-4000-8000-000000000003"

signup_identity() {
  local label="$1"
  curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/auth/v1/signup" \
    -H "apikey: ${ANON_KEY}" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg email "auth-smoke-${GITHUB_RUN_ID:-local}-${label}@example.test" --arg password "${PASSWORD}" '{email:$email,password:$password}')"
}

echo "Creating real Supabase Auth identities for admin, owner, cashier and stock keeper..."
ADMIN_RESPONSE="$(signup_identity admin)"
OWNER_RESPONSE="$(signup_identity owner)"
CASHIER_RESPONSE="$(signup_identity cashier)"
STOCK_RESPONSE="$(signup_identity stockkeeper)"
AUTH_USER_ID="$(jq -er '.user.id' <<<"${ADMIN_RESPONSE}")"
ADMIN_TOKEN="$(jq -er '.access_token' <<<"${ADMIN_RESPONSE}")"
OWNER_AUTH_ID="$(jq -er '.user.id' <<<"${OWNER_RESPONSE}")"
OWNER_TOKEN="$(jq -er '.access_token' <<<"${OWNER_RESPONSE}")"
CASHIER_AUTH_ID="$(jq -er '.user.id' <<<"${CASHIER_RESPONSE}")"
CASHIER_TOKEN="$(jq -er '.access_token' <<<"${CASHIER_RESPONSE}")"
STOCK_AUTH_ID="$(jq -er '.user.id' <<<"${STOCK_RESPONSE}")"
STOCK_TOKEN="$(jq -er '.access_token' <<<"${STOCK_RESPONSE}")"

echo "Seeding isolated stores, real Auth-backed role fixtures and inventory..."
psql "$DB_URL" -v ON_ERROR_STOP=1 \
  -v auth_user_id="$AUTH_USER_ID" -v user_a="$USER_A" \
  -v owner_auth_id="$OWNER_AUTH_ID" -v owner_user="$OWNER_USER" \
  -v cashier_auth_id="$CASHIER_AUTH_ID" -v cashier_user="$CASHIER_USER" \
  -v stock_auth_id="$STOCK_AUTH_ID" -v stock_user="$STOCK_USER" \
  -v store_a="$STORE_A" -v store_b="$STORE_B" \
  -v product_a="$PRODUCT_A" -v product_b="$PRODUCT_B" \
  -v store_b_user="$STORE_B_USER" <<'SQL'
INSERT INTO public.stores(id,name) VALUES
  (:'store_a'::uuid,'Auth smoke store A'),
  (:'store_b'::uuid,'Auth smoke store B');

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 (:'user_a'::uuid,:'auth_user_id'::uuid,:'store_a'::uuid,'auth-smoke-admin','Auth Smoke Admin',TRUE),
 (:'owner_user'::uuid,:'owner_auth_id'::uuid,:'store_a'::uuid,'auth-smoke-owner','Auth Smoke Owner',TRUE),
 (:'cashier_user'::uuid,:'cashier_auth_id'::uuid,:'store_a'::uuid,'auth-smoke-cashier','Auth Smoke Cashier',TRUE),
 (:'stock_user'::uuid,:'stock_auth_id'::uuid,:'store_a'::uuid,'auth-smoke-stock','Auth Smoke Stock Keeper',TRUE),
 (:'store_b_user'::uuid,'b4000000-0000-4000-8000-000000000003',:'store_b'::uuid,'auth-smoke-store-b','Other Store User',TRUE);

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 (:'user_a'::uuid,'admin'),
 (:'owner_user'::uuid,'owner'),
 (:'cashier_user'::uuid,'cashier'),
 (:'stock_user'::uuid,'stock_keeper'),
 (:'store_b_user'::uuid,'cashier');

INSERT INTO public.products(store_id,id,name,primary_unit_id,cost_price,default_sale_price)
VALUES
  (:'store_a'::uuid,:'product_a'::uuid,'Visible product','pcs',2,5),
  (:'store_b'::uuid,:'product_b'::uuid,'Hidden product','pcs',2,5);

INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
VALUES (:'product_a'::uuid,'main',10,0);

NOTIFY pgrst, 'reload schema';
SQL

echo "Waiting for PostgREST schema cache..."
sleep 3

expect_rpc_denied() {
  local label="$1"
  local token="$2"
  local function_name="$3"
  local payload="$4"
  local status
  status="$(curl --silent --show-error -o /tmp/atack-rpc-error.json -w '%{http_code}' \
    -X POST "${API_URL}/rest/v1/rpc/${function_name}" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "${payload}")"
  if [[ "${status}" =~ ^2 ]]; then
    echo "Unexpectedly allowed ${label}" >&2
    cat /tmp/atack-rpc-error.json >&2
    exit 1
  fi
}

rpc_call() {
  local token="$1"
  local function_name="$2"
  local payload="$3"
  curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/rest/v1/rpc/${function_name}" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "${payload}"
}

echo "Verifying JWT-backed store isolation through PostgREST..."
PRODUCTS="$(curl --fail-with-body --silent --show-error \
  "${API_URL}/rest/v1/products?select=id&order=id.asc" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")"
ACTUAL_IDS="$(jq -r '.[].id' <<<"${PRODUCTS}" | sort)"
EXPECTED_IDS="$(printf '%s\n' "${PRODUCT_A}" | sort)"
if [[ "${ACTUAL_IDS}" != "${EXPECTED_IDS}" ]]; then
  echo "Expected only store A product ${PRODUCT_A}, got: ${ACTUAL_IDS}" >&2
  exit 1
fi

echo "Verifying RPC role boundaries with real Auth JWTs..."
expect_rpc_denied "admin granting owner role" "${ADMIN_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${CASHIER_USER}" '{p_target_user_id:$user,p_role_id:"owner",p_action:"GRANT"}')"
rpc_call "${ADMIN_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${CASHIER_USER}" '{p_target_user_id:$user,p_role_id:"stock_keeper",p_action:"GRANT"}')" >/dev/null
rpc_call "${ADMIN_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${CASHIER_USER}" '{p_target_user_id:$user,p_role_id:"stock_keeper",p_action:"REVOKE"}')" >/dev/null
expect_rpc_denied "cashier managing user roles" "${CASHIER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${STOCK_USER}" '{p_target_user_id:$user,p_role_id:"cashier",p_action:"GRANT"}')"
expect_rpc_denied "admin managing a user from another store" "${ADMIN_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${STORE_B_USER}" '{p_target_user_id:$user,p_role_id:"cashier",p_action:"GRANT"}')"
expect_rpc_denied "NULL role-management action" "${ADMIN_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${CASHIER_USER}" '{p_target_user_id:$user,p_role_id:"cashier",p_action:null}')"
rpc_call "${OWNER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${CASHIER_USER}" '{p_target_user_id:$user,p_role_id:"admin",p_action:"GRANT"}')" >/dev/null
rpc_call "${OWNER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${CASHIER_USER}" '{p_target_user_id:$user,p_role_id:"admin",p_action:"REVOKE"}')" >/dev/null

echo "Verifying business RPC permission boundaries and a successful cashier sale..."
SALE_PAYLOAD="$(jq -nc --arg id "${SALE_ID}" --arg item "${SALE_ITEM_ID}" --arg product "${PRODUCT_A}" \
  --arg number "AUTH-RPC-${GITHUB_RUN_ID:-local}" \
  '{id:$id,invoice_number:$number,paid_amount:5,payment_method:"CASH",items:[{id:$item,product_id:$product,quantity:1,unit_id:"pcs",unit_price:5,discount_amount:0}]}')"
SALE_ARGS="$(jq -nc --arg store "${STORE_A}" --arg op "${SALE_OPERATION}" --argjson payload "${SALE_PAYLOAD}" \
  '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
SALE_RESULT="$(rpc_call "${CASHIER_TOKEN}" "process_sale_invoice" "${SALE_ARGS}")"
if [[ "$(jq -r '.success' <<<"${SALE_RESULT}")" != "true" ]]; then
  echo "Cashier's permitted sale RPC did not succeed: ${SALE_RESULT}" >&2
  exit 1
fi
expect_rpc_denied "stock keeper invoking the sales RPC" "${STOCK_TOKEN}" "process_sale_invoice" \
  "$(jq -nc --arg store "${STORE_A}" --arg op "a5000000-0000-4000-8000-000000000004" --argjson payload "${SALE_PAYLOAD}" \
    '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "admin invoking a business RPC for another store" "${ADMIN_TOKEN}" "process_sale_invoice" \
  "$(jq -nc --arg store "${STORE_B}" --arg op "b5000000-0000-4000-8000-000000000005" --argjson payload "${SALE_PAYLOAD}" \
    '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"

echo "Verifying authenticated direct writes to accounting tables are denied..."
WRITE_STATUS="$(curl --silent --show-error -o /tmp/journal-write-response.json -w '%{http_code}' \
  -X POST "${API_URL}/rest/v1/journal_entries" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  --data "$(jq -nc --arg store_id "${STORE_A}" '{store_id:$store_id}')")"
if [[ "${WRITE_STATUS}" =~ ^2 ]]; then
  echo "Unexpectedly allowed direct INSERT into journal_entries" >&2
  cat /tmp/journal-write-response.json >&2
  exit 1
fi

echo "PASS: real Supabase Auth JWT role matrix, store isolation, role-management RPC, business RPC permissions and protected accounting writes"
