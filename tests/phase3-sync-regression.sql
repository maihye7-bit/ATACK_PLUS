-- Phase 3 incremental sync Pull/ACK security regression tests.
-- Requires Phase 2 business fixtures and the Phase 3 security fixture.
INSERT INTO public.devices(id,store_id,device_name,device_type)
VALUES
 ('91000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','Sync Test Device A','DESKTOP'),
 ('92000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','Sync Test Device B','DESKTOP')
ON CONFLICT (id) DO NOTHING;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;

DO $sync_pull_ack$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := '91000000-0000-4000-8000-000000000001';
  v_cursor BIGINT;
  v_count INTEGER;
  v_denied BOOLEAN;
  v_error TEXT;
BEGIN
  IF public.current_user_store_id() IS DISTINCT FROM v_store THEN
    RAISE EXCEPTION 'Sync test authenticated user resolved to the wrong store';
  END IF;

  SELECT count(*),max(sync_cursor) INTO v_count,v_cursor
    FROM public.get_unsynced_records(v_store,v_device,'products',0);
  IF v_count=0 OR v_cursor IS NULL THEN
    RAISE EXCEPTION 'Registered device could not pull its store product changes';
  END IF;

  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',v_cursor) THEN
    RAISE EXCEPTION 'Valid Pull cursor was not acknowledged';
  END IF;
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',0) THEN
    RAISE EXCEPTION 'Stale zero cursor ACK was not safely accepted';
  END IF;
  v_denied:=FALSE;
  BEGIN
    PERFORM * FROM public.get_unsynced_records(v_store,
      '92000000-0000-4000-8000-000000000002','products',0);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device is not registered for this store%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Cross-store device was allowed to Pull'; END IF;

  -- Phase 3 server-generated records are pullable, but not generic-pushable.
  PERFORM * FROM public.get_unsynced_records(v_store,v_device,'journal_entries',0);
  PERFORM * FROM public.get_unsynced_records(v_store,v_device,'purchase_returns',0);
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'purchase_returns',0) THEN
    RAISE EXCEPTION 'Phase 3 table initial cursor could not be acknowledged';
  END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM * FROM public.get_unsynced_records(v_store,v_device,'audit_logs',0);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Table audit_logs is not enabled for incremental sync%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Untracked audit_logs Pull was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,v_device,'audit_logs',0);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Table audit_logs is not enabled for incremental sync%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Untracked table ACK was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,v_device,'products',v_cursor+100000);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Cannot acknowledge a cursor beyond the latest change%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ACK beyond the latest table cursor was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,
      '92000000-0000-4000-8000-000000000002','products',v_cursor);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device is not registered for this store%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Cross-store device was allowed to ACK'; END IF;

  RAISE NOTICE 'PASS: sync Pull/ACK table allowlist, registered-device ownership, cursor persistence and bounds';
END
$sync_pull_ack$;

RESET ROLE;
DO $sync_ack_persistence$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.sync_cursors
     WHERE store_id='10000000-0000-4000-8000-000000000001'
       AND device_id='91000000-0000-4000-8000-000000000001'
       AND table_name='products'
       AND last_pull_seq=(SELECT COALESCE(MAX(sync_cursor),0) FROM public.change_log
                           WHERE store_id='10000000-0000-4000-8000-000000000001'
                             AND table_name='products')
       AND cursor_value=last_pull_seq::TEXT
  ) THEN
    RAISE EXCEPTION 'Acknowledged cursor was not persisted';
  END IF;
END
$sync_ack_persistence$;

ROLLBACK;
