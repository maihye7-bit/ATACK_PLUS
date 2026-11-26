#!/usr/bin/env bash
set -euo pipefail

: "${PGPASSWORD:?PGPASSWORD must be set}"
PSQL=(psql -h localhost -U postgres -d atack_plus_test -v ON_ERROR_STOP=1)

# Two independent purchase transactions deliberately contend for the same
# product row. The RPC must serialize the cost/stock calculation.
"${PSQL[@]}" <<'SQL'
INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
VALUES ('50000000-0000-4000-8000-000000000009',
        '10000000-0000-4000-8000-000000000001',
        'Concurrent Weighted Cost Test','pcs',0,TRUE);
SQL

(
  "${PSQL[@]}" <<'SQL'
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',false);
SELECT public.process_purchase(
 '10000000-0000-4000-8000-000000000001',
 '60000000-0000-4000-8000-000000000031',
 '{"id":"70000000-0000-4000-8000-000000000031","purchase_number":"PH2-CONCURRENT-001","supplier_id":"40000000-0000-4000-8000-000000000001","paid_amount":0,"items":[{"product_id":"50000000-0000-4000-8000-000000000009","quantity":10,"unit_id":"pcs","unit_price":10,"cost_per_unit":10}]}'::jsonb
);
SQL
) &
pid1=$!

(
  "${PSQL[@]}" <<'SQL'
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',false);
SELECT public.process_purchase(
 '10000000-0000-4000-8000-000000000001',
 '60000000-0000-4000-8000-000000000032',
 '{"id":"70000000-0000-4000-8000-000000000032","purchase_number":"PH2-CONCURRENT-002","supplier_id":"40000000-0000-4000-8000-000000000001","paid_amount":0,"items":[{"product_id":"50000000-0000-4000-8000-000000000009","quantity":10,"unit_id":"pcs","unit_price":20,"cost_per_unit":20}]}'::jsonb
);
SQL
) &
pid2=$!

wait "$pid1"
wait "$pid2"

"${PSQL[@]}" <<'SQL'
DO $concurrency_check$
DECLARE
  v_stock NUMERIC(18,4);
  v_cost NUMERIC(18,4);
  v_purchases INTEGER;
BEGIN
  SELECT quantity INTO v_stock FROM public.stock
   WHERE product_id='50000000-0000-4000-8000-000000000009' AND location_id='main';
  SELECT cost_price INTO v_cost FROM public.products
   WHERE id='50000000-0000-4000-8000-000000000009';
  SELECT count(*) INTO v_purchases FROM public.purchases
   WHERE id IN ('70000000-0000-4000-8000-000000000031',
                '70000000-0000-4000-8000-000000000032');
  IF v_stock IS DISTINCT FROM 20 OR v_cost IS DISTINCT FROM 15 OR v_purchases<>2 THEN
    RAISE EXCEPTION 'Concurrent purchase lost an update: stock %, weighted cost %, purchases %',
      v_stock,v_cost,v_purchases;
  END IF;
  RAISE NOTICE 'PASS: concurrent purchase serialization, stock quantity and weighted average cost';
END
$concurrency_check$;
SQL


# Two concurrent sale transactions contend for the final available unit.
# Exactly one sale may commit; the rejected transaction must leave no invoice,
# stock movement, journal entry, or processed-operation residue.
"${PSQL[@]}" <<'SQL'
INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
VALUES ('50000000-0000-4000-8000-000000000010',
        '10000000-0000-4000-8000-000000000001',
        'Concurrent Last-Unit Sale Test','pcs',10,TRUE);
INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
VALUES ('50000000-0000-4000-8000-000000000010','main',1,0);
SQL

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_last_unit_sale() {
  local op_id="$1"
  local invoice_id="$2"
  local invoice_number="$3"
  local output="$4"
  if "${PSQL[@]}" >"$output.log" 2>&1 <<SQL
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',false);
SELECT public.process_sale_invoice(
 '10000000-0000-4000-8000-000000000001',
 '$op_id',
 jsonb_build_object(
   'id','$invoice_id',
   'invoice_number','$invoice_number',
   'paid_amount',100,
   'payment_method','CASH',
   'items',jsonb_build_array(jsonb_build_object(
     'product_id','50000000-0000-4000-8000-000000000010',
     'quantity',1,'unit_id','pcs','unit_price',100
   ))
 )
);
SQL
  then
    printf 'success' >"$output.status"
  else
    printf 'rejected' >"$output.status"
  fi
}

run_last_unit_sale \
  '60000000-0000-4000-8000-000000000041' \
  '80000000-0000-4000-8000-000000000041' \
  'PH2-LAST-UNIT-A' "$tmpdir/a" &
sale_a=$!

run_last_unit_sale \
  '60000000-0000-4000-8000-000000000042' \
  '80000000-0000-4000-8000-000000000042' \
  'PH2-LAST-UNIT-B' "$tmpdir/b" &
sale_b=$!

wait "$sale_a"
wait "$sale_b"

if [[ "$(cat "$tmpdir/a.status")" == "success" && "$(cat "$tmpdir/b.status")" == "rejected" ]]; then
  :
elif [[ "$(cat "$tmpdir/a.status")" == "rejected" && "$(cat "$tmpdir/b.status")" == "success" ]]; then
  :
else
  echo "Expected exactly one successful last-unit sale and one rejected sale."
  cat "$tmpdir/a.log" "$tmpdir/b.log"
  exit 1
fi

"${PSQL[@]}" <<'SQL'
DO $last_unit_sale_check$
DECLARE
  v_stock NUMERIC(18,4);
  v_invoices INTEGER;
  v_movements INTEGER;
  v_journals INTEGER;
  v_processed INTEGER;
BEGIN
  SELECT quantity INTO v_stock FROM public.stock
   WHERE product_id='50000000-0000-4000-8000-000000000010' AND location_id='main';
  SELECT count(*) INTO v_invoices FROM public.invoices
   WHERE id IN ('80000000-0000-4000-8000-000000000041',
                '80000000-0000-4000-8000-000000000042');
  SELECT count(*) INTO v_movements FROM public.stock_movements
   WHERE reference_id IN ('80000000-0000-4000-8000-000000000041',
                           '80000000-0000-4000-8000-000000000042')
     AND reference_type='invoice' AND type='OUT';
  SELECT count(*) INTO v_journals FROM public.journal_entries
   WHERE source_type='SALE'
     AND source_id IN ('80000000-0000-4000-8000-000000000041',
                       '80000000-0000-4000-8000-000000000042');
  SELECT count(*) INTO v_processed FROM public.processed_operations
   WHERE operation_id IN ('60000000-0000-4000-8000-000000000041',
                          '60000000-0000-4000-8000-000000000042');
  IF v_stock IS DISTINCT FROM 0 OR v_invoices<>1 OR v_movements<>1
     OR v_journals<>1 OR v_processed<>1 THEN
    RAISE EXCEPTION 'Last-unit sale invariant failed: stock %, invoices %, movements %, journals %, processed %',
      v_stock,v_invoices,v_movements,v_journals,v_processed;
  END IF;
  RAISE NOTICE 'PASS: concurrent last-unit sales serialize; exactly one complete sale commits and the rejected sale leaves no residue';
END
$last_unit_sale_check$;
SQL
