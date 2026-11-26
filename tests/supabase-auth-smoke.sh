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
SELLER_USER="a3000000-0000-4000-8000-000000000003"
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
PURCHASE_AMENDMENT_ID="a6000000-0000-4000-8000-000000000020"
PURCHASE_AMENDMENT_OPERATION="a6000000-0000-4000-8000-000000000021"
PURCHASE_CLOSURE_ID="a6000000-0000-4000-8000-000000000022"
PURCHASE_CLOSURE_OPERATION="a6000000-0000-4000-8000-000000000023"
SUPPLIER_PAYMENT_ID="a6000000-0000-4000-8000-000000000024"
SUPPLIER_PAYMENT_OPERATION="a6000000-0000-4000-8000-000000000025"
SALE_RETURN_ID="a6000000-0000-4000-8000-000000000010"
SALE_RETURN_OPERATION="a6000000-0000-4000-8000-000000000011"
SALE_ID="a5000000-0000-4000-8000-000000000001"
SALE_ITEM_ID="a5000000-0000-4000-8000-000000000002"
SALE_OPERATION="a5000000-0000-4000-8000-000000000003"
CUSTOMER_A="a4000000-0000-4000-8000-000000000002"
CUSTOMER_B="a4000000-0000-4000-8000-000000000003"
CUSTOMER_SALE_ID="a5000000-0000-4000-8000-000000000004"
CUSTOMER_SALE_ITEM_ID="a5000000-0000-4000-8000-000000000005"
CUSTOMER_SALE_OPERATION="a5000000-0000-4000-8000-000000000006"
CUSTOMER_PAYMENT_ID="a5000000-0000-4000-8000-000000000007"
CUSTOMER_PAYMENT_OPERATION="a5000000-0000-4000-8000-000000000008"
OWNER_CUSTOMER_PAYMENT_ID="a5000000-0000-4000-8000-000000000014"
SELLER_OWN_PAYMENT_ID="a5000000-0000-4000-8000-000000000018"
SELLER_OWN_PAYMENT_OPERATION="a5000000-0000-4000-8000-000000000019"
SYNC_DEVICE_A="a7000000-0000-4000-8000-000000000001"
OUTBOX_CATEGORY_ID="a7000000-0000-4000-8000-000000000002"
OUTBOX_IDEMPOTENCY_KEY="a7000000-0000-4000-8000-000000000003"

signup_identity() {
  local label="$1"
  curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/auth/v1/signup" \
    -H "apikey: ${ANON_KEY}" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg email "auth-smoke-${GITHUB_RUN_ID:-local}-${label}@example.test" --arg password "${PASSWORD}" '{email:$email,password:$password}')"
}

echo "Creating real Supabase Auth identities for the store owner and sellers..."
OWNER_RESPONSE="$(signup_identity owner)"
SELLER_RESPONSE="$(signup_identity seller)"
STORE_B_RESPONSE="$(signup_identity store-b)"
AUTH_USER_ID="$(jq -er '.user.id' <<<"${OWNER_RESPONSE}")"
OWNER_TOKEN="$(jq -er '.access_token' <<<"${OWNER_RESPONSE}")"
SELLER_AUTH_ID="$(jq -er '.user.id' <<<"${SELLER_RESPONSE}")"
SELLER_TOKEN="$(jq -er '.access_token' <<<"${SELLER_RESPONSE}")"
STORE_B_AUTH_ID="$(jq -er '.user.id' <<<"${STORE_B_RESPONSE}")"
STORE_B_TOKEN="$(jq -er '.access_token' <<<"${STORE_B_RESPONSE}")"

echo "Seeding isolated stores, real Auth-backed role fixtures and inventory..."
psql "$DB_URL" -v ON_ERROR_STOP=1 \
  -v auth_user_id="$AUTH_USER_ID" -v user_a="$USER_A" \
  -v seller_auth_id="$SELLER_AUTH_ID" -v seller_user="$SELLER_USER" \
  -v store_b_auth_id="$STORE_B_AUTH_ID" \
  -v store_a="$STORE_A" -v store_b="$STORE_B" \
  -v product_a="$PRODUCT_A" -v product_b="$PRODUCT_B" \
  -v store_b_user="$STORE_B_USER" -v supplier_a="$SUPPLIER_A" \
  -v customer_a="$CUSTOMER_A" -v customer_b="$CUSTOMER_B" -v sync_device_a="$SYNC_DEVICE_A" <<'SQL'
INSERT INTO public.stores(id,name) VALUES
  (:'store_a'::uuid,'Auth smoke store A'),
  (:'store_b'::uuid,'Auth smoke store B');

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 (:'user_a'::uuid,:'auth_user_id'::uuid,:'store_a'::uuid,'auth-smoke-owner','Auth Smoke Store Owner',TRUE),
 (:'seller_user'::uuid,:'seller_auth_id'::uuid,:'store_a'::uuid,'auth-smoke-seller','Auth Smoke Seller',TRUE),
 (:'store_b_user'::uuid,:'store_b_auth_id'::uuid,:'store_b'::uuid,'auth-smoke-store-b','Other Store Seller',TRUE);

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 (:'user_a'::uuid,'owner'),
 (:'seller_user'::uuid,'cashier'),
 (:'store_b_user'::uuid,'cashier');

INSERT INTO public.suppliers(id,store_id,code,name,is_active)
VALUES (:'supplier_a'::uuid, :'store_a'::uuid, 'AUTH-SUP-001', 'Auth RPC Supplier', TRUE);

INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
VALUES
 (:'customer_a'::uuid, :'store_a'::uuid, 'AUTH-CUST-001', 'Auth RPC Customer', 0, 0, TRUE),
 (:'customer_b'::uuid, :'store_a'::uuid, 'AUTH-CUST-002', 'Seller Allocation Isolation Customer', 11, 0, TRUE);

INSERT INTO public.products(store_id,id,name,primary_unit_id,cost_price,default_sale_price)
VALUES
  (:'store_a'::uuid,:'product_a'::uuid,'Visible product','pcs',2,5),
  (:'store_b'::uuid,:'product_b'::uuid,'Hidden product','pcs',2,5);

INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
VALUES (:'product_a'::uuid,'main',10,0);

-- Owner-created sale proves sellers cannot read another user's invoice.
INSERT INTO public.invoices(
  id,store_id,invoice_number,type,customer_id,invoice_date,total_amount,paid_amount,remaining_amount,created_by,status
) VALUES (
  'a5000000-0000-4000-8000-000000000009',
  :'store_a'::uuid,'AUTH-OWNER-PRIVATE-001','SALE',:'customer_b'::uuid,NOW()-INTERVAL '1 day',4,1,3,:'user_a'::uuid,'PARTIAL'
);

-- A later seller-owned open invoice shares the same customer. The seller's
-- automatic receipt must skip the older owner invoice and settle only this one.
INSERT INTO public.invoices(
  id,store_id,invoice_number,type,customer_id,invoice_date,total_amount,paid_amount,remaining_amount,created_by,status
) VALUES (
  'a5000000-0000-4000-8000-000000000017',
  :'store_a'::uuid,'AUTH-SELLER-OWN-OPEN-001','SALE',:'customer_b'::uuid,NOW(),8,0,8,:'seller_user'::uuid,'OPEN'
);

-- A customer receipt belonging to the owner and its ledger/allocation rows
-- are seeded to verify that a seller cannot read another seller's financial activity.
INSERT INTO public.customer_payments(id,customer_id,amount,payment_method,created_by)
VALUES ('a5000000-0000-4000-8000-000000000014',:'customer_b'::uuid,1,'CASH',:'user_a'::uuid);
INSERT INTO public.payment_allocations(payment_id,invoice_id,allocated_amount)
VALUES ('a5000000-0000-4000-8000-000000000014','a5000000-0000-4000-8000-000000000009',1);
INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,description,created_by)
VALUES (:'customer_b'::uuid,'PAYMENT',-1,10,'a5000000-0000-4000-8000-000000000014',
        'Owner-only customer payment fixture',:'user_a'::uuid);

INSERT INTO public.devices(id,store_id,device_name,device_type)
VALUES (:'sync_device_a'::uuid,:'store_a'::uuid,'Auth Smoke Sync Device','DESKTOP');

NOTIFY pgrst, 'reload schema';
SQL

echo "Waiting for PostgREST schema cache..."
sleep 3

expect_rpc_error() {
  local label="$1"
  local token="$2"
  local function_name="$3"
  local payload="$4"
  local expected_code="$5"
  local status actual_code
  status="$(curl --silent --show-error -o /tmp/atack-rpc-error.json -w '%{http_code}' \
    -X POST "${API_URL}/rest/v1/rpc/${function_name}" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "${payload}")"
  actual_code="$(jq -r '.code // empty' /tmp/atack-rpc-error.json)"
  if [[ "${status}" != "400" && "${status}" != "403" ]] || [[ "${actual_code}" != "${expected_code}" ]]; then
    echo "Expected SQLSTATE ${expected_code} for ${label}, got HTTP ${status} / SQLSTATE ${actual_code}" >&2
    cat /tmp/atack-rpc-error.json >&2
    exit 1
  fi
}

expect_rpc_denied() {
  expect_rpc_error "$1" "$2" "$3" "$4" "42501"
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

echo "Verifying real-JWT isolation for stores and users across two stores..."
OWNER_STORES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/stores?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
SELLER_STORES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/stores?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
STORE_B_STORES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/stores?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${STORE_B_TOKEN}")"
OWNER_USERS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/users?select=id,store_id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
SELLER_USERS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/users?select=id,store_id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
STORE_B_USERS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/users?select=id,store_id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${STORE_B_TOKEN}")"
[[ "$(jq 'length' <<<"${OWNER_STORES}")" -eq 1 && "$(jq -r '.[0].id' <<<"${OWNER_STORES}")" == "${STORE_A}" ]] || { echo "Owner stores isolation failed: ${OWNER_STORES}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_STORES}")" -eq 1 && "$(jq -r '.[0].id' <<<"${SELLER_STORES}")" == "${STORE_A}" ]] || { echo "Seller stores isolation failed: ${SELLER_STORES}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${STORE_B_STORES}")" -eq 1 && "$(jq -r '.[0].id' <<<"${STORE_B_STORES}")" == "${STORE_B}" ]] || { echo "Store B stores isolation failed: ${STORE_B_STORES}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_USERS}")" -eq 2 && "$(jq -e --arg store "${STORE_A}" 'all(.[]; .store_id==$store)' <<<"${OWNER_USERS}")" == "true" ]] || { echo "Owner users isolation failed: ${OWNER_USERS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_USERS}")" -eq 1 && "$(jq -r '.[0].id' <<<"${SELLER_USERS}")" == "${SELLER_USER}" ]] || { echo "Seller profile isolation failed: ${SELLER_USERS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${STORE_B_USERS}")" -eq 1 && "$(jq -r '.[0].id' <<<"${STORE_B_USERS}")" == "${STORE_B_USER}" ]] || { echo "Store B profile isolation failed: ${STORE_B_USERS}" >&2; exit 1; }

echo "Verifying JWT-backed store isolation through PostgREST..."
PRODUCTS="$(curl --fail-with-body --silent --show-error \
  "${API_URL}/rest/v1/products?select=id&order=id.asc" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${OWNER_TOKEN}")"
ACTUAL_IDS="$(jq -r '.[].id' <<<"${PRODUCTS}" | sort)"
EXPECTED_IDS="$(printf '%s\n' "${PRODUCT_A}" | sort)"
if [[ "${ACTUAL_IDS}" != "${EXPECTED_IDS}" ]]; then
  echo "Expected only store A product ${PRODUCT_A}, got: ${ACTUAL_IDS}" >&2
  exit 1
fi

echo "Verifying owner/seller role boundaries with real Auth JWTs..."
expect_rpc_error "seller attempting to grant owner role" "${SELLER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${SELLER_USER}" '{p_target_user_id:$user,p_role_id:"owner",p_action:"GRANT"}')" "P0001"
expect_rpc_error "seller managing user roles" "${SELLER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${SELLER_USER}" '{p_target_user_id:$user,p_role_id:"cashier",p_action:"GRANT"}')" "P0001"
expect_rpc_error "owner managing a user from another store" "${OWNER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${STORE_B_USER}" '{p_target_user_id:$user,p_role_id:"cashier",p_action:"GRANT"}')" "P0001"
expect_rpc_error "NULL role-management action" "${OWNER_TOKEN}" "manage_store_user_role" \
  "$(jq -nc --arg user "${SELLER_USER}" '{p_target_user_id:$user,p_role_id:"cashier",p_action:null}')" "P0001"
echo "Verifying business RPC permission boundaries and a successful seller sale..."
SALE_PAYLOAD="$(jq -nc --arg id "${SALE_ID}" --arg item "${SALE_ITEM_ID}" --arg product "${PRODUCT_A}" --arg customer "${CUSTOMER_A}" \
  --arg number "AUTH-RPC-${GITHUB_RUN_ID:-local}" \
  '{id:$id,invoice_number:$number,customer_id:$customer,paid_amount:5,payment_method:"CASH",items:[{id:$item,product_id:$product,quantity:1,unit_id:"pcs",unit_price:5,discount_amount:0}]}')"
SALE_ARGS="$(jq -nc --arg store "${STORE_A}" --arg op "${SALE_OPERATION}" --argjson payload "${SALE_PAYLOAD}" \
  '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
SALE_RESULT="$(rpc_call "${SELLER_TOKEN}" "process_sale_invoice" "${SALE_ARGS}")"
if [[ "$(jq -r '.success' <<<"${SALE_RESULT}")" != "true" ]]; then
  echo "Seller's permitted sale RPC did not succeed: ${SALE_RESULT}" >&2
  exit 1
fi
expect_rpc_denied "owner invoking a business RPC for another store" "${OWNER_TOKEN}" "process_sale_invoice" \
  "$(jq -nc --arg store "${STORE_B}" --arg op "b5000000-0000-4000-8000-000000000005" --argjson payload "${SALE_PAYLOAD}" \
    '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"

echo "Verifying Push/Outbox enqueue and apply with a real Supabase Auth JWT..."
OUTBOX_RECORD="$(jq -nc --arg id "$OUTBOX_CATEGORY_ID" --arg store "$STORE_A" '{id:$id,store_id:$store,name:"JWT Outbox category",is_active:true}')"
OUTBOX_ARGS="$(jq -nc --arg store "$STORE_A" --arg device "$SYNC_DEVICE_A" --arg record "$OUTBOX_CATEGORY_ID" --arg key "$OUTBOX_IDEMPOTENCY_KEY" --argjson payload "$OUTBOX_RECORD" '{p_store_id:$store,p_device_id:$device,p_table_name:"categories",p_operation:"INSERT",p_record_uuid:$record,p_idempotency_key:$key,p_record_json:$payload}')"
OUTBOX_ID="$(rpc_call "$OWNER_TOKEN" "create_outbox_entry" "$OUTBOX_ARGS" | jq -er '.')"
OUTBOX_REPLAY_ID="$(rpc_call "$OWNER_TOKEN" "create_outbox_entry" "$OUTBOX_ARGS" | jq -er '.')"
[[ "$OUTBOX_ID" == "$OUTBOX_REPLAY_ID" ]] || { echo "JWT Push replay created a duplicate Outbox entry" >&2; exit 1; }
APPLY_ARGS="$(jq -nc --arg id "$OUTBOX_ID" '{p_outbox_id:$id}')"
APPLY_RESULT="$(rpc_call "$OWNER_TOKEN" "apply_outbox_operation" "$APPLY_ARGS")"
[[ "$(jq -r '.success' <<<"$APPLY_RESULT")" == "true" ]] || { echo "JWT Outbox apply failed: $APPLY_RESULT" >&2; exit 1; }
APPLY_REPLAY="$(rpc_call "$OWNER_TOKEN" "apply_outbox_operation" "$APPLY_ARGS")"
[[ "$(jq -r '.success' <<<"$APPLY_REPLAY")" == "true" && "$(jq -r '.duplicate' <<<"$APPLY_REPLAY")" == "true" ]] || { echo "JWT Outbox apply replay was not idempotent: $APPLY_REPLAY" >&2; exit 1; }
CROSS_STORE_ARGS="$(jq -nc --arg device "$SYNC_DEVICE_A" --arg record "a7000000-0000-4000-8000-000000000004" --arg key "a7000000-0000-4000-8000-000000000005" '{p_store_id:"b1000000-0000-4000-8000-000000000002",p_device_id:$device,p_table_name:"categories",p_operation:"INSERT",p_record_uuid:$record,p_idempotency_key:$key,p_record_json:{id:$record,store_id:"b1000000-0000-4000-8000-000000000002",name:"Cross-store JWT Push"}}')"
expect_rpc_error "JWT Push targeting another store" "$OWNER_TOKEN" "create_outbox_entry" "$CROSS_STORE_ARGS" "P0001"
PROTECTED_PUSH_ARGS="$(jq -nc --arg store "$STORE_A" --arg device "$SYNC_DEVICE_A" --arg record "a7000000-0000-4000-8000-000000000006" --arg key "a7000000-0000-4000-8000-000000000007" '{p_store_id:$store,p_device_id:$device,p_table_name:"categories",p_operation:"INSERT",p_record_uuid:$record,p_idempotency_key:$key,p_record_json:{id:$record,store_id:$store,name:"Protected JWT Push",created_by:"forbidden"}}')"
expect_rpc_error "JWT Push containing protected columns" "$OWNER_TOKEN" "create_outbox_entry" "$PROTECTED_PUSH_ARGS" "P0001"
psql "$DB_URL" -v ON_ERROR_STOP=1 -v outbox_category="$OUTBOX_CATEGORY_ID" -v store_a="$STORE_A" <<'SQL'
SELECT set_config('atack.test.outbox_category', :'outbox_category', false);
SELECT set_config('atack.test.store_a', :'store_a', false);
DO $assert_jwt_outbox$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.categories
    WHERE id=current_setting('atack.test.outbox_category')::uuid
      AND store_id=current_setting('atack.test.store_a')::uuid
      AND name='JWT Outbox category') THEN
    RAISE EXCEPTION 'Real JWT Outbox operation did not persist the category';
  END IF;
END
$assert_jwt_outbox$;
SQL
echo "Verifying owner-controlled purchasing, inventory, returns and accounting via real JWT RPCs..."
PURCHASE_PAYLOAD="$(jq -nc --arg id "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" --arg supplier "$SUPPLIER_A" --arg product "$PRODUCT_A" --arg number "AUTH-PUR-$GITHUB_RUN_ID" '{id:$id,purchase_number:$number,supplier_id:$supplier,paid_amount:0,items:[{id:$item,product_id:$product,quantity:4,received_quantity:0,unit_id:"pcs",unit_price:12,cost_per_unit:12}]}')"
PURCHASE_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$PURCHASE_OPERATION" --argjson payload "$PURCHASE_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller creating a purchase" "$SELLER_TOKEN" "process_purchase" "$PURCHASE_ARGS"
PURCHASE_RESULT="$(rpc_call "$OWNER_TOKEN" "process_purchase" "$PURCHASE_ARGS")"
[[ "$(jq -r '.success' <<<"$PURCHASE_RESULT")" == "true" ]] || { echo "Purchase creation failed: $PURCHASE_RESULT" >&2; exit 1; }

RECEIPT_PAYLOAD="$(jq -nc --arg id "$RECEIPT_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,items:[{purchase_item_id:$item,accepted_quantity:3,rejected_quantity:1,rejection_reason:"Damaged packaging"}]}')"
RECEIPT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$RECEIPT_OPERATION" --argjson payload "$RECEIPT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller receiving a purchase" "$SELLER_TOKEN" "process_purchase_receipt" "$RECEIPT_ARGS"
RECEIPT_RESULT="$(rpc_call "$OWNER_TOKEN" "process_purchase_receipt" "$RECEIPT_ARGS")"
[[ "$(jq -r '.success' <<<"$RECEIPT_RESULT")" == "true" ]] || { echo "Partial receipt failed: $RECEIPT_RESULT" >&2; exit 1; }
REPLAY_RESULT="$(rpc_call "$OWNER_TOKEN" "process_purchase_receipt" "$RECEIPT_ARGS")"
[[ "$(jq -r '.replayed' <<<"$REPLAY_RESULT")" == "true" ]] || { echo "Receipt retry was not idempotent: $REPLAY_RESULT" >&2; exit 1; }

OVER_RECEIPT_PAYLOAD="$(jq -nc --arg id "a6000000-0000-4000-8000-000000000012" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,items:[{purchase_item_id:$item,accepted_quantity:2}]}')"
OVER_RECEIPT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "a6000000-0000-4000-8000-000000000013" --argjson payload "$OVER_RECEIPT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_error "receipt beyond outstanding quantity" "$OWNER_TOKEN" "process_purchase_receipt" "$OVER_RECEIPT_ARGS" "23514"

PURCHASE_RETURN_PAYLOAD="$(jq -nc --arg id "$PURCHASE_RETURN_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" --arg product "$PRODUCT_A" '{id:$id,purchase_id:$purchase,return_number:"AUTH-PRET-001",refund_method:"CREDIT",items:[{purchase_item_id:$item,product_id:$product,quantity:1,unit_id:"pcs"}]}')"
PURCHASE_RETURN_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$PURCHASE_RETURN_OPERATION" --argjson payload "$PURCHASE_RETURN_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller processing supplier return" "$SELLER_TOKEN" "process_purchase_return" "$PURCHASE_RETURN_ARGS"
PURCHASE_RETURN_RESULT="$(rpc_call "$OWNER_TOKEN" "process_purchase_return" "$PURCHASE_RETURN_ARGS")"
[[ "$(jq -r '.success' <<<"$PURCHASE_RETURN_RESULT")" == "true" ]] || { echo "Purchase return failed: $PURCHASE_RETURN_RESULT" >&2; exit 1; }
expect_rpc_denied "purchase return against another store" "$OWNER_TOKEN" "process_purchase_return" "$(jq -nc --arg op "b6000000-0000-4000-8000-000000000014" --argjson payload "$PURCHASE_RETURN_PAYLOAD" '{p_store_id:"b1000000-0000-4000-8000-000000000002",p_operation_id:$op,p_payload:$payload}')"

ADJUSTMENT_PAYLOAD="$(jq -nc --arg id "$ADJUSTMENT_ID" --arg product "$PRODUCT_A" '{id:$id,product_id:$product,adjustment_type:"INCREASE",reason:"Authenticated stock count correction",quantity:1,unit_id:"pcs",cost_per_unit:12,location_id:"main"}')"
ADJUSTMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$ADJUSTMENT_OPERATION" --argjson payload "$ADJUSTMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller privileged stock adjustment" "$SELLER_TOKEN" "process_stock_adjustment" "$ADJUSTMENT_ARGS"
ADJUSTMENT_RESULT="$(rpc_call "$OWNER_TOKEN" "process_stock_adjustment" "$ADJUSTMENT_ARGS")"
[[ "$(jq -r '.success' <<<"$ADJUSTMENT_RESULT")" == "true" ]] || { echo "Stock adjustment failed: $ADJUSTMENT_RESULT" >&2; exit 1; }

FOREIGN_SALE_RETURN_PAYLOAD="$(jq -nc --arg id "a6000000-0000-4000-8000-000000000030" --arg invoice "a5000000-0000-4000-8000-000000000009" '{id:$id,invoice_id:$invoice,return_number:"AUTH-FOREIGN-SELLER-RETURN",items:[]}')"
FOREIGN_SALE_RETURN_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "a6000000-0000-4000-8000-000000000031" --argjson payload "$FOREIGN_SALE_RETURN_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_error "seller returning another seller's invoice" "$SELLER_TOKEN" "process_sale_return" "$FOREIGN_SALE_RETURN_ARGS" "P0001"

SALE_RETURN_PAYLOAD="$(jq -nc --arg id "$SALE_RETURN_ID" --arg invoice "$SALE_ID" --arg product "$PRODUCT_A" --arg item "$SALE_ITEM_ID" '{id:$id,invoice_id:$invoice,return_number:"AUTH-SRET-001",refund_method:"CREDIT",items:[{invoice_item_id:$item,product_id:$product,quantity:1,unit_id:"pcs"}]}')"
SALE_RETURN_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$SALE_RETURN_OPERATION" --argjson payload "$SALE_RETURN_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
SALE_RETURN_RESULT="$(rpc_call "$SELLER_TOKEN" "process_sale_return" "$SALE_RETURN_ARGS")"
[[ "$(jq -r '.success' <<<"$SALE_RETURN_RESULT")" == "true" ]] || { echo "Sale return failed: $SALE_RETURN_RESULT" >&2; exit 1; }

expect_rpc_denied "purchase creation for another store" "$OWNER_TOKEN" "process_purchase" "$(jq -nc --arg op "b6000000-0000-4000-8000-000000000015" --argjson payload "$PURCHASE_PAYLOAD" '{p_store_id:"b1000000-0000-4000-8000-000000000002",p_operation_id:$op,p_payload:$payload}')"

echo "Verifying D-054/D-055 amendment and closure RPCs with real JWTs..."
INVALID_AMENDMENT_PAYLOAD="$(jq -nc --arg id "$PURCHASE_AMENDMENT_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,reason:"Attempt to reduce below received plus returned quantity",items:[{purchase_item_id:$item,quantity:3,unit_price:12,cost_per_unit:12}]}')"
INVALID_AMENDMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "a6000000-0000-4000-8000-000000000026" --argjson payload "$INVALID_AMENDMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_error "amendment below received plus returned quantity" "$OWNER_TOKEN" "process_purchase_amendment" "$INVALID_AMENDMENT_ARGS" "23514"

AMENDMENT_PAYLOAD="$(jq -nc --arg id "$PURCHASE_AMENDMENT_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,reason:"Approved post-receipt price and quantity amendment",items:[{purchase_item_id:$item,quantity:5,unit_price:13,cost_per_unit:13}]}')"
AMENDMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$PURCHASE_AMENDMENT_OPERATION" --argjson payload "$AMENDMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller amending a received purchase" "$SELLER_TOKEN" "process_purchase_amendment" "$AMENDMENT_ARGS"
AMENDMENT_RESULT="$(rpc_call "$OWNER_TOKEN" "process_purchase_amendment" "$AMENDMENT_ARGS")"
[[ "$(jq -r '.success' <<<"$AMENDMENT_RESULT")" == "true" ]] || { echo "Purchase amendment failed: $AMENDMENT_RESULT" >&2; exit 1; }

CLOSURE_PAYLOAD="$(jq -nc --arg id "$PURCHASE_CLOSURE_ID" --arg purchase "$PURCHASE_ID" --arg item "$PURCHASE_ITEM_ID" '{id:$id,purchase_id:$purchase,reason:"Supplier confirmed remaining quantity cannot be delivered",items:[{purchase_item_id:$item,quantity:2,reason:"Supplier out of stock"}]}')"
CLOSURE_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$PURCHASE_CLOSURE_OPERATION" --argjson payload "$CLOSURE_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller closing unreceived purchase quantity" "$SELLER_TOKEN" "process_purchase_close_remaining" "$CLOSURE_ARGS"
STOCK_BEFORE_CLOSURE="$(psql "$DB_URL" -Atqc "SELECT quantity FROM public.stock WHERE product_id='${PRODUCT_A}'::uuid AND location_id='main'")"
CLOSURE_RESULT="$(rpc_call "$OWNER_TOKEN" "process_purchase_close_remaining" "$CLOSURE_ARGS")"
[[ "$(jq -r '.success' <<<"$CLOSURE_RESULT")" == "true" ]] || { echo "Purchase closure failed: $CLOSURE_RESULT" >&2; exit 1; }
STOCK_AFTER_CLOSURE="$(psql "$DB_URL" -Atqc "SELECT quantity FROM public.stock WHERE product_id='${PRODUCT_A}'::uuid AND location_id='main'")"
[[ "$STOCK_BEFORE_CLOSURE" == "$STOCK_AFTER_CLOSURE" ]] || { echo "Closing unreceived purchase quantity changed stock: before=$STOCK_BEFORE_CLOSURE after=$STOCK_AFTER_CLOSURE" >&2; exit 1; }

echo "Verifying customer and supplier payment RPCs and accounting journals..."
CUSTOMER_SALE_PAYLOAD="$(jq -nc --arg id "$CUSTOMER_SALE_ID" --arg item "$CUSTOMER_SALE_ITEM_ID" --arg product "$PRODUCT_A" --arg customer "$CUSTOMER_A" --arg number "AUTH-CUST-SALE-$GITHUB_RUN_ID" '{id:$id,invoice_number:$number,customer_id:$customer,paid_amount:0,payment_method:"CASH",items:[{id:$item,product_id:$product,quantity:1,unit_id:"pcs",unit_price:8,discount_amount:0}]}')"
CUSTOMER_SALE_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$CUSTOMER_SALE_OPERATION" --argjson payload "$CUSTOMER_SALE_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
CUSTOMER_SALE_RESULT="$(rpc_call "$SELLER_TOKEN" "process_sale_invoice" "$CUSTOMER_SALE_ARGS")"
[[ "$(jq -r '.success' <<<"$CUSTOMER_SALE_RESULT")" == "true" ]] || { echo "Unpaid customer sale failed: $CUSTOMER_SALE_RESULT" >&2; exit 1; }

CUSTOMER_PAYMENT_PAYLOAD="$(jq -nc --arg id "$CUSTOMER_PAYMENT_ID" --arg customer "$CUSTOMER_A" '{id:$id,customer_id:$customer,amount:3,payment_method:"CARD"}')"
CUSTOMER_PAYMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$CUSTOMER_PAYMENT_OPERATION" --argjson payload "$CUSTOMER_PAYMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
CUSTOMER_PAYMENT_RESULT="$(rpc_call "$SELLER_TOKEN" "process_customer_payment" "$CUSTOMER_PAYMENT_ARGS")"
[[ "$(jq -r '.success' <<<"$CUSTOMER_PAYMENT_RESULT")" == "true" ]] || { echo "Customer payment failed: $CUSTOMER_PAYMENT_RESULT" >&2; exit 1; }
CUSTOMER_PAYMENT_REPLAY="$(rpc_call "$SELLER_TOKEN" "process_customer_payment" "$CUSTOMER_PAYMENT_ARGS")"
[[ "$(jq -r '.replayed' <<<"$CUSTOMER_PAYMENT_REPLAY")" == "true" ]] || { echo "Customer payment replay was not idempotent: $CUSTOMER_PAYMENT_REPLAY" >&2; exit 1; }

SELLER_OWN_PAYMENT_PAYLOAD="$(jq -nc --arg id "$SELLER_OWN_PAYMENT_ID" --arg customer "$CUSTOMER_B" '{id:$id,customer_id:$customer,amount:3,payment_method:"CASH"}')"
SELLER_OWN_PAYMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$SELLER_OWN_PAYMENT_OPERATION" --argjson payload "$SELLER_OWN_PAYMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
SELLER_OWN_PAYMENT_RESULT="$(rpc_call "$SELLER_TOKEN" "process_customer_payment" "$SELLER_OWN_PAYMENT_ARGS")"
[[ "$(jq -r '.success' <<<"$SELLER_OWN_PAYMENT_RESULT")" == "true" ]] || { echo "Seller payment for own invoice failed: $SELLER_OWN_PAYMENT_RESULT" >&2; exit 1; }
if [[ "$(psql "$DB_URL" -Atqc "SELECT invoice_id::text FROM public.payment_allocations WHERE payment_id='$SELLER_OWN_PAYMENT_ID'::uuid")" != "a5000000-0000-4000-8000-000000000017" ]]; then
  echo "Seller payment was not allocated exclusively to the seller-owned invoice" >&2
  exit 1
fi

FOREIGN_ALLOCATION_PAYLOAD="$(jq -nc --arg id "a5000000-0000-4000-8000-000000000020" --arg customer "$CUSTOMER_B" '{id:$id,customer_id:$customer,amount:1,payment_method:"CASH",allocations:[{invoice_id:"a5000000-0000-4000-8000-000000000009",amount:1}]}')"
FOREIGN_ALLOCATION_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "a5000000-0000-4000-8000-000000000021" --argjson payload "$FOREIGN_ALLOCATION_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_error "seller allocating payment to another seller's invoice" "$SELLER_TOKEN" "process_customer_payment" "$FOREIGN_ALLOCATION_ARGS" "P0001"

echo "Verifying seller-specific customer payment, ledger and allocation visibility..."
SELLER_CUSTOMER_PAYMENTS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/customer_payments?select=id,created_by" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
OWNER_CUSTOMER_PAYMENTS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/customer_payments?select=id,created_by" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
SELLER_CUSTOMER_LEDGERS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/customer_ledgers?select=id,created_by" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
OWNER_CUSTOMER_LEDGERS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/customer_ledgers?select=id,created_by" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
SELLER_PAYMENT_ALLOCATIONS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/payment_allocations?select=payment_id,invoice_id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
OWNER_PAYMENT_ALLOCATIONS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/payment_allocations?select=payment_id,invoice_id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
[[ "$(jq 'length' <<<"${SELLER_CUSTOMER_PAYMENTS}")" -eq 3 && "$(jq -e --arg owner "a5000000-0000-4000-8000-000000000014" 'all(.[]; .id!=$owner)' <<<"${SELLER_CUSTOMER_PAYMENTS}")" == "true" ]] || { echo "Seller can see owner customer payments: ${SELLER_CUSTOMER_PAYMENTS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_CUSTOMER_PAYMENTS}")" -eq 4 ]] || { echo "Owner cannot see all customer payments: ${OWNER_CUSTOMER_PAYMENTS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_CUSTOMER_LEDGERS}")" -eq 6 && "$(jq -e --arg owner "a3000000-0000-4000-8000-000000000001" 'all(.[]; .created_by!=$owner)' <<<"${SELLER_CUSTOMER_LEDGERS}")" == "true" ]] || { echo "Seller can see owner customer ledger rows: ${SELLER_CUSTOMER_LEDGERS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_CUSTOMER_LEDGERS}")" -eq 7 ]] || { echo "Owner cannot see all customer ledger rows: ${OWNER_CUSTOMER_LEDGERS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_PAYMENT_ALLOCATIONS}")" -eq 3 && "$(jq -e --arg owner_invoice "a5000000-0000-4000-8000-000000000009" 'all(.[]; .invoice_id!=$owner_invoice)' <<<"${SELLER_PAYMENT_ALLOCATIONS}")" == "true" ]] || { echo "Seller can see a foreign payment allocation or cannot see own allocations: ${SELLER_PAYMENT_ALLOCATIONS}" >&2; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_PAYMENT_ALLOCATIONS}")" -eq 4 ]] || { echo "Owner cannot see all customer payment allocations: ${OWNER_PAYMENT_ALLOCATIONS}" >&2; exit 1; }

SUPPLIER_PAYMENT_PAYLOAD="$(jq -nc --arg id "$SUPPLIER_PAYMENT_ID" --arg supplier "$SUPPLIER_A" '{id:$id,supplier_id:$supplier,amount:5,payment_method:"BANK_TRANSFER"}')"
SUPPLIER_PAYMENT_ARGS="$(jq -nc --arg store "$STORE_A" --arg op "$SUPPLIER_PAYMENT_OPERATION" --argjson payload "$SUPPLIER_PAYMENT_PAYLOAD" '{p_store_id:$store,p_operation_id:$op,p_payload:$payload}')"
expect_rpc_denied "seller paying a supplier" "$SELLER_TOKEN" "process_supplier_payment" "$SUPPLIER_PAYMENT_ARGS"
SUPPLIER_PAYMENT_RESULT="$(rpc_call "$OWNER_TOKEN" "process_supplier_payment" "$SUPPLIER_PAYMENT_ARGS")"
[[ "$(jq -r '.success' <<<"$SUPPLIER_PAYMENT_RESULT")" == "true" ]] || { echo "Supplier payment failed: $SUPPLIER_PAYMENT_RESULT" >&2; exit 1; }
SUPPLIER_PAYMENT_REPLAY="$(rpc_call "$OWNER_TOKEN" "process_supplier_payment" "$SUPPLIER_PAYMENT_ARGS")"
[[ "$(jq -r '.replayed' <<<"$SUPPLIER_PAYMENT_REPLAY")" == "true" ]] || { echo "Supplier payment replay was not idempotent: $SUPPLIER_PAYMENT_REPLAY" >&2; exit 1; }

psql "$DB_URL" -v ON_ERROR_STOP=1 -v store_a="$STORE_A" -v product_a="$PRODUCT_A" -v purchase_id="$PURCHASE_ID" -v purchase_item_id="$PURCHASE_ITEM_ID" -v purchase_return_id="$PURCHASE_RETURN_ID" -v adjustment_id="$ADJUSTMENT_ID" -v sale_return_id="$SALE_RETURN_ID" -v purchase_amendment_id="$PURCHASE_AMENDMENT_ID" -v purchase_closure_id="$PURCHASE_CLOSURE_ID" -v customer_a="$CUSTOMER_A" -v customer_sale_id="$CUSTOMER_SALE_ID" -v customer_payment_id="$CUSTOMER_PAYMENT_ID" -v supplier_payment_id="$SUPPLIER_PAYMENT_ID" <<'SQL'
SELECT set_config('atack.test.store_a', :'store_a', false);
SELECT set_config('atack.test.product_a', :'product_a', false);
SELECT set_config('atack.test.purchase_id', :'purchase_id', false);
SELECT set_config('atack.test.purchase_item_id', :'purchase_item_id', false);
SELECT set_config('atack.test.purchase_return_id', :'purchase_return_id', false);
SELECT set_config('atack.test.adjustment_id', :'adjustment_id', false);
SELECT set_config('atack.test.sale_return_id', :'sale_return_id', false);
SELECT set_config('atack.test.purchase_amendment_id', :'purchase_amendment_id', false);
SELECT set_config('atack.test.purchase_closure_id', :'purchase_closure_id', false);
SELECT set_config('atack.test.customer_a', :'customer_a', false);
SELECT set_config('atack.test.customer_sale_id', :'customer_sale_id', false);
SELECT set_config('atack.test.customer_payment_id', :'customer_payment_id', false);
SELECT set_config('atack.test.supplier_payment_id', :'supplier_payment_id', false);
DO $assert_business$
DECLARE
  v_stock NUMERIC(18,4);
  v_received NUMERIC(18,4);
  v_returned NUMERIC(18,4);
  v_supplier_payments INTEGER;
  v_customer_debt NUMERIC(18,4);
  v_customer_credit NUMERIC(18,4);
  v_supplier_debt NUMERIC(18,4);
  v_invoice_remaining NUMERIC(18,4);
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
  IF v_stock<>12 THEN RAISE EXCEPTION 'Unexpected final stock after sale, receipt, returns and adjustment: %',v_stock; END IF;
  SELECT count(*) INTO v_supplier_payments FROM public.supplier_payments WHERE supplier_id=(SELECT supplier_id FROM public.purchases WHERE id=current_setting('atack.test.purchase_id')::uuid);
  IF v_supplier_payments<>1 THEN RAISE EXCEPTION 'Expected exactly one explicit supplier payment; purchase return must not create an automatic payout'; END IF;
  SELECT current_debt INTO v_supplier_debt FROM public.suppliers WHERE id=(SELECT supplier_id FROM public.purchases WHERE id=current_setting('atack.test.purchase_id')::uuid);
  IF v_supplier_debt<>22 THEN RAISE EXCEPTION 'Supplier debt after return, amendment, closure and payment mismatch: %',v_supplier_debt; END IF;
  SELECT current_debt,credit_balance INTO v_customer_debt,v_customer_credit FROM public.customers WHERE id=current_setting('atack.test.customer_a')::uuid;
  IF v_customer_credit<>5 OR (SELECT customer_credit_created FROM public.sales_returns WHERE id=current_setting('atack.test.sale_return_id')::uuid)<>5 THEN
    RAISE EXCEPTION 'Paid sale return did not create the approved customer credit: balance %, return credit %',v_customer_credit,(SELECT customer_credit_created FROM public.sales_returns WHERE id=current_setting('atack.test.sale_return_id')::uuid);
  END IF;
  SELECT remaining_amount INTO v_invoice_remaining FROM public.invoices WHERE id=current_setting('atack.test.customer_sale_id')::uuid;
  IF v_customer_debt<>5 OR v_invoice_remaining<>5 THEN RAISE EXCEPTION 'Customer payment allocation mismatch: debt %, invoice remaining %',v_customer_debt,v_invoice_remaining; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.purchase_amendments WHERE id=current_setting('atack.test.purchase_amendment_id')::uuid AND store_id=current_setting('atack.test.store_a')::uuid) THEN RAISE EXCEPTION 'Purchase amendment record missing'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.purchase_closures WHERE id=current_setting('atack.test.purchase_closure_id')::uuid AND store_id=current_setting('atack.test.store_a')::uuid) THEN RAISE EXCEPTION 'Purchase closure record missing'; END IF;
  IF (SELECT closed_quantity FROM public.purchase_items WHERE id=current_setting('atack.test.purchase_item_id')::uuid)<>2
     OR (SELECT receiving_status FROM public.purchases WHERE id=current_setting('atack.test.purchase_id')::uuid)<>'CLOSED_PARTIAL' THEN
    RAISE EXCEPTION 'Purchase close-remaining status/quantity mismatch';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.journal_entries WHERE store_id=current_setting('atack.test.store_a')::uuid AND source_type='PAYMENT' AND source_id=current_setting('atack.test.customer_payment_id')::uuid)
     OR NOT EXISTS(SELECT 1 FROM public.journal_entries WHERE store_id=current_setting('atack.test.store_a')::uuid AND source_type='PAYMENT' AND source_id=current_setting('atack.test.supplier_payment_id')::uuid) THEN
    RAISE EXCEPTION 'Customer/supplier payment journal entries are missing';
  END IF;
  SELECT COALESCE(SUM(total_debit),0),COALESCE(SUM(total_credit),0) INTO v_debit,v_credit FROM public.v_trial_balance WHERE store_id=current_setting('atack.test.store_a')::uuid;
  IF round(v_debit,4)<>round(v_credit,4) THEN RAISE EXCEPTION 'Trial balance unbalanced after RPC operations: debit %, credit %',v_debit,v_credit; END IF;
END
$assert_business$;
SQL

echo "Verifying owner direct writes to accounting tables are denied..."
WRITE_STATUS="$(curl --silent --show-error -o /tmp/journal-write-response.json -w '%{http_code}' \
  -X POST "${API_URL}/rest/v1/journal_entries" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  --data "$(jq -nc --arg store_id "${STORE_A}" '{store_id:$store_id}')")"
if [[ "${WRITE_STATUS}" != "403" ]] || [[ "$(jq -r '.code // empty' /tmp/journal-write-response.json)" != "42501" ]]; then
  echo "Expected PostgreSQL privilege denial (HTTP 403 / SQLSTATE 42501) for direct journal INSERT, got HTTP ${WRITE_STATUS}" >&2
  cat /tmp/journal-write-response.json >&2
  exit 1
fi

echo "Verifying real JWT owner/seller read boundaries through PostgREST..."
SELLER_INVOICES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/invoices?select=id,created_by" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
SELLER_PURCHASES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/purchases?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
SELLER_JOURNALS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/journal_entries?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
SELLER_PROFILES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/users?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SELLER_TOKEN}")"
[[ "$(jq 'length' <<<"${SELLER_INVOICES}")" -eq 2 ]] || { echo "Seller must see exactly their two sales invoices; received: ${SELLER_INVOICES}"; exit 1; }
[[ "$(jq -r --arg id "a5000000-0000-4000-8000-000000000009" 'any(.[]; .id==$id)' <<<"${SELLER_INVOICES}")" == "false" ]] || { echo "Seller can read the owner's private invoice"; exit 1; }
[[ "$(jq -e --arg id "${SALE_ID}" --arg seller "${SELLER_USER}" 'any(.[]; .id==$id and .created_by==$seller)' <<<"${SELLER_INVOICES}")" == "true" ]] || { echo "Seller sale invoice is not attributed to the authenticated seller"; exit 1; }
[[ "$(jq -e --arg id "${CUSTOMER_SALE_ID}" --arg seller "${SELLER_USER}" 'any(.[]; .id==$id and .created_by==$seller)' <<<"${SELLER_INVOICES}")" == "true" ]] || { echo "Seller customer invoice is not attributed to the authenticated seller"; exit 1; }
[[ "$(jq -e --arg seller "${SELLER_USER}" 'all(.[]; .created_by==$seller)' <<<"${SELLER_INVOICES}")" == "true" ]] || { echo "Seller can read an invoice owned by another user"; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_PURCHASES}")" -eq 0 ]] || { echo "Seller read purchases without purchases.read"; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_JOURNALS}")" -eq 0 ]] || { echo "Seller read financial journals without reports.financial"; exit 1; }
[[ "$(jq 'length' <<<"${SELLER_PROFILES}")" -eq 1 && "$(jq -r '.[0].id' <<<"${SELLER_PROFILES}")" == "${SELLER_USER}" ]] || { echo "Seller profile read is not restricted to the caller's own profile"; exit 1; }


OWNER_INVOICES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/invoices?select=id,created_by" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
OWNER_PURCHASES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/purchases?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
OWNER_JOURNALS="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/journal_entries?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
OWNER_STOCK="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/stock?select=product_id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
OWNER_CHART="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/chart_of_accounts?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
OWNER_LEDGER="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/general_ledger?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
OWNER_PROFILES="$(curl --fail-with-body --silent --show-error "${API_URL}/rest/v1/users?select=id" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${OWNER_TOKEN}")"
[[ "$(jq 'length' <<<"${OWNER_INVOICES}")" -gt 0 && "$(jq 'length' <<<"${OWNER_PURCHASES}")" -gt 0 ]] || { echo "Owner cannot read store sales and purchases"; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_INVOICES}")" -ge 2 ]] || { echo "Owner cannot see all store invoices"; exit 1; }
[[ "$(jq -e --arg id "${SALE_ID}" --arg seller "${SELLER_USER}" 'any(.[]; .id==$id and .created_by==$seller)' <<<"${OWNER_INVOICES}")" == "true" ]] || { echo "Owner cannot see the seller-attributed invoice"; exit 1; }
[[ "$(jq -e --arg id "a5000000-0000-4000-8000-000000000009" 'any(.[]; .id==$id)' <<<"${OWNER_INVOICES}")" == "true" ]] || { echo "Owner cannot see their own invoice"; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_JOURNALS}")" -gt 0 && "$(jq 'length' <<<"${OWNER_CHART}")" -gt 0 && "$(jq 'length' <<<"${OWNER_LEDGER}")" -gt 0 ]] || { echo "Owner cannot read complete store accounting records"; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_STOCK}")" -gt 0 ]] || { echo "Owner cannot read store inventory"; exit 1; }
[[ "$(jq 'length' <<<"${OWNER_PROFILES}")" -eq 2 ]] || { echo "Owner cannot see all users in own store, or cross-store user isolation failed"; exit 1; }

echo "PASS: real Supabase Auth owner/seller model, store isolation, owner role management, Push/Outbox RPCs, business RPC permissions, owner/seller read boundaries and protected accounting writes"
