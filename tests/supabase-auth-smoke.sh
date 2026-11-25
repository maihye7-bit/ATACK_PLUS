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
SUPPLIER_A="a4000000-0000-4000-8000-000000000001"
PURCHASE_ID="a6000000-0000-4000-8000-000000000001"
PURCHASE_ITEM_ID="a6000000-0000-4000-8000-000000000002"
PURCHASE_OPERATION="a6000000-0000-4000-8000-000000000003"
RECEIPT_ID="a6000000-0000-4000-8000-000000000004"
RECEIPT_OPERATION="a6000000-0000-4000-8000-000000000005"
PURCHASE_RETURN_ID="a6000000-0000-4000-8000-000000000006"
PURCHASE_RETURN_OPERATION="a6000000-0000-4000-8000-000000000007"
ADJUSTMENT_ID="a6000000-0000-4000-8000-000000000008"
ADJUSTMENT_OPERATION="a6000000-0000-4000-8000-000000000009"
SALE_RETURN_ID="a6000000-0000-4000-8000-000000000010"
SALE_RETURN_OPERATION="a6000000-0000-4000-8000-000000000011"
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
  -v store_b_user="$STORE_B_USER" -v supplier_a="$SUPPLIER_A" <<'SQL'
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

INSERT INTO public.suppliers(id,store_id,code,name,is_active)
VALUES (:'supplier_a'::uuid, :'store_a'::uuid, 'AUTH-SUP-001', 'Auth RPC Supplier', TRUE);

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
  if [[ "${status}" != "400" && "${status}" != "403" ]]; then
    echo "Expected an authorization rejection (HTTP 400/403) for ${label}, got HTTP ${status}" >&2
    cat /tmp/atack-rpc-error.json >&2
    exit 1
  fi
}

rpc_call() {
  local token="$1"
  local function_name="$2"
  local payload="$3"
  local status body
  status="$(curl --silent --show-error -o /tmp/atack-rpc-response.json -w '%{http_code}' \
    -X POST "${API_URL}/rest/v1/rpc/${function_name}" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "${payload}")"
  body="$(cat /tmp/atack-rpc-response.json)"
  if [[ ! "${status}" =~ ^2 ]]; then
    echo "RPC ${function_name} failed with HTTP ${status}: ${body}" >&2
    return 1
  fi
  printf '%s' "${body}"
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

echo "Verifying purchase, partial receipt, returns, stock adjustment and accounting via real JWT RPCs..."
PURCHASE_PAYLOAD="$(jq -nc --arg id "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" --arg supplier "$SUPPLIER_A" --arg product "$PRODUCT_A" --arg number "AUTH-PUR-$GITHUB_RUN_ID" '{id:$id,purchase_number:$number,supplier_id:$supplier,paid_amount:0,items:[{id:$item,product_id:$product,quantity:4,received_quantity:0,unit_id:"pcs",unit_price:12,cost_per_unit:12}]}')"
PURCHASE_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$PURCHASE_OPERATION" --argjson payload "$PURCHASE_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "cashier creating a purchase" "$CASHIER_TOKEN" "process_purchase" "$PURCHASE_ARGS"
PURCHASE_RESULT="$(rpc_call "$ADMIN_TOKEN" "process_purchase" "$PURCHASE_ARGS")"
[[ "$(jq -r '.success' <<<"$PURCHASE_RESULT")" == "true" ]] || { echo "Purchase creation failed: $PURCHASE_RESULT" >&2; exit 1; }

RECEIPT_PAYLOAD="$(jq -nc --arg id "$RECEIPT_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,items:[{purchase_item_id:$item,accepted_quantity:3,rejected_quantity:1,rejection_reason:"Damaged packaging"}]}')"
RECEIPT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$RECEIPT_OPERATION" --argjson payload "$RECEIPT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "cashier receiving a purchase" "$CASHIER_TOKEN" "process_purchase_receipt" "$RECEIPT_ARGS"
RECEIPT_RESULT="$(rpc_call "$STOCK_TOKEN" "process_purchase_receipt" "$RECEIPT_ARGS")"
[[ "$(jq -r '.success' <<<"$RECEIPT_RESULT")" == "true" ]] || { echo "Partial receipt failed: $RECEIPT_RESULT" >&2; exit 1; }
REPLAY_RESULT="$(rpc_call "$STOCK_TOKEN" "process_purchase_receipt" "$RECEIPT_ARGS")"
[[ "$(jq -r '.replayed' <<<"$REPLAY_RESULT")" == "true" ]] || { echo "Receipt retry was not idempotent: $REPLAY_RESULT" >&2; exit 1; }

OVER_RECEIPT_PAYLOAD="$(jq -nc --arg id "a6000000-0000-4000-8000-000000000012" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,items:[{purchase_item_id:$item,accepted_quantity:2}]}')"
OVER_RECEIPT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "a6000000-0000-4000-8000-000000000013" --argjson payload "$OVER_RECEIPT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "receipt beyond outstanding quantity" "$STOCK_TOKEN" "process_purchase_receipt" "$OVER_RECEIPT_ARGS"

PURCHASE_RETURN_PAYLOAD="$(jq -nc --arg id "$PURCHASE_RETURN_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" --arg product "$PRODUCT_A" '{id:$id,purchase_id:$purchase,return_number:"AUTH-PRET-001",refund_method:"CREDIT",items:[{purchase_item_id:$item,product_id:$product,quantity:1,unit_id:"pcs"}]}')"
PURCHASE_RETURN_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$PURCHASE_RETURN_OPERATION" --argjson payload "$PURCHASE_RETURN_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "stock keeper processing supplier return" "$STOCK_TOKEN" "process_purchase_return" "$PURCHASE_RETURN_ARGS"
PURCHASE_RETURN_RESULT="$(rpc_call "$ADMIN_TOKEN" "process_purchase_return" "$PURCHASE_RETURN_ARGS")"
[[ "$(jq -r '.success' <<<"$PURCHASE_RETURN_RESULT")" == "true" ]] || { echo "Purchase return failed: $PURCHASE_RETURN_RESULT" >&2; exit 1; }
expect_rpc_denied "purchase return against another store" "$ADMIN_TOKEN" "process_purchase_return" "$(jq -nc --arg op "b6000000-0000-4000-8000-000000000014" --argjson payload "$PURCHASE_RETURN_PAYLOAD" '{p_store_id:"b1000000-0000-4000-8000-000000000002",p_operation_id:$op,p_payload:$payload}')"

ADJUSTMENT_PAYLOAD="$(jq -nc --arg id "$ADJUSTMENT_ID" --arg product "$PRODUCT_A" '{id:$id,product_id:$product,adjustment_type:"INCREASE",reason:"Authenticated stock count correction",quantity:1,unit_id:"pcs",cost_per_unit:12,location_id:"main"}')"
ADJUSTMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$ADJUSTMENT_OPERATION" --argjson payload "$ADJUSTMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "stock keeper privileged adjustment" "$STOCK_TOKEN" "process_stock_adjustment" "$ADJUSTMENT_ARGS"
ADJUSTMENT_RESULT="$(rpc_call "$OWNER_TOKEN" "process_stock_adjustment" "$ADJUSTMENT_ARGS")"
[[ "$(jq -r '.success' <<<"$ADJUSTMENT_RESULT")" == "true" ]] || { echo "Stock adjustment failed: $ADJUSTMENT_RESULT" >&2; exit 1; }

SALE_RETURN_PAYLOAD="$(jq -nc --arg id "$SALE_RETURN_ID" --arg invoice "$SALE_ID" --arg product "$PRODUCT_A" --arg item "$SALE_ITEM_ID" '{id:$id,invoice_id:$invoice,return_number:"AUTH-SRET-001",refund_method:"CREDIT",items:[{invoice_item_id:$item,product_id:$product,quantity:1,unit_id:"pcs"}]}')"
SALE_RETURN_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$SALE_RETURN_OPERATION" --argjson payload "$SALE_RETURN_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
SALE_RETURN_RESULT="$(rpc_call "$CASHIER_TOKEN" "process_sale_return" "$SALE_RETURN_ARGS")"
[[ "$(jq -r '.success' <<<"$SALE_RETURN_RESULT")" == "true" ]] || { echo "Sale return failed: $SALE_RETURN_RESULT" >&2; exit 1; }

expect_rpc_denied "purchase creation for another store" "$ADMIN_TOKEN" "process_purchase" "$(jq -nc --arg op "b6000000-0000-4000-8000-000000000015" --argjson payload "$PURCHASE_PAYLOAD" '{p_store_id:"b1000000-0000-4000-8000-000000000002",p_operation_id:$op,p_payload:$payload}')"

psql "$DB_URL" -v ON_ERROR_STOP=1 -v store_a="$STORE_A" -v product_a="$PRODUCT_A" -v purchase_id="$PURCHASE_ID" -v purchase_item_id="$PURCHASE_ITEM_ID" -v purchase_return_id="$PURCHASE_RETURN_ID" -v adjustment_id="$ADJUSTMENT_ID" -v sale_return_id="$SALE_RETURN_ID" <<'SQL'
SELECT set_config('atack.test.store_a', :'store_a', false);
SELECT set_config('atack.test.product_a', :'product_a', false);
SELECT set_config('atack.test.purchase_id', :'purchase_id', false);
SELECT set_config('atack.test.purchase_item_id', :'purchase_item_id', false);
SELECT set_config('atack.test.purchase_return_id', :'purchase_return_id', false);
SELECT set_config('atack.test.adjustment_id', :'adjustment_id', false);
SELECT set_config('atack.test.sale_return_id', :'sale_return_id', false);
DO $assert_business$
DECLARE
  v_stock NUMERIC(18,4);
  v_received NUMERIC(18,4);
  v_returned NUMERIC(18,4);
  v_supplier_payments INTEGER;
  v_debit NUMERIC(18,4);
  v_credit NUMERIC(18,4);
BEGIN
  SELECT quantity INTO v_stock FROM public.stock WHERE product_id=current_setting('atack.test.product_a')::uuid AND location_id='main';
  SELECT received_quantity INTO v_received FROM public.purchase_items WHERE id=current_setting('atack.test.purchase_item_id')::uuid AND purchase_id=current_setting('atack.test.purchase_id')::uuid;
  SELECT total_amount INTO v_returned FROM public.purchase_returns WHERE id=current_setting('atack.test.purchase_return_id')::uuid AND store_id=current_setting('atack.test.store_a')::uuid;
  IF v_received<>3 THEN RAISE EXCEPTION 'Partial receipt quantity mismatch: %',v_received; END IF;
  IF v_returned<>12 THEN RAISE EXCEPTION 'Purchase return amount mismatch: %',v_returned; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock_adjustments WHERE id=current_setting('atack.test.adjustment_id')::uuid AND store_id=current_setting('atack.test.store_a')::uuid) THEN RAISE EXCEPTION 'Stock adjustment record missing'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_returns WHERE id=current_setting('atack.test.sale_return_id')::uuid AND store_id=current_setting('atack.test.store_a')::uuid) THEN RAISE EXCEPTION 'Sale return record missing'; END IF;
  IF v_stock<>13 THEN RAISE EXCEPTION 'Unexpected final stock after sale, receipt, returns and adjustment: %',v_stock; END IF;
  SELECT count(*) INTO v_supplier_payments FROM public.supplier_payments WHERE supplier_id=(SELECT supplier_id FROM public.purchases WHERE id=current_setting('atack.test.purchase_id')::uuid);
  IF v_supplier_payments<>0 THEN RAISE EXCEPTION 'Purchase return unexpectedly created supplier cash/bank payment'; END IF;
  SELECT COALESCE(SUM(total_debit),0),COALESCE(SUM(total_credit),0) INTO v_debit,v_credit FROM public.v_trial_balance WHERE store_id=current_setting('atack.test.store_a')::uuid;
  IF round(v_debit,4)<>round(v_credit,4) THEN RAISE EXCEPTION 'Trial balance unbalanced after RPC operations: debit %, credit %',v_debit,v_credit; END IF;
END
$assert_business$;
SQL

echo "Verifying authenticated direct writes to accounting tables are denied..."
WRITE_STATUS="$(curl --silent --show-error -o /tmp/journal-write-response.json -w '%{http_code}' \
  -X POST "${API_URL}/rest/v1/journal_entries" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  --data "$(jq -nc --arg store_id "${STORE_A}" '{store_id:$store_id}')")"
if [[ "${WRITE_STATUS}" != "403" ]] || [[ "$(jq -r '.code // empty' /tmp/journal-write-response.json)" != "42501" ]]; then
  echo "Expected PostgreSQL privilege denial (HTTP 403 / SQLSTATE 42501) for direct journal INSERT, got HTTP ${WRITE_STATUS}" >&2
  cat /tmp/journal-write-response.json >&2
  exit 1
fi

echo "PASS: real Supabase Auth JWT role matrix, store isolation, role-management RPC, business RPC permissions and protected accounting writes"
