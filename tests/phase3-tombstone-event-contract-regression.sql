-- D3.2 / R4 regression: Tombstone is the canonical DELETE signal.
-- Verifies target identity, separate tombstone identity, trigger ordering and global UUID uniqueness.
BEGIN;

INSERT INTO public.stores(id,name)
VALUES('20000000-0000-4000-8000-000000000001','D3.2 R4 Secondary Store')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000041','20500000-0000-4000-8000-000000000041',
  '10000000-0000-4000-8000-000000000001','d32_r4_owner','D3.2 R4 Owner',TRUE),
 ('99100000-0000-4000-8000-000000000042','20500000-0000-4000-8000-000000000042',
  '10000000-0000-4000-8000-000000000001','d32_r4_seller','D3.2 R4 Seller',TRUE),
 ('99100000-0000-4000-8000-000000000043','20500000-0000-4000-8000-000000000043',
  '20000000-0000-4000-8000-000000000001','d32_r4_owner_store2','D3.2 R4 Store2 Owner',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000041','owner'),
 ('99100000-0000-4000-8000-000000000042','cashier'),
 ('99100000-0000-4000-8000-000000000043','owner')
ON CONFLICT (user_id,role_id) DO NOTHING;

INSERT INTO public.categories(id,store_id,name,code,is_active)
VALUES (
 '99200000-0000-4000-8000-000000000041',
 '10000000-0000-4000-8000-000000000001',
 'D3.2 R4 Tombstone Category','D32-R4-CATEGORY',TRUE
)
ON CONFLICT (id) DO NOTHING;

-- Catalog proof: every soft-delete target has a globally unique UUID primary key
-- and store_id; the stronger current tombstone uniqueness guard is intentional.
DO $tombstone_catalog$
DECLARE
  v_table TEXT;
  v_id_ok BOOLEAN;
  v_store_ok BOOLEAN;
  v_unique_columns TEXT[];
BEGIN
  FOREACH v_table IN ARRAY ARRAY['categories','brands','products','customers','suppliers'] LOOP
    SELECT EXISTS (
      SELECT 1
        FROM pg_index i
        JOIN pg_attribute a
          ON a.attrelid=i.indrelid
         AND a.attnum=ANY(i.indkey)
       WHERE i.indrelid=format('public.%I',v_table)::REGCLASS
         AND i.indisprimary
         AND i.indnatts=1
         AND a.attname='id'
         AND a.atttypid='uuid'::REGTYPE
         AND a.attnotnull
    ) INTO v_id_ok;
    SELECT EXISTS (
      SELECT 1 FROM pg_attribute a
       WHERE a.attrelid=format('public.%I',v_table)::REGCLASS
         AND a.attname='store_id'
         AND a.atttypid='uuid'::REGTYPE
         AND a.attnotnull
         AND NOT a.attisdropped
    ) INTO v_store_ok;
    IF NOT v_id_ok OR NOT v_store_ok THEN
      RAISE EXCEPTION 'Tombstone target %.id/store_id no longer meets global UUID identity contract',v_table;
    END IF;
  END LOOP;

  SELECT array_agg(a.attname::TEXT ORDER BY a.attname::TEXT)
    INTO v_unique_columns
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) AS k(attnum) ON TRUE
    JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
   WHERE c.conrelid='public.tombstones'::REGCLASS
     AND c.conname='unique_tombstone'
     AND c.contype='u';
  IF v_unique_columns IS DISTINCT FROM ARRAY['record_uuid','table_name']::TEXT[] THEN
    RAISE EXCEPTION 'unique_tombstone constraint changed unexpectedly: %',v_unique_columns;
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_trigger t
       WHERE t.tgrelid='public.tombstones'::REGCLASS
         AND t.tgname='trg_tombstones_log_change'
         AND NOT t.tgisinternal
         AND t.tgenabled IN ('O','A')
         AND t.tgfoid='public.trg_log_change()'::REGPROCEDURE
  ) THEN
    RAISE EXCEPTION 'Tombstone Change Log trigger is missing or disabled';
  END IF;
  RAISE NOTICE 'PASS: tombstone target UUID PKs, uniqueness guard and enabled Change Log trigger are verified';
END
$tombstone_catalog$;

-- Provision a seller device and start its tombstone stream at the current high-water mark.
SELECT set_config('request.jwt.claim.sub','20500000-0000-4000-8000-000000000041',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO $provision$
DECLARE r JSONB; v_base BIGINT;
BEGIN
  r := public.register_sync_device(
    '99100000-0000-4000-8000-000000000042',
    'D3.2 R4 Tombstone Seller Device','DESKTOP'
  );
  PERFORM set_config('atack_test.d32_r4_device',r->>'device_id',TRUE);
  PERFORM set_config('atack_test.d32_r4_token',r->>'device_token',TRUE);
END
$provision$;
RESET ROLE;

SELECT COALESCE(MAX(sync_cursor),0) AS tombstone_base
FROM public.change_log
WHERE store_id='10000000-0000-4000-8000-000000000001' AND table_name='tombstones';
DO $set_cursor$
DECLARE v_base BIGINT;
BEGIN
  SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
    FROM public.change_log
   WHERE store_id='10000000-0000-4000-8000-000000000001' AND table_name='tombstones';
  INSERT INTO public.sync_cursors(
    store_id,device_id,table_name,last_pull_seq,cursor_value
  ) VALUES (
    '10000000-0000-4000-8000-000000000001',
    current_setting('atack_test.d32_r4_device'),
    'tombstones',v_base,v_base::TEXT
  )
  ON CONFLICT (store_id,device_id,table_name) DO UPDATE
    SET last_pull_seq=EXCLUDED.last_pull_seq,cursor_value=EXCLUDED.cursor_value;
END
$set_cursor$;

-- Owner soft-deletes the category. Tombstone INSERT must be logged before the
-- original category UPDATE. Replaying the same request must not emit duplicates.
SELECT set_config('request.jwt.claim.sub','20500000-0000-4000-8000-000000000041',TRUE);
SET LOCAL ROLE authenticated;
DO $soft_delete$
BEGIN
  PERFORM public.soft_delete_record(
    'categories',
    '99200000-0000-4000-8000-000000000041',
    '10000000-0000-4000-8000-000000000001',
    '99100000-0000-4000-8000-000000000041'
  );
  PERFORM public.soft_delete_record(
    'categories',
    '99200000-0000-4000-8000-000000000041',
    '10000000-0000-4000-8000-000000000001',
    '99100000-0000-4000-8000-000000000041'
  );
END
$soft_delete$;
RESET ROLE;

DO $delete_state$
DECLARE
  v_tombstone_id UUID;
  v_tombstone_cursor BIGINT;
  v_target_update_cursor BIGINT;
  v_count INTEGER;
BEGIN
  SELECT id INTO v_tombstone_id FROM public.tombstones
   WHERE store_id='10000000-0000-4000-8000-000000000001'
     AND table_name='categories'
     AND record_uuid='99200000-0000-4000-8000-000000000041';
  IF v_tombstone_id IS NULL THEN RAISE EXCEPTION 'Expected tombstone was not created'; END IF;

  SELECT COUNT(*)::INTEGER INTO v_count FROM public.tombstones
   WHERE table_name='categories' AND record_uuid='99200000-0000-4000-8000-000000000041';
  IF v_count <> 1 THEN RAISE EXCEPTION 'Repeated soft delete created duplicate tombstones'; END IF;

  SELECT sync_cursor INTO v_tombstone_cursor FROM public.change_log
   WHERE store_id='10000000-0000-4000-8000-000000000001'
     AND table_name='tombstones' AND record_uuid=v_tombstone_id AND operation='INSERT';
  SELECT sync_cursor INTO v_target_update_cursor FROM public.change_log
   WHERE store_id='10000000-0000-4000-8000-000000000001'
     AND table_name='categories'
     AND record_uuid='99200000-0000-4000-8000-000000000041'
     AND operation='UPDATE'
   ORDER BY sync_cursor DESC LIMIT 1;
  IF v_tombstone_cursor IS NULL OR v_target_update_cursor IS NULL
     OR v_tombstone_cursor >= v_target_update_cursor THEN
    RAISE EXCEPTION 'Tombstone must be logged before target UPDATE: tombstone %, target %',
      v_tombstone_cursor,v_target_update_cursor;
  END IF;
  IF (SELECT is_active FROM public.categories
       WHERE id='99200000-0000-4000-8000-000000000041') IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'Soft-delete target was not made inactive';
  END IF;
  PERFORM set_config('atack_test.d32_r4_tombstone_id',v_tombstone_id::TEXT,TRUE);
  RAISE NOTICE 'PASS: tombstone identity is stable, replay is idempotent and Tombstone precedes target UPDATE';
END
$delete_state$;

-- A user in another store cannot create a tombstone for this store's category.
SELECT set_config('request.jwt.claim.sub','20500000-0000-4000-8000-000000000043',TRUE);
SET LOCAL ROLE authenticated;
DO $cross_store$
DECLARE denied BOOLEAN := FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM public.soft_delete_record(
      'categories',
      '99200000-0000-4000-8000-000000000041',
      '20000000-0000-4000-8000-000000000001',
      '99100000-0000-4000-8000-000000000043'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Delete target not found in this store%' THEN RAISE; END IF;
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Cross-store tombstone was accepted'; END IF;
  RAISE NOTICE 'PASS: soft delete cannot create a cross-store tombstone';
END
$cross_store$;
RESET ROLE;

-- Seller receives the canonical delete envelope: original entity identity and
-- tombstone_id are separate, and the transport stream remains tombstones.
SELECT set_config('request.jwt.claim.sub','20500000-0000-4000-8000-000000000042',TRUE);
SET LOCAL ROLE authenticated;
DO $pull_tombstone$
DECLARE
  v_page JSONB;
  v_event JSONB;
  v_delivery UUID;
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r4_device');
  v_token TEXT := current_setting('atack_test.d32_r4_token');
  v_target UUID := '99200000-0000-4000-8000-000000000041';
  v_tombstone UUID := current_setting('atack_test.d32_r4_tombstone_id')::UUID;
BEGIN
  v_page := public.get_unsynced_records_page(v_store,v_device,'tombstones',v_token);
  IF (v_page->>'event_count')::INTEGER <> 1
     OR (v_page->>'has_more')::BOOLEAN IS NOT FALSE
     OR v_page->>'delivery_id' IS NULL THEN
    RAISE EXCEPTION 'Unexpected tombstone Pull page: %',v_page;
  END IF;
  v_event := v_page->'events'->0;
  IF v_event->>'event_type' IS DISTINCT FROM 'DELETE'
     OR v_event->>'operation' IS DISTINCT FROM 'DELETE'
     OR v_event->>'table_name' IS DISTINCT FROM 'categories'
     OR (v_event->>'record_uuid')::UUID IS DISTINCT FROM v_target
     OR (v_event->>'tombstone_id')::UUID IS DISTINCT FROM v_tombstone
     OR v_event->'record_json'->>'event_type' IS DISTINCT FROM 'DELETE'
     OR v_event->'record_json'->>'table_name' IS DISTINCT FROM 'categories'
     OR (v_event->'record_json'->>'record_uuid')::UUID IS DISTINCT FROM v_target
     OR (v_event->'record_json'->>'tombstone_id')::UUID IS DISTINCT FROM v_tombstone
     OR (v_event->'record_json'->>'store_id')::UUID IS DISTINCT FROM v_store
     OR v_event->'record_json'->>'deleted_at' IS NULL
     OR (v_event->'record_json'->>'deleted_by')::UUID IS DISTINCT FROM
        '99100000-0000-4000-8000-000000000041'::UUID THEN
    RAISE EXCEPTION 'Canonical Tombstone DELETE envelope is invalid: %',v_event;
  END IF;
  v_delivery := (v_page->>'delivery_id')::UUID;
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'tombstones',v_delivery,v_token) THEN
    RAISE EXCEPTION 'Tombstone delivery ACK failed';
  END IF;
  RAISE NOTICE 'PASS: Pull emits canonical DELETE with original record_uuid and distinct tombstone_id';
END
$pull_tombstone$;
RESET ROLE;

-- The stronger global UNIQUE guard rejects a duplicate tombstone for the
-- same logical target, independently of the idempotent soft-delete RPC.
DO $unique_guard$
DECLARE denied BOOLEAN := FALSE;
BEGIN
  BEGIN
    INSERT INTO public.tombstones(
      store_id,table_name,record_uuid,deleted_by
    ) VALUES (
      '10000000-0000-4000-8000-000000000001',
      'categories',
      '99200000-0000-4000-8000-000000000041',
      '99100000-0000-4000-8000-000000000041'
    );
  EXCEPTION WHEN unique_violation THEN
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Global tombstone uniqueness guard did not reject duplicate identity'; END IF;
  RAISE NOTICE 'PASS: existing UNIQUE(table_name, record_uuid) remains a valid stronger guard';
END
$unique_guard$;

ROLLBACK;
