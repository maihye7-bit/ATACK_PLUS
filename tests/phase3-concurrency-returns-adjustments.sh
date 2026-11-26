#!/usr/bin/env bash
set -euo pipefail

: "${PGPASSWORD:?PGPASSWORD must be set}"
PSQL=(psql -h localhost -U postgres -d atack_plus_test -v ON_ERROR_STOP=1)
STORE='10000000-0000-4000-8000-000000000001'
AUTH='20000000-0000-4000-8000-000000000001'
CUSTOMER='90000000-0000-4000-8000-000000000012'
RETURN_PRODUCT='50000000-0000-4000-8000-000000000012'

# Two different invoices share one customer. Hold the store cursor mutex while
# both RPCs pass through the accounting wrapper and snapshot-free path into the
# operation claim. This makes the old stale-balance race reproducible: both
# transactions reach the mutex before either can mutate the customer.
"${PSQL[@]}" <<'SQL'
INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
VALUES ('90000000-0000-4000-8000-000000000012',
        '10000000-0000-4000-8000-000000000001',
        'CONC-RET-012','Concurrent Returns Customer',0,0,TRUE);
INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
VALUES ('50000000-0000-4000-8000-000000000012',
        '10000000-0000-4000-8000-000000000001',
        'Concurrent Return Product','pcs',10,TRUE);
INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
VALUES ('50000000-0000-4000-8000-000000000012','main',10,0);
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',false);
SELECT public.process_sale_invoice(
 '10000000-0000-4000-8000-000000000001',
 '60000000-0000-4000-8000-000000000051',
 jsonb_build_object('id','80000000-0000-4000-8000-000000000051',
   'invoice_number','PH3-CONC-RET-A','customer_id','90000000-0000-4000-8000-000000000012',
   'paid_amount',0,'items',jsonb_build_array(jsonb_build_object(
     'product_id','50000000-0000-4000-8000-000000000012',
     'quantity',1,'unit_id','pcs','unit_price',100))));
SELECT public.process_sale_invoice(
 '10000000-0000-4000-8000-000000000001',
 '60000000-0000-4000-8000-000000000052',
 jsonb_build_object('id','80000000-0000-4000-8000-000000000052',
   'invoice_number','PH3-CONC-RET-B','customer_id','90000000-0000-4000-8000-000000000012',
   'paid_amount',0,'items',jsonb_build_array(jsonb_build_object(
     'product_id','50000000-0000-4000-8000-000000000012',
     'quantity',1,'unit_id','pcs','unit_price',100))));
SQL

item_a="$("${PSQL[@]}" -Atc "SELECT id FROM public.invoice_items WHERE invoice_id='80000000-0000-4000-8000-000000000051'")"
item_b="$("${PSQL[@]}" -Atc "SELECT id FROM public.invoice_items WHERE invoice_id='80000000-0000-4000-8000-000000000052'")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Hold the per-store mutex until both independent returns have reached it.
(
  "${PSQL[@]}" <<'SQL'
SET application_name='atack-return-mutex-holder';
BEGIN;
SELECT 1 FROM public.store_sync_counters
 WHERE store_id='10000000-0000-4000-8000-000000000001' FOR UPDATE;
SELECT pg_sleep(12);
COMMIT;
SQL
) >"$tmpdir/holder.log" 2>&1 &
holder=$!

for _ in $(seq 1 50); do
  active="$("${PSQL[@]}" -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name='atack-return-mutex-holder' AND state='active'")"
  [[ "$active" == "1" ]] && break
  sleep 0.1
done
if [[ "$active" != "1" ]]; then
  echo "Could not establish the return concurrency mutex holder."
  cat "$tmpdir/holder.log"
  exit 1
fi

run_sale_return() {
  local op="$1" id="$2" invoice="$3" item="$4" number="$5" out="$6"
  if "${PSQL[@]}" >"$out.log" 2>&1 <<SQL
SELECT set_config('request.jwt.claim.sub','$AUTH',false);
SELECT public.process_sale_return(
 '$STORE','$op',
 jsonb_build_object('id','$id','invoice_id','$invoice','return_number','$number',
   'refund_method','CREDIT','return_condition','GOOD',
   'items',jsonb_build_array(jsonb_build_object(
     'invoice_item_id','$item','product_id','$RETURN_PRODUCT',
     'quantity',1,'unit_id','pcs'))));
SQL
  then printf success >"$out.status"; else printf rejected >"$out.status"; fi
}

run_sale_return '60000000-0000-4000-8000-000000000053' \
 '91000000-0000-4000-8000-000000000051' \
 '80000000-0000-4000-8000-000000000051' "$item_a" 'PH3-RET-A' "$tmpdir/return-a" &
ret_a=$!
run_sale_return '60000000-0000-4000-8000-000000000054' \
 '91000000-0000-4000-8000-000000000052' \
 '80000000-0000-4000-8000-000000000052' "$item_b" 'PH3-RET-B' "$tmpdir/return-b" &
ret_b=$!

waiters=0
for _ in $(seq 1 80); do
  waiters="$("${PSQL[@]}" -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query ILIKE '%process_sale_return%'")"
  [[ "$waiters" -ge 2 ]] && break
  sleep 0.1
done
if [[ "$waiters" -lt 2 ]]; then
  echo "Both sale-return RPCs did not reach the held store mutex concurrently."
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$ret_a" || true
  wait "$ret_b" || true
  cat "$tmpdir/return-a.log" "$tmpdir/return-b.log"
  exit 1
fi

wait "$ret_a"
wait "$ret_b"
wait "$holder"

if [[ "$(cat "$tmpdir/return-a.status")" != success || "$(cat "$tmpdir/return-b.status")" != success ]]; then
  echo "Both independent sale returns should succeed."
  cat "$tmpdir/return-a.log" "$tmpdir/return-b.log"
  exit 1
fi

"${PSQL[@]}" <<'SQL'
DO $concurrent_returns$
DECLARE
  v_debt NUMERIC(18,4);
  v_credit NUMERIC(18,4);
  v_stock NUMERIC(18,4);
  v_returns INTEGER;
  v_return_movements INTEGER;
  v_ledgers INTEGER;
  v_journals INTEGER;
  v_applied NUMERIC(18,4);
  v_credit_created NUMERIC(18,4);
BEGIN
  SELECT current_debt,credit_balance INTO v_debt,v_credit
    FROM public.customers WHERE id='90000000-0000-4000-8000-000000000012';
  SELECT quantity INTO v_stock FROM public.stock
    WHERE product_id='50000000-0000-4000-8000-000000000012' AND location_id='main';
  SELECT count(*),COALESCE(sum(applied_to_debt),0),COALESCE(sum(customer_credit_created),0)
    INTO v_returns,v_applied,v_credit_created FROM public.sales_returns
   WHERE id IN ('91000000-0000-4000-8000-000000000051',
                '91000000-0000-4000-8000-000000000052');
  SELECT count(*) INTO v_return_movements FROM public.stock_movements
   WHERE reference_id IN ('91000000-0000-4000-8000-000000000051',
                          '91000000-0000-4000-8000-000000000052')
     AND reference_type='return' AND type='RETURN_IN';
  SELECT count(*) INTO v_ledgers FROM public.customer_ledgers
   WHERE reference_id IN ('91000000-0000-4000-8000-000000000051',
                          '91000000-0000-4000-8000-000000000052') AND type='RETURN';
  SELECT count(*) INTO v_journals FROM public.journal_entries
   WHERE source_type='RETURN'
     AND source_id IN ('91000000-0000-4000-8000-000000000051',
                       '91000000-0000-4000-8000-000000000052')
     AND total_debit=total_credit;
  IF v_debt IS DISTINCT FROM 0 OR v_credit IS DISTINCT FROM 0
     OR v_stock IS DISTINCT FROM 10 OR v_returns<>2 OR v_applied<>200
     OR v_credit_created<>0 OR v_return_movements<>2 OR v_ledgers<>2 OR v_journals<>2 THEN
    RAISE EXCEPTION 'Concurrent sale-return reconciliation failed: debt %, credit %, stock %, returns %, applied %, credit-created %, movements %, ledgers %, balanced journals %',
      v_debt,v_credit,v_stock,v_returns,v_applied,v_credit_created,v_return_movements,v_ledgers,v_journals;
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.journal_entries je
    WHERE je.source_type='RETURN'
      AND je.source_id IN ('91000000-0000-4000-8000-000000000051',
                           '91000000-0000-4000-8000-000000000052')
      AND (je.total_debit<>(SELECT COALESCE(sum(amount),0) FROM public.general_ledger
                            WHERE journal_entry_id=je.id AND entry_type='DEBIT')
        OR je.total_credit<>(SELECT COALESCE(sum(amount),0) FROM public.general_ledger
                              WHERE journal_entry_id=je.id AND entry_type='CREDIT'))
  ) THEN RAISE EXCEPTION 'A concurrent return journal does not reconcile to its ledger lines'; END IF;
  RAISE NOTICE 'PASS: concurrent sale returns preserve customer debt, credit, stock, return ledgers and balanced journals';
END
$concurrent_returns$;
SQL

# Two stock adjustments contend on the same product. Both must commit without
# losing either quantity change, movement or balanced accounting journal.
"${PSQL[@]}" <<'SQL'
INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
VALUES ('50000000-0000-4000-8000-000000000013',
        '10000000-0000-4000-8000-000000000001',
        'Concurrent Stock Adjustment Product','pcs',10,TRUE);
INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
VALUES ('50000000-0000-4000-8000-000000000013','main',100,0);
SQL

run_adjustment() {
  local op="$1" id="$2" kind="$3" qty="$4" cost="$5" out="$6"
  if "${PSQL[@]}" >"$out.log" 2>&1 <<SQL
SELECT set_config('request.jwt.claim.sub','$AUTH',false);
SELECT public.process_stock_adjustment(
 '$STORE','$op',
 jsonb_build_object('id','$id','product_id','50000000-0000-4000-8000-000000000013',
   'adjustment_type','$kind','quantity',$qty,'unit_id','pcs',
   'cost_per_unit',$cost,'location_id','main','reason','Concurrent adjustment regression'));
SQL
  then printf success >"$out.status"; else printf rejected >"$out.status"; fi
}
run_adjustment '60000000-0000-4000-8000-000000000061' \
 '92000000-0000-4000-8000-000000000061' 'INCREASE' 10 20 "$tmpdir/adjust-increase" &
adj_a=$!
run_adjustment '60000000-0000-4000-8000-000000000062' \
 '92000000-0000-4000-8000-000000000062' 'DECREASE' 5 0 "$tmpdir/adjust-decrease" &
adj_b=$!
wait "$adj_a"
wait "$adj_b"

if [[ "$(cat "$tmpdir/adjust-increase.status")" != success || "$(cat "$tmpdir/adjust-decrease.status")" != success ]]; then
  echo "Both concurrent stock adjustments should succeed."
  cat "$tmpdir/adjust-increase.log" "$tmpdir/adjust-decrease.log"
  exit 1
fi

"${PSQL[@]}" <<'SQL'
DO $concurrent_adjustments$
DECLARE
  v_stock NUMERIC(18,4);
  v_adjustments INTEGER;
  v_movements INTEGER;
  v_journals INTEGER;
BEGIN
  SELECT quantity INTO v_stock FROM public.stock
   WHERE product_id='50000000-0000-4000-8000-000000000013' AND location_id='main';
  SELECT count(*) INTO v_adjustments FROM public.stock_adjustments
   WHERE id IN ('92000000-0000-4000-8000-000000000061',
                '92000000-0000-4000-8000-000000000062');
  SELECT count(*) INTO v_movements FROM public.stock_movements
   WHERE reference_id IN ('92000000-0000-4000-8000-000000000061',
                          '92000000-0000-4000-8000-000000000062')
     AND reference_type='adjustment' AND type='ADJUSTMENT';
  SELECT count(*) INTO v_journals FROM public.journal_entries
   WHERE source_type='ADJUSTMENT'
     AND source_id IN ('92000000-0000-4000-8000-000000000061',
                       '92000000-0000-4000-8000-000000000062')
     AND total_debit=total_credit;
  IF v_stock IS DISTINCT FROM 105 OR v_adjustments<>2 OR v_movements<>2 OR v_journals<>2 THEN
    RAISE EXCEPTION 'Concurrent stock adjustment invariant failed: stock %, adjustments %, movements %, balanced journals %',
      v_stock,v_adjustments,v_movements,v_journals;
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.journal_entries je
    WHERE je.source_type='ADJUSTMENT'
      AND je.source_id IN ('92000000-0000-4000-8000-000000000061',
                           '92000000-0000-4000-8000-000000000062')
      AND (je.total_debit<>(SELECT COALESCE(sum(amount),0) FROM public.general_ledger
                            WHERE journal_entry_id=je.id AND entry_type='DEBIT')
        OR je.total_credit<>(SELECT COALESCE(sum(amount),0) FROM public.general_ledger
                              WHERE journal_entry_id=je.id AND entry_type='CREDIT'))
  ) THEN RAISE EXCEPTION 'A concurrent adjustment journal does not reconcile to its ledger lines'; END IF;
  RAISE NOTICE 'PASS: concurrent stock adjustments preserve both quantity changes, movements and balanced journals';
END
$concurrent_adjustments$;
SQL
