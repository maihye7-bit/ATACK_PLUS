-- D3.2 / R3 regression: ACK must reference a page actually issued to this device.
-- Covers pagination beyond 500 and invisible-event checkpointing without metadata leakage.
BEGIN;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000031','20400000-0000-4000-8000-000000000031',
  '10000000-0000-4000-8000-000000000001','d32_r3_owner','D3.2 R3 Owner',TRUE),
 ('99100000-0000-4000-8000-000000000032','20400000-0000-4000-8000-000000000032',
  '10000000-0000-4000-8000-000000000001','d32_r3_seller_a','D3.2 R3 Seller A',TRUE),
 ('99100000-0000-4000-8000-000000000033','20400000-0000-4000-8000-000000000033',
  '10000000-0000-4000-8000-000000000001','d32_r3_seller_b','D3.2 R3 Seller B',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000031','owner'),
 ('99100000-0000-4000-8000-000000000032','cashier'),
 ('99100000-0000-4000-8000-000000000033','cashier')
ON CONFLICT (user_id,role_id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub','20400000-0000-4000-8000-000000000031',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_provision$
DECLARE a JSONB; b JSONB;
BEGIN
  a := public.register_sync_device(
    '99100000-0000-4000-8000-000000000032','D3.2 R3 Seller A Device','DESKTOP');
  b := public.register_sync_device(
    '99100000-0000-4000-8000-000000000033','D3.2 R3 Seller B Device','PHONE');
  PERFORM set_config('atack_test.d32_r3_device_a',a->>'device_id',TRUE);
  PERFORM set_config('atack_test.d32_r3_token_a',a->>'device_token',TRUE);
  PERFORM set_config('atack_test.d32_r3_device_b',b->>'device_id',TRUE);
  PERFORM set_config('atack_test.d32_r3_token_b',b->>'device_token',TRUE);
  RAISE NOTICE 'PASS: owner provisioned two independently bound test devices';
END
$owner_provision$;
RESET ROLE;

-- Start each test stream at its pre-fixture high-water mark, then append
-- deterministic counts of unique Change Log events.
DO $seed_pages$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r3_device_a');
  v_base BIGINT;
BEGIN
  SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
    FROM public.change_log WHERE store_id=v_store AND table_name='products';
  INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq,cursor_value)
  VALUES(v_store,v_device,'products',v_base,v_base::TEXT)
  ON CONFLICT (store_id,device_id,table_name) DO UPDATE
    SET last_pull_seq=EXCLUDED.last_pull_seq,cursor_value=EXCLUDED.cursor_value;

  SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
    FROM public.change_log WHERE store_id=v_store AND table_name='purchases';
  PERFORM set_config('atack_test.d32_r3_purchase_base',v_base::TEXT,TRUE);
  INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq,cursor_value)
  VALUES(v_store,v_device,'purchases',v_base,v_base::TEXT)
  ON CONFLICT (store_id,device_id,table_name) DO UPDATE
    SET last_pull_seq=EXCLUDED.last_pull_seq,cursor_value=EXCLUDED.cursor_value;

  PERFORM public.log_change(
      v_store, 'products', ids.id, 'UPDATE', NULL,
      jsonb_build_object('id',ids.id,'store_id',v_store,'name','D3.2 R3 visible fixture')
  )
  FROM (SELECT gen_random_uuid() AS id FROM generate_series(1,1201)) ids;

  PERFORM public.log_change(
      v_store, 'purchases', ids.id, 'INSERT', NULL,
      jsonb_build_object('id',ids.id,'store_id',v_store,'purchase_number','D3.2 R3 hidden fixture')
  )
  FROM (SELECT gen_random_uuid() AS id FROM generate_series(1,601)) ids;

END
$seed_pages$;

CREATE TEMP TABLE r3_seen_events(record_uuid UUID) ON COMMIT DROP;
GRANT SELECT, INSERT ON r3_seen_events TO authenticated;

SELECT set_config('request.jwt.claim.sub','20400000-0000-4000-8000-000000000032',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_page_delivery$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r3_device_a');
  v_token TEXT := current_setting('atack_test.d32_r3_token_a');
  v_page JSONB;
  v_retry JSONB;
  v_delivery UUID;
  v_error TEXT;
  v_denied BOOLEAN;
  v_distinct INTEGER;
  v_expected INTEGER;
  v_cursor BIGINT;
  v_page_no INTEGER;
BEGIN
  IF NOT has_function_privilege(current_user,
      'public.get_unsynced_records_page(uuid,text,text,text)','EXECUTE')
     OR NOT has_function_privilege(current_user,
      'public.acknowledge_sync_cursor(uuid,text,text,uuid,text)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint,text)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.acknowledge_sync_cursor(uuid,text,text,bigint,text)','EXECUTE')
     OR has_table_privilege(current_user,'public.sync_delivery_pages','SELECT') THEN
    RAISE EXCEPTION 'Delivery API grants or private ledger ACL are incorrect';
  END IF;

  -- Page 1: exactly 500 visible events and a server-issued delivery ID.
  v_page := public.get_unsynced_records_page(v_store,v_device,'products',v_token);
  IF (v_page->>'event_count')::INTEGER <> 500
     OR (v_page->>'has_more')::BOOLEAN IS NOT TRUE
     OR jsonb_array_length(v_page->'events') <> 500
     OR v_page->>'delivery_id' IS NULL THEN
    RAISE EXCEPTION 'First 500-event page contract is invalid: %',v_page;
  END IF;
  v_delivery := (v_page->>'delivery_id')::UUID;
  INSERT INTO pg_temp.r3_seen_events(record_uuid)
  SELECT (e->>'record_uuid')::UUID FROM jsonb_array_elements(v_page->'events') e;

  -- Retrying the same unacknowledged page returns the same delivery identity/hash.
  v_retry := public.get_unsynced_records_page(v_store,v_device,'products',v_token);
  IF v_retry->>'delivery_id' IS DISTINCT FROM v_page->>'delivery_id'
     OR v_retry->>'page_hash' IS DISTINCT FROM v_page->>'page_hash' THEN
    RAISE EXCEPTION 'Pull retry did not return the same delivery page';
  END IF;

  -- A cursor/event without a server-issued delivery ID cannot be acknowledged.
  v_denied := FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,v_device,'products',gen_random_uuid(),v_token);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Delivery page is not registered%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Undelivered page ID was accepted'; END IF;
  PERFORM set_config('atack_test.d32_r3_page1',v_delivery::TEXT,TRUE);
  RAISE NOTICE 'PASS: first page is recorded, replay-stable and cannot be ACKed with a fabricated ID';
END
$seller_page_delivery$;
RESET ROLE;

-- A different seller/device cannot acknowledge Seller A's page.
SELECT set_config('request.jwt.claim.sub','20400000-0000-4000-8000-000000000033',TRUE);
SET LOCAL ROLE authenticated;
DO $cross_device_ack$
DECLARE denied BOOLEAN := FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM public.acknowledge_sync_cursor(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r3_device_b'),
      'products',
      current_setting('atack_test.d32_r3_page1')::UUID,
      current_setting('atack_test.d32_r3_token_b')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Delivery page is not registered%' THEN RAISE; END IF;
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Seller B acknowledged Seller A delivery'; END IF;
  RAISE NOTICE 'PASS: delivery ACK is bound to the issuing device';
END
$cross_device_ack$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20400000-0000-4000-8000-000000000032',TRUE);
SET LOCAL ROLE authenticated;
DO $sequential_pages$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r3_device_a');
  v_token TEXT := current_setting('atack_test.d32_r3_token_a');
  v_delivery UUID;
  v_page JSONB;
  v_distinct INTEGER;
  v_total INTEGER;
  v_page_no INTEGER := 0;
  v_expected INTEGER;
  v_has_more BOOLEAN;
BEGIN
  -- ACK page 1, including an idempotent replay.
  v_delivery := current_setting('atack_test.d32_r3_page1')::UUID;
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',v_delivery,v_token)
     OR NOT public.acknowledge_sync_cursor(v_store,v_device,'products',v_delivery,v_token) THEN
    RAISE EXCEPTION 'Page 1 ACK or duplicate ACK failed';
  END IF;

  LOOP
    v_page := public.get_unsynced_records_page(v_store,v_device,'products',v_token);
    v_expected := (v_page->>'event_count')::INTEGER;
    v_has_more := (v_page->>'has_more')::BOOLEAN;
    IF v_expected < 1 OR v_expected > 500 OR v_page->>'delivery_id' IS NULL THEN
      RAISE EXCEPTION 'Unexpected page shape after first ACK: %',v_page;
    END IF;
    v_page_no := v_page_no + 1;
    INSERT INTO pg_temp.r3_seen_events(record_uuid)
    SELECT (e->>'record_uuid')::UUID FROM jsonb_array_elements(v_page->'events') e;
    v_delivery := (v_page->>'delivery_id')::UUID;
    IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',v_delivery,v_token) THEN
      RAISE EXCEPTION 'ACK failed for subsequent page %',v_page_no;
    END IF;
    EXIT WHEN NOT v_has_more;
    IF v_page_no > 3 THEN RAISE EXCEPTION 'Pagination did not terminate'; END IF;
  END LOOP;

  SELECT COUNT(*)::INTEGER, COUNT(DISTINCT record_uuid)::INTEGER
    INTO v_total, v_distinct
    FROM pg_temp.r3_seen_events;
  IF v_total <> 1201 OR v_distinct <> 1201 THEN
    RAISE EXCEPTION 'Pagination lost or duplicated events: total %, distinct %',
      v_total,v_distinct;
  END IF;
  RAISE NOTICE 'PASS: sequential pages contain every visible event once, without gaps or duplicates';
END
$sequential_pages$;
RESET ROLE;

-- Purchases are outside the seller's permissions. Their events must neither
-- appear in the page nor affect has_more/event_count; the invisible cursor range
-- is checkpointed server-side without returning a delivery ID or hidden metadata.
SELECT set_config('request.jwt.claim.sub','20400000-0000-4000-8000-000000000032',TRUE);
SET LOCAL ROLE authenticated;
DO $hidden_event_checkpoint$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r3_device_a');
  v_token TEXT := current_setting('atack_test.d32_r3_token_a');
  v_page JSONB;
  v_cursor BIGINT;
  v_max BIGINT;
  v_base BIGINT := current_setting('atack_test.d32_r3_purchase_base')::BIGINT;
BEGIN
  v_page := public.get_unsynced_records_page(v_store,v_device,'purchases',v_token);
  IF (v_page->>'event_count')::INTEGER <> 0
     OR (v_page->>'has_more')::BOOLEAN IS NOT FALSE
     OR v_page->>'delivery_id' IS NOT NULL
     OR jsonb_array_length(v_page->'events') <> 0 THEN
    RAISE EXCEPTION 'Hidden purchase activity leaked through Pull metadata: %',v_page;
  END IF;

  SELECT last_pull_seq INTO v_cursor
    FROM public.sync_cursors
   WHERE store_id=v_store AND device_id=v_device AND table_name='purchases';
  SELECT COALESCE(MAX(sync_cursor),0) INTO v_max
    FROM public.change_log WHERE store_id=v_store AND table_name='purchases';
  IF v_max <= v_base THEN
    RAISE EXCEPTION 'Purchase Change Log fixtures were not created: base %, max %',v_base,v_max;
  END IF;
  IF v_cursor IS DISTINCT FROM v_max THEN
    RAISE EXCEPTION 'Invisible event checkpoint did not advance safely: cursor %, base %, max %',
      v_cursor,v_base,v_max;
  END IF;
  RAISE NOTICE 'PASS: invisible-only pages expose no event count/has_more/delivery ID and checkpoint safely';
END
$hidden_event_checkpoint$;
RESET ROLE;

ROLLBACK;
