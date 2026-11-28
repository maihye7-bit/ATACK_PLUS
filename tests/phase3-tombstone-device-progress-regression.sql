-- D3.2 / R5 regression: Tombstone status is not a global multi-device ACK.
BEGIN;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000051','20600000-0000-4000-8000-000000000051',
  '10000000-0000-4000-8000-000000000001','d32_r5_owner','D3.2 R5 Owner',TRUE),
 ('99100000-0000-4000-8000-000000000052','20600000-0000-4000-8000-000000000052',
  '10000000-0000-4000-8000-000000000001','d32_r5_seller','D3.2 R5 Seller',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000051','owner'),
 ('99100000-0000-4000-8000-000000000052','cashier')
ON CONFLICT (user_id,role_id) DO NOTHING;

INSERT INTO public.categories(id,store_id,name,code,is_active)
VALUES (
 '99200000-0000-4000-8000-000000000051',
 '10000000-0000-4000-8000-000000000001',
 'D3.2 R5 Multi Device Tombstone','D32-R5-CATEGORY',TRUE
)
ON CONFLICT (id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub','20600000-0000-4000-8000-000000000051',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_provision$
DECLARE a JSONB; b JSONB;
BEGIN
  a := public.register_sync_device(
    '99100000-0000-4000-8000-000000000052','D3.2 R5 Seller Device A','DESKTOP');
  b := public.register_sync_device(
    '99100000-0000-4000-8000-000000000052','D3.2 R5 Seller Device B','PHONE');
  PERFORM set_config('atack_test.d32_r5_device_a',a->>'device_id',TRUE);
  PERFORM set_config('atack_test.d32_r5_token_a',a->>'device_token',TRUE);
  PERFORM set_config('atack_test.d32_r5_device_b',b->>'device_id',TRUE);
  PERFORM set_config('atack_test.d32_r5_token_b',b->>'device_token',TRUE);
END
$owner_provision$;
RESET ROLE;

-- Both devices begin at the same pre-delete Tombstone high-water mark.
DO $seed_cursors$
DECLARE v_base BIGINT; v_store UUID := '10000000-0000-4000-8000-000000000001';
BEGIN
  SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
    FROM public.change_log WHERE store_id=v_store AND table_name='tombstones';
  PERFORM set_config('atack_test.d32_r5_base',v_base::TEXT,TRUE);
  INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq,cursor_value)
  VALUES
    (v_store,current_setting('atack_test.d32_r5_device_a'),'tombstones',v_base,v_base::TEXT),
    (v_store,current_setting('atack_test.d32_r5_device_b'),'tombstones',v_base,v_base::TEXT)
  ON CONFLICT (store_id,device_id,table_name) DO UPDATE
    SET last_pull_seq=EXCLUDED.last_pull_seq,cursor_value=EXCLUDED.cursor_value;
END
$seed_cursors$;

SELECT set_config('request.jwt.claim.sub','20600000-0000-4000-8000-000000000051',TRUE);
SET LOCAL ROLE authenticated;
DO $soft_delete$
BEGIN
  PERFORM public.soft_delete_record(
    'categories',
    '99200000-0000-4000-8000-000000000051',
    '10000000-0000-4000-8000-000000000001',
    '99100000-0000-4000-8000-000000000051'
  );
END
$soft_delete$;
RESET ROLE;

-- Device A receives and ACKs the Tombstone. Device B has not yet pulled it.
SELECT set_config('request.jwt.claim.sub','20600000-0000-4000-8000-000000000052',TRUE);
SET LOCAL ROLE authenticated;
DO $device_a_ack$
DECLARE p JSONB; v_delivery UUID;
BEGIN
  p := public.get_unsynced_records_page(
    '10000000-0000-4000-8000-000000000001',
    current_setting('atack_test.d32_r5_device_a'),'tombstones',
    current_setting('atack_test.d32_r5_token_a')
  );
  IF (p->>'event_count')::INTEGER <> 1 OR p->>'delivery_id' IS NULL THEN
    RAISE EXCEPTION 'Device A did not receive the Tombstone: %',p;
  END IF;
  v_delivery := (p->>'delivery_id')::UUID;
  IF NOT public.acknowledge_sync_cursor(
    '10000000-0000-4000-8000-000000000001',
    current_setting('atack_test.d32_r5_device_a'),'tombstones',
    v_delivery,current_setting('atack_test.d32_r5_token_a')
  ) THEN RAISE EXCEPTION 'Device A ACK failed'; END IF;
  RAISE NOTICE 'PASS: device A acknowledged its own Tombstone delivery';
END
$device_a_ack$;
RESET ROLE;

DO $after_device_a$
DECLARE v_status TEXT; v_synced_at TIMESTAMPTZ; v_a BIGINT; v_b BIGINT; v_base BIGINT;
BEGIN
  SELECT sync_status,synced_at INTO v_status,v_synced_at
    FROM public.tombstones
   WHERE table_name='categories'
     AND record_uuid='99200000-0000-4000-8000-000000000051';
  SELECT last_pull_seq INTO v_a FROM public.sync_cursors
   WHERE device_id=current_setting('atack_test.d32_r5_device_a') AND table_name='tombstones';
  SELECT last_pull_seq INTO v_b FROM public.sync_cursors
   WHERE device_id=current_setting('atack_test.d32_r5_device_b') AND table_name='tombstones';
  v_base := current_setting('atack_test.d32_r5_base')::BIGINT;
  IF v_status <> 'PENDING' OR v_synced_at IS NOT NULL THEN
    RAISE EXCEPTION 'One device ACK incorrectly changed global Tombstone status';
  END IF;
  IF v_a <= v_base OR v_b IS DISTINCT FROM v_base THEN
    RAISE EXCEPTION 'Device progress is not independent after A ACK: A %, B %, base %',v_a,v_b,v_base;
  END IF;
  RAISE NOTICE 'PASS: A progress advances independently while B remains behind and Tombstone stays PENDING';
END
$after_device_a$;

-- Device B receives and ACKs the same logical delete independently.
SELECT set_config('request.jwt.claim.sub','20600000-0000-4000-8000-000000000052',TRUE);
SET LOCAL ROLE authenticated;
DO $device_b_ack$
DECLARE p JSONB; v_delivery UUID;
BEGIN
  p := public.get_unsynced_records_page(
    '10000000-0000-4000-8000-000000000001',
    current_setting('atack_test.d32_r5_device_b'),'tombstones',
    current_setting('atack_test.d32_r5_token_b')
  );
  IF (p->>'event_count')::INTEGER <> 1 OR p->>'delivery_id' IS NULL THEN
    RAISE EXCEPTION 'Device B did not receive the Tombstone: %',p;
  END IF;
  v_delivery := (p->>'delivery_id')::UUID;
  IF NOT public.acknowledge_sync_cursor(
    '10000000-0000-4000-8000-000000000001',
    current_setting('atack_test.d32_r5_device_b'),'tombstones',
    v_delivery,current_setting('atack_test.d32_r5_token_b')
  ) THEN RAISE EXCEPTION 'Device B ACK failed'; END IF;
  RAISE NOTICE 'PASS: device B acknowledged its own Tombstone delivery';
END
$device_b_ack$;
RESET ROLE;

DO $final_state$
DECLARE
  v_status TEXT;
  v_synced_at TIMESTAMPTZ;
  v_a BIGINT;
  v_b BIGINT;
  v_max BIGINT;
  v_acked INTEGER;
BEGIN
  SELECT sync_status,synced_at INTO v_status,v_synced_at
    FROM public.tombstones
   WHERE table_name='categories'
     AND record_uuid='99200000-0000-4000-8000-000000000051';
  SELECT last_pull_seq INTO v_a FROM public.sync_cursors
   WHERE device_id=current_setting('atack_test.d32_r5_device_a') AND table_name='tombstones';
  SELECT last_pull_seq INTO v_b FROM public.sync_cursors
   WHERE device_id=current_setting('atack_test.d32_r5_device_b') AND table_name='tombstones';
  SELECT MAX(sync_cursor) INTO v_max FROM public.change_log
   WHERE store_id='10000000-0000-4000-8000-000000000001' AND table_name='tombstones';
  SELECT COUNT(*)::INTEGER INTO v_acked FROM public.sync_delivery_pages
   WHERE store_id='10000000-0000-4000-8000-000000000001'
     AND table_name='tombstones'
     AND device_id IN (
       current_setting('atack_test.d32_r5_device_a')::UUID,
       current_setting('atack_test.d32_r5_device_b')::UUID
     )
     AND acknowledged_at IS NOT NULL;

  IF v_status <> 'PENDING' OR v_synced_at IS NOT NULL THEN
    RAISE EXCEPTION 'Legacy global Tombstone fields were incorrectly treated as all-device state';
  END IF;
  IF v_a IS DISTINCT FROM v_max OR v_b IS DISTINCT FROM v_max OR v_acked <> 2 THEN
    RAISE EXCEPTION 'Per-device ACK state is incomplete: A %, B %, max %, acked pages %',
      v_a,v_b,v_max,v_acked;
  END IF;
  RAISE NOTICE 'PASS: both devices have independent ACK records; global Tombstone status remains legacy PENDING';
END
$final_state$;

ROLLBACK;
