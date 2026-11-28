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
   WHERE product_id='50000000-0000-4000-8000-000000000009' AND location_id=(SELECT id FROM public.locations WHERE store_id='10000000-0000-4000-8000-000000000001' AND code='main');
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
   WHERE product_id='50000000-0000-4000-8000-000000000010' AND location_id=(SELECT id FROM public.locations WHERE store_id='10000000-0000-4000-8000-000000000001' AND code='main');
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


# Two concurrent payments against one customer's outstanding invoice must
# serialize without losing debt updates or duplicating allocations/journals.
"${PSQL[@]}" <<'SQL'
INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
VALUES ('90000000-0000-4000-8000-000000000010',
        '10000000-0000-4000-8000-000000000001',
        'CONC-PAY-010','Concurrent Customer Payment Test',0,0,TRUE);
INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
VALUES ('50000000-0000-4000-8000-000000000011',
        '10000000-0000-4000-8000-000000000001',
        'Concurrent Customer Payment Product','pcs',10,TRUE);
INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
VALUES ('50000000-0000-4000-8000-000000000011','main',5,0);
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',false);
SELECT public.process_sale_invoice(
 '10000000-0000-4000-8000-000000000001',
 '60000000-0000-4000-8000-000000000043',
 jsonb_build_object(
   'id','80000000-0000-4000-8000-000000000043',
   'invoice_number','PH2-CONC-PAY-INV',
   'customer_id','90000000-0000-4000-8000-000000000010',
   'paid_amount',0,
   'items',jsonb_build_array(jsonb_build_object(
     'product_id','50000000-0000-4000-8000-000000000011',
     'quantity',1,'unit_id','pcs','unit_price',100
   ))
 )
);
SQL

run_customer_payment() {
  local op_id="$1"
  local payment_id="$2"
  local amount="$3"
  local output="$4"
  if "${PSQL[@]}" >"$output.log" 2>&1 <<SQL
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',false);
SELECT pg_sleep(0.2);
SELECT public.process_customer_payment(
 '10000000-0000-4000-8000-000000000001',
 '$op_id',
 jsonb_build_object(
   'id','$payment_id',
   'customer_id','90000000-0000-4000-8000-000000000010',
   'amount',$amount,
   'payment_method','CASH'
 )
);
SQL
  then
    printf 'success' >"$output.status"
  else
    printf 'rejected' >"$output.status"
  fi
}

run_customer_payment \
  '60000000-0000-4000-8000-000000000044' \
  '81000000-0000-4000-8000-000000000041' \
  '30' "$tmpdir/payment-a" &
payment_a=$!

run_customer_payment \
  '60000000-0000-4000-8000-000000000045' \
  '81000000-0000-4000-8000-000000000042' \
  '40' "$tmpdir/payment-b" &
payment_b=$!

wait "$payment_a"
wait "$payment_b"

if [[ "$(cat "$tmpdir/payment-a.status")" != "success" || "$(cat "$tmpdir/payment-b.status")" != "success" ]]; then
  echo "Both concurrent customer payments should have succeeded."
  cat "$tmpdir/payment-a.log" "$tmpdir/payment-b.log"
  exit 1
fi

"${PSQL[@]}" <<'SQL'
DO $concurrent_payment_check$
DECLARE
  v_debt NUMERIC(18,4);
  v_paid NUMERIC(18,4);
  v_remaining NUMERIC(18,4);
  v_allocated NUMERIC(18,4);
  v_payment_count INTEGER;
  v_journal_count INTEGER;
  v_processed_count INTEGER;
  v_ledger_net NUMERIC(18,4);
BEGIN
  SELECT current_debt INTO v_debt FROM public.customers
   WHERE id='90000000-0000-4000-8000-000000000010';
  SELECT paid_amount,remaining_amount INTO v_paid,v_remaining FROM public.invoices
   WHERE id='80000000-0000-4000-8000-000000000043';
  SELECT COALESCE(SUM(allocated_amount),0) INTO v_allocated FROM public.payment_allocations
   WHERE payment_id IN ('81000000-0000-4000-8000-000000000041',
                        '81000000-0000-4000-8000-000000000042');
  SELECT count(*) INTO v_payment_count FROM public.customer_payments
   WHERE id IN ('81000000-0000-4000-8000-000000000041',
                '81000000-0000-4000-8000-000000000042');
  SELECT count(*) INTO v_journal_count FROM public.journal_entries
   WHERE source_type='PAYMENT'
     AND source_id IN ('81000000-0000-4000-8000-000000000041',
                       '81000000-0000-4000-8000-000000000042');
  SELECT count(*) INTO v_processed_count FROM public.processed_operations
   WHERE operation_id IN ('60000000-0000-4000-8000-000000000044',
                          '60000000-0000-4000-8000-000000000045');
  SELECT COALESCE(SUM(amount),0) INTO v_ledger_net FROM public.customer_ledgers
   WHERE customer_id='90000000-0000-4000-8000-000000000010';
  IF v_debt IS DISTINCT FROM 30 OR v_paid IS DISTINCT FROM 70
     OR v_remaining IS DISTINCT FROM 30 OR v_allocated IS DISTINCT FROM 70
     OR v_payment_count<>2 OR v_journal_count<>2 OR v_processed_count<>2
     OR v_ledger_net IS DISTINCT FROM 30 THEN
    RAISE EXCEPTION 'Concurrent payment invariant failed: debt %, invoice paid %, remaining %, allocations %, payments %, journals %, processed %, ledger net %',
      v_debt,v_paid,v_remaining,v_allocated,v_payment_count,v_journal_count,v_processed_count,v_ledger_net;
  END IF;
  RAISE NOTICE 'PASS: concurrent customer payments serialize; debt, invoice allocations, ledger and journals reconcile';
END
$concurrent_payment_check$;
SQL
