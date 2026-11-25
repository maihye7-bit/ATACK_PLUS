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
