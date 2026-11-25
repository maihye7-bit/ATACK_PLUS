-- Authenticated-role Push/Outbox regression.
-- Phase 2 business fixtures and the registered sync device are created by prior tests.
BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;

DO $authenticated_push$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_store_b UUID := '10000000-0000-4000-8000-000000000002';
  v_device TEXT := '91000000-0000-4000-8000-000000000001';
  v_record UUID := '97000000-0000-4000-8000-000000000001';
  v_key UUID := '98000000-0000-4000-8000-000000000001';
  v_outbox UUID;
  v_replay UUID;
  v_result JSONB;
  v_denied BOOLEAN;
  v_error TEXT;
BEGIN
  IF current_user <> 'authenticated' THEN
    RAISE EXCEPTION 'Push test is not running as authenticated: %',current_user;
  END IF;
  IF public.current_user_store_id() IS DISTINCT FROM v_store THEN
    RAISE EXCEPTION 'Authenticated Push identity resolved to the wrong store';
  END IF;
  IF NOT has_function_privilege(current_user,
      'public.create_outbox_entry(uuid,text,text,text,uuid,uuid,jsonb)','EXECUTE')
     OR NOT has_function_privilege(current_user,
      'public.apply_outbox_operation(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role lacks the intended Push/Outbox RPC grants';
  END IF;

  v_outbox := public.create_outbox_entry(
    v_store,v_device,'categories','INSERT',v_record,v_key,
    jsonb_build_object('id',v_record,'store_id',v_store,'name','Authenticated Outbox category','is_active',TRUE)
  );
  v_replay := public.create_outbox_entry(
    v_store,v_device,'categories','INSERT',v_record,v_key,
    jsonb_build_object('id',v_record,'store_id',v_store,'name','Authenticated Outbox category','is_active',TRUE)
  );
  IF v_outbox IS DISTINCT FROM v_replay THEN
    RAISE EXCEPTION 'Authenticated exact Push replay created a duplicate Outbox row';
  END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store_b,'92000000-0000-4000-8000-000000000002','categories','INSERT',
      '97000000-0000-4000-8000-000000000002','98000000-0000-4000-8000-000000000002',
      jsonb_build_object('id','97000000-0000-4000-8000-000000000002','store_id',v_store_b,'name','Cross-store Push')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Authenticated user does not belong to the requested store%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Authenticated cross-store Push was accepted'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store,v_device,'categories','INSERT',
      '97000000-0000-4000-8000-000000000003','98000000-0000-4000-8000-000000000003',
      jsonb_build_object('id','97000000-0000-4000-8000-000000000003','store_id',v_store,
        'name','Protected metadata','is_active',TRUE,'created_by','20000000-0000-4000-8000-000000000001')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Outbox payload contains protected or unsupported fields%' THEN RAISE; END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Authenticated Push accepted a protected column'; END IF;

  v_result := public.apply_outbox_operation(v_outbox);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Authenticated Outbox apply failed: %',v_result;
  END IF;
  v_result := public.apply_outbox_operation(v_outbox);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR COALESCE((v_result->>'duplicate')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Authenticated Outbox apply replay was not idempotent: %',v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.categories
    WHERE id=v_record AND store_id=v_store AND name='Authenticated Outbox category') THEN
    RAISE EXCEPTION 'Authenticated Outbox operation did not persist its metadata row';
  END IF;
  RAISE NOTICE 'PASS: authenticated Push enqueue/apply, store isolation, protected columns and idempotent replay';
END
$authenticated_push$;
ROLLBACK;
