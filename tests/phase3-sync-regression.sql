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
  IF NOT EXISTS (
    SELECT 1 FROM public.sync_cursors
     WHERE store_id=v_store AND device_id=v_device AND table_name='products'
       AND last_pull_seq=v_cursor
  ) THEN
    RAISE EXCEPTION 'Acknowledged cursor was not persisted';
  END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM * FROM public.get_unsynced_records(v_store,
      '92000000-0000-4000-8000-000000000002','products',0);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Cross-store device was allowed to Pull'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM * FROM public.get_unsynced_records(v_store,v_device,'journal_entries',0);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Unapproved journal_entries Pull was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM * FROM public.get_unsynced_records(v_store,v_device,'purchase_returns',0);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Untracked Phase 3 table Pull was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,v_device,'journal_entries',0);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Unapproved table ACK was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,v_device,'products',v_cursor+100000);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ACK beyond the latest table cursor was allowed'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.acknowledge_sync_cursor(v_store,
      '92000000-0000-4000-8000-000000000002','products',v_cursor);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Cross-store device was allowed to ACK'; END IF;

  RAISE NOTICE 'PASS: sync Pull/ACK table allowlist, registered-device ownership, cursor persistence and bounds';
END
$sync_pull_ack$;

ROLLBACK;
