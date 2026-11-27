#!/usr/bin/env bash
set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-atack_plus_test}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
psql_cmd=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1)
store_a="91000000-0000-4000-8000-000000000001"
store_b="91000000-0000-4000-8000-000000000002"
user_a="92000000-0000-4000-8000-000000000001"
product_a="93000000-0000-4000-8000-000000000001"
product_b="93000000-0000-4000-8000-000000000002"
tmp_a="$(mktemp)"
tmp_b="$(mktemp)"
cleanup() {
  "${psql_cmd[@]}" >/dev/null 2>&1 <<SQL || true
DELETE FROM public.stock_movements WHERE product_id IN ('$product_a','$product_b');
DELETE FROM public.products WHERE id IN ('$product_a','$product_b');
DELETE FROM public.users WHERE id='$user_a';
DELETE FROM public.stores WHERE id IN ('$store_a','$store_b');
SQL
  rm -f "$tmp_a" "$tmp_b"
}
trap cleanup EXIT

"${psql_cmd[@]}" <<SQL
INSERT INTO public.stores(id,name) VALUES ('$store_a','Concurrency store A'),('$store_b','Concurrency store B');
INSERT INTO public.users(id,store_id,username,full_name)
VALUES ('$user_a','$store_a','same_store_concurrency_user','Same Store Concurrency User');
INSERT INTO public.products(id,store_id,name,primary_unit_id)
VALUES ('$product_a','$store_a','Parent-first concurrency product','pcs'),
       ('$product_b','$store_a','Child-first concurrency product','pcs');
SQL

# Case 1: parent ownership update wins the row lock. The later child insert
# must wait, observe the new owner and reject the stale user/store pairing.
"${psql_cmd[@]}" >"$tmp_a" 2>&1 <<SQL &
BEGIN;
UPDATE public.products SET store_id='$store_b' WHERE id='$product_a';
SELECT pg_sleep(1);
COMMIT;
SQL
pid_a=$!
sleep 0.2
set +e
"${psql_cmd[@]}" >"$tmp_b" 2>&1 <<SQL
INSERT INTO public.stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,user_id)
VALUES ('$product_a','IN',1,'pcs',1,1,'$user_a');
SQL
status=$?
set -e
wait "$pid_a"
if [[ $status -eq 0 ]] || ! grep -q "Cross-store or missing reference rejected" "$tmp_b"; then
  echo "FAIL: child insert was not rejected after concurrent parent ownership change"
  cat "$tmp_b"
  exit 1
fi

# Case 2: child insert wins and holds FOR SHARE. Parent update waits, then
# must be rejected because the committed movement now depends on that owner.
"${psql_cmd[@]}" >"$tmp_a" 2>&1 <<SQL &
BEGIN;
INSERT INTO public.stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,user_id)
VALUES ('$product_b','IN',1,'pcs',1,1,'$user_a');
SELECT pg_sleep(1);
COMMIT;
SQL
pid_a=$!
sleep 0.2
set +e
"${psql_cmd[@]}" >"$tmp_b" 2>&1 <<SQL
UPDATE public.products SET store_id='$store_b' WHERE id='$product_b';
SQL
status=$?
set -e
wait "$pid_a"
if [[ $status -eq 0 ]] || ! grep -q "Cannot change store_id for products" "$tmp_b"; then
  echo "FAIL: parent update was not rejected after concurrent child insert"
  cat "$tmp_b"
  exit 1
fi

echo "PASS: same-store parent/child concurrent ownership changes are serialized and rejected safely"
