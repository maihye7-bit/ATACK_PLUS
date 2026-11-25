-- Phase 3 Push/Outbox, tombstone and conflict-resolution regressions.
-- Requires Phase 2 fixtures plus Phase 3 Sync Pull/ACK fixtures.
DO $push_outbox_regression$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_store_b UUID := '10000000-0000-4000-8000-000000000002';
  v_auth UUID := '20000000-0000-4000-8000-000000000001';
  v_user UUID := '30000000-0000-4000-8000-000000000001';
  v_device TEXT := '91000000-0000-4000-8000-000000000001';
  v_outbox UUID;
  v_replay UUID;
  v_result JSONB;
  v_denied BOOLEAN;
  v_count INTEGER;
  v_name TEXT;
  v_retry UUID;
  v_parent UUID := '93000000-0000-4000-8000-000000000001';
  v_child UUID := '93000000-0000-4000-8000-000000000002';
  v_conflict UUID := '94000000-0000-4000-8000-000000000001';
  v_role_conflict UUID := '94000000-0000-4000-8000-000000000002';
BEGIN
  PERFORM set_config('request.jwt.claim.sub',v_auth::TEXT,TRUE);

  -- Push is idempotent at enqueue time: exact replay returns the same Outbox row.
  v_outbox := public.create_outbox_entry(
    v_store,v_device,'categories','INSERT',
    '93000000-0000-4000-8000-000000000010',
    '95000000-0000-4000-8000-000000000001',
    jsonb_build_object('id','93000000-0000-4000-8000-000000000010',
      'store_id',v_store,'name','Outbox category','is_active',TRUE)
  );
  v_replay := public.create_outbox_entry(
    v_store,v_device,'categories','INSERT',
    '93000000-0000-4000-8000-000000000010',
    '95000000-0000-4000-8000-000000000001',
    jsonb_build_object('id','93000000-0000-4000-8000-000000000010',
      'store_id',v_store,'name','Outbox category','is_active',TRUE)
  );
  IF v_outbox IS DISTINCT FROM v_replay THEN
    RAISE EXCEPTION 'Identical Outbox replay created a second row';
  END IF;
  SELECT count(*) INTO v_count FROM public.sync_outbox
   WHERE store_id=v_store AND idempotency_key='95000000-0000-4000-8000-000000000001';
  IF v_count<>1 THEN RAISE EXCEPTION 'Expected exactly one idempotent Outbox row, got %',v_count; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store,v_device,'categories','INSERT',
      '93000000-0000-4000-8000-000000000011',
      '95000000-0000-4000-8000-000000000001',
      jsonb_build_object('id','93000000-0000-4000-8000-000000000011',
        'store_id',v_store,'name','Different payload')
    );
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Reused operation key with a different payload was accepted'; END IF;

  -- Cross-store identity and unregistered devices must not enqueue.
  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store_b,'92000000-0000-4000-8000-000000000002','categories','INSERT',
      '93000000-0000-4000-8000-000000000012',
      '95000000-0000-4000-8000-000000000002',
      jsonb_build_object('id','93000000-0000-4000-8000-000000000012',
        'store_id',v_store_b,'name','Cross store')
    );
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Cross-store Outbox enqueue was accepted'; END IF;

  -- Generic Push must not mutate prices, costs or derived debt/balance fields.
  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store,v_device,'products','INSERT',
      '93000000-0000-4000-8000-000000000013',
      '95000000-0000-4000-8000-000000000003',
      jsonb_build_object('id','93000000-0000-4000-8000-000000000013',
        'store_id',v_store,'name','Protected product','primary_unit_id','pcs',
        'cost_price',1,'default_sale_price',2)
    );
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Protected product price/cost fields entered generic Outbox'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store,v_device,'customers','UPDATE',
      '40000000-0000-4000-8000-000000000001',
      '95000000-0000-4000-8000-000000000004',
      jsonb_build_object('id','40000000-0000-4000-8000-000000000001',
        'store_id',v_store,'current_debt',0,'total_sales',0)
    );
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Derived customer balances entered generic Outbox'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.create_outbox_entry(
      v_store,v_device,'categories','UPDATE',
      '93000000-0000-4000-8000-000000000010',
      '95000000-0000-4000-8000-000000000006',
      jsonb_build_object('id','93000000-0000-4000-8000-000000000010',
        'store_id',v_store,'name','Hidden without tombstone','is_active',FALSE)
    );
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Generic UPDATE bypassed the tombstone soft-delete path'; END IF;

  v_result := public.apply_outbox_operation(v_outbox);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Valid metadata Push failed: %',v_result;
  END IF;
  SELECT name INTO v_name FROM public.categories
   WHERE id='93000000-0000-4000-8000-000000000010' AND store_id=v_store;
  IF v_name IS DISTINCT FROM 'Outbox category' THEN
    RAISE EXCEPTION 'Valid metadata Push did not persist the category';
  END IF;
  v_result := public.apply_outbox_operation(v_outbox);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR COALESCE((v_result->>'duplicate')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Successful Outbox retry was not idempotent: %',v_result;
  END IF;

  -- Failed FK operation rolls back its idempotency claim; after dependency arrival it can retry.
  v_retry := public.create_outbox_entry(
    v_store,v_device,'categories','INSERT',v_child,
    '95000000-0000-4000-8000-000000000005',
    jsonb_build_object('id',v_child,'store_id',v_store,'name','Retry child',
      'parent_id',v_parent,'is_active',TRUE)
  );
  v_result := public.apply_outbox_operation(v_retry);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT FALSE THEN
    RAISE EXCEPTION 'Outbox with missing parent unexpectedly succeeded';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sync_outbox WHERE id=v_retry AND status='FAILED' AND retry_count=1) THEN
    RAISE EXCEPTION 'Failed Outbox attempt was not retained as FAILED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.processed_operations
    WHERE store_id=v_store AND operation_id='95000000-0000-4000-8000-000000000005') THEN
    RAISE EXCEPTION 'Failed transaction left an idempotency claim behind';
  END IF;
  INSERT INTO public.categories(id,store_id,name,is_active)
  VALUES(v_parent,v_store,'Retry parent',TRUE);
  v_result := public.apply_outbox_operation(v_retry);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR NOT EXISTS(SELECT 1 FROM public.categories WHERE id=v_child AND parent_id=v_parent) THEN
    RAISE EXCEPTION 'Failed Outbox entry could not retry after dependency repair: %',v_result;
  END IF;

  -- Status-only legacy API is not callable by app or worker roles.
  IF has_function_privilege('authenticated',
       'public.process_outbox_entry(uuid,text,text)','EXECUTE')
     OR has_function_privilege('service_role',
       'public.process_outbox_entry(uuid,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Legacy status-only Outbox endpoint remains executable';
  END IF;

  -- Soft delete updates the live row, creates an auditable tombstone and publishes it to Pull.
  PERFORM public.soft_delete_record('categories',v_child,v_store,v_user);
  IF NOT EXISTS(SELECT 1 FROM public.categories WHERE id=v_child AND is_active=FALSE) THEN
    RAISE EXCEPTION 'Soft delete did not deactivate the live record';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tombstones
    WHERE store_id=v_store AND table_name='categories' AND record_uuid=v_child
      AND deleted_by=v_user AND sync_status='PENDING') THEN
    RAISE EXCEPTION 'Soft delete did not create a pending tombstone';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.audit_logs
    WHERE store_id=v_store AND entity_type='categories' AND entity_id=v_child AND action='DELETE') THEN
    RAISE EXCEPTION 'Soft delete did not write an audit record';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.get_unsynced_records(v_store,v_device,'tombstones',0)
     WHERE record_uuid IN (SELECT id FROM public.tombstones WHERE table_name='categories' AND record_uuid=v_child)
       AND operation='INSERT'
  ) THEN
    RAISE EXCEPTION 'Tombstone was not exposed through incremental Pull';
  END IF;

  -- Generic conflict resolution cannot edit role grants or protected financial fields.
  INSERT INTO public.sync_conflicts(id,store_id,table_name,record_uuid,conflict_type,
    local_record_json,remote_record_json)
  VALUES(v_role_conflict,v_store,'user_roles','96000000-0000-4000-8000-000000000001',
    'DUPLICATE','{}'::jsonb,'{}'::jsonb);
  v_denied:=FALSE;
  BEGIN
    PERFORM public.resolve_sync_conflict(v_role_conflict,'ACCEPT_REMOTE',v_user,NULL);
  EXCEPTION WHEN OTHERS THEN v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Generic conflict resolution allowed user_roles mutation'; END IF;

  INSERT INTO public.sync_conflicts(id,store_id,table_name,record_uuid,conflict_type,
    local_record_json,remote_record_json)
  VALUES(v_conflict,v_store,'categories',v_parent,'DUPLICATE',
    jsonb_build_object('id',v_parent,'store_id',v_store,'name','Local parent'),
    jsonb_build_object('id',v_parent,'store_id',v_store,'name','Remote parent'));
  v_result := public.resolve_sync_conflict(v_conflict,'ACCEPT_REMOTE',v_user,NULL);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR NOT EXISTS(SELECT 1 FROM public.categories WHERE id=v_parent AND name='Remote parent') THEN
    RAISE EXCEPTION 'Safe metadata conflict resolution failed: %',v_result;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.audit_logs
    WHERE store_id=v_store AND entity_type='sync_conflicts' AND entity_id=v_conflict AND action='SYNC') THEN
    RAISE EXCEPTION 'Conflict resolution did not write an audit record';
  END IF;

  RAISE NOTICE 'PASS: authenticated Push, Outbox idempotency, protected fields, rollback/retry, tombstones and audited conflict resolution';
END
$push_outbox_regression$;
