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

echo "Creating a real user through the local Supabase Auth API..."
AUTH_RESPONSE="$(curl --fail-with-body --silent --show-error \
  -X POST "${API_URL}/auth/v1/signup" \
  -H "apikey: ${ANON_KEY}" \
  -H "Content-Type: application/json" \
  --data "$(jq -nc --arg email "$EMAIL" --arg password "$PASSWORD" '{email:$email,password:$password}')")"

ACCESS_TOKEN="$(jq -er '.access_token' <<<"$AUTH_RESPONSE")"
AUTH_USER_ID="$(jq -er '.user.id' <<<"$AUTH_RESPONSE")"

echo "Seeding two stores and linking the real Auth identity to store A..."
psql "$DB_URL" -v ON_ERROR_STOP=1 \
  -v auth_user_id="$AUTH_USER_ID" \
  -v store_a="$STORE_A" -v store_b="$STORE_B" \
  -v product_a="$PRODUCT_A" -v product_b="$PRODUCT_B" <<'SQL'
INSERT INTO public.stores(id,name) VALUES
  (:'store_a'::uuid,'Auth smoke store A'),
  (:'store_b'::uuid,'Auth smoke store B');

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES (:'user_a'::uuid,:'auth_user_id'::uuid,:'store_a'::uuid,'auth-smoke-owner','Auth Smoke Owner',TRUE);

INSERT INTO public.user_roles(user_id,role_id)
VALUES (:'user_a'::uuid,'admin');

INSERT INTO public.products(store_id,id,name,primary_unit_id)
VALUES
  (:'store_a'::uuid,:'product_a'::uuid,'Visible product','pcs'),
  (:'store_b'::uuid,:'product_b'::uuid,'Hidden product','pcs');

NOTIFY pgrst, 'reload schema';
SQL

echo "Waiting for PostgREST schema cache..."
sleep 3

echo "Verifying JWT-backed store isolation through PostgREST..."
PRODUCTS="$(curl --fail-with-body --silent --show-error \
  "${API_URL}/rest/v1/products?select=id&order=id.asc" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")"

ACTUAL_IDS="$(jq -r '.[].id' <<<"$PRODUCTS" | sort)"
EXPECTED_IDS="$(printf '%s\n' "$PRODUCT_A" | sort)"
if [[ "$ACTUAL_IDS" != "$EXPECTED_IDS" ]]; then
  echo "Expected only store A product $PRODUCT_A, got: $ACTUAL_IDS" >&2
  exit 1
fi

echo "Verifying authenticated direct writes to accounting tables are denied..."
WRITE_STATUS="$(curl --silent --show-error -o /tmp/journal-write-response.json -w '%{http_code}' \
  -X POST "${API_URL}/rest/v1/journal_entries" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  --data "$(jq -nc --arg store_id "$STORE_A" '{store_id:$store_id}')")"

if [[ "$WRITE_STATUS" =~ ^2 ]]; then
  echo "Unexpectedly allowed direct INSERT into journal_entries" >&2
  cat /tmp/journal-write-response.json >&2
  exit 1
fi

echo "PASS: real Supabase Auth signup/JWT, PostgREST identity, store isolation and protected accounting writes"
