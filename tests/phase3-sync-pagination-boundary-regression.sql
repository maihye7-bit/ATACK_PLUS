-- D3.2 / R6 regression: exact 499/500/501 page boundaries.
BEGIN;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000071','20800000-0000-4000-8000-000000000071',
  '10000000-0000-4000-8000-000000000001','d32_r6_owner','D3.2 R6 Owner',TRUE),
 ('99100000-0000-4000-8000-000000000072','20800000-0000-4000-8000-000000000072',
  '10000000-0000-4000-8000-000000000001','d32_r6_seller','D3.2 R6 Seller',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000071','owner'),
 ('99100000-0000-4000-8000-000000000072','cashier')
ON CONFLICT (user_id,role_id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub','20800000-0000-4000-8000-000000000071',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO $provision$
DECLARE r JSONB;
BEGIN
  r := public.register_sync_device(
    '99100000-0000-4000-8000-000000000072','D3.2 R6 Boundary Device','DESKTOP');
  PERFORM set_config('atack_test.d32_r6_device',r->>'device_id',TRUE);
  PERFORM set_config('atack_test.d32_r6_token',r->>'device_token',TRUE);
END
$provision$;
RESET ROLE;

DO $seed$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r6_device');
  v_table TEXT;
  v_count INTEGER;
  v_base BIGINT;
BEGIN
  FOR v_table,v_count IN
    SELECT * FROM (VALUES ('categories',499),('brands',500),('products',501)) AS x(table_name,event_count)
  LOOP
    SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
      FROM public.change_log WHERE store_id=v_store AND table_name=v_table;
    INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq,cursor_value)
    VALUES(v_store,v_device,v_table,v_base,v_base::TEXT)
    ON CONFLICT (store_id,device_id,table_name) DO UPDATE
      SET last_pull_seq=EXCLUDED.last_pull_seq,cursor_value=EXCLUDED.cursor_value;

    PERFORM public.log_change(
      v_store,v_table,ids.id,'UPDATE',NULL,
      jsonb_build_object('id',ids.id,'store_id',v_store,'name','D3.2 R6 boundary fixture')
    )
    FROM (SELECT gen_random_uuid() AS id FROM generate_series(1,v_count)) ids;
  END LOOP;
END
$seed$;

SELECT set_config('request.jwt.claim.sub','20800000-0000-4000-8000-000000000072',TRUE);
SET LOCAL ROLE authenticated;
DO $boundaries$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r6_device');
  v_token TEXT := current_setting('atack_test.d32_r6_token');
  p JSONB;
  v_delivery UUID;
BEGIN
  p := public.get_unsynced_records_page(v_store,v_device,'categories',v_token);
  IF (p->>'event_count')::INTEGER <> 499
     OR (p->>'has_more')::BOOLEAN IS NOT FALSE
     OR jsonb_array_length(p->'events') <> 499 THEN
    RAISE EXCEPTION '499-event page boundary failed: %',p;
  END IF;
  v_delivery := (p->>'delivery_id')::UUID;
  PERFORM public.acknowledge_sync_cursor(v_store,v_device,'categories',v_delivery,v_token);

  p := public.get_unsynced_records_page(v_store,v_device,'brands',v_token);
  IF (p->>'event_count')::INTEGER <> 500
     OR (p->>'has_more')::BOOLEAN IS NOT FALSE
     OR jsonb_array_length(p->'events') <> 500 THEN
    RAISE EXCEPTION '500-event page boundary failed: %',p;
  END IF;
  v_delivery := (p->>'delivery_id')::UUID;
  PERFORM public.acknowledge_sync_cursor(v_store,v_device,'brands',v_delivery,v_token);

  p := public.get_unsynced_records_page(v_store,v_device,'products',v_token);
  IF (p->>'event_count')::INTEGER <> 500
     OR (p->>'has_more')::BOOLEAN IS NOT TRUE
     OR jsonb_array_length(p->'events') <> 500 THEN
    RAISE EXCEPTION '501-event first page boundary failed: %',p;
  END IF;
  v_delivery := (p->>'delivery_id')::UUID;
  PERFORM public.acknowledge_sync_cursor(v_store,v_device,'products',v_delivery,v_token);

  p := public.get_unsynced_records_page(v_store,v_device,'products',v_token);
  IF (p->>'event_count')::INTEGER <> 1
     OR (p->>'has_more')::BOOLEAN IS NOT FALSE
     OR jsonb_array_length(p->'events') <> 1 THEN
    RAISE EXCEPTION '501-event continuation boundary failed: %',p;
  END IF;
  v_delivery := (p->>'delivery_id')::UUID;
  PERFORM public.acknowledge_sync_cursor(v_store,v_device,'products',v_delivery,v_token);
  RAISE NOTICE 'PASS: 499, 500 and 501 page boundaries behave exactly as specified';
END
$boundaries$;
RESET ROLE;

ROLLBACK;
