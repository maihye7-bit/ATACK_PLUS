-- Phase 3 Push/Outbox, tombstone and conflict-resolution regressions.
-- Requires Phase 2 fixtures plus Phase 3 Sync Pull/ACK fixtures.

-- Inject a deterministic audit failure for one dedicated fixture to prove the
-- tombstone and live-row mutation are rolled back in the same transaction.
CREATE OR REPLACE FUNCTION pg_temp.fail_soft_delete_audit_for_rollback_test()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $rollback_test$
BEGIN
  IF NEW.entity_type='categories'
     AND NEW.entity_id='93000000-0000-4000-8000-000000000003'::UUID
     AND NEW.action='DELETE' THEN
    RAISE EXCEPTION 'forced soft-delete audit failure' USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$rollback_test$;

DROP TRIGGER IF EXISTS trg_test_soft_delete_audit_failure ON public.audit_logs;
CREATE TRIGGER trg_test_soft_delete_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_soft_delete_audit_for_rollback_test();

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
  v_error TEXT;
  v_count INTEGER;
  v_name TEXT;
  v_retry UUID;
  v_parent UUID := '93000000-0000-4000-8000-000000000001';
  v_child UUID := '93000000-0000-4000-8000-000000000002';
  v_conflict UUID := '94000000-0000-4000-8000-000000000001';
  v_role_conflict UUID := '94000000-0000-4000-8000-000000000002';
  v_reactivation_conflict UUID := '94000000-0000-4000-8000-000000000003';
  v_brand UUID := '93000000-0000-4000-8000-000000000020';
  v_tombstone UUID;
  v_audit_count_before BIGINT;
  v_change_count_before BIGINT;
  v_deleted_at_before TIMESTAMPTZ;
  v_rollback_category UUID := '93000000-0000-4000-8000-000000000003';
  v_rollback_error TEXT;
  v_master_table TEXT;
BEGIN
  PERFORM set_config('request.jwt.claim.sub',v_auth::TEXT,TRUE);

  -- Authenticated clients must not have direct DML table- or column-level grants
  -- on any master-data table; trusted SECURITY DEFINER RPCs remain the write path.
  FOREACH v_master_table IN ARRAY ARRAY['categories','brands','products','customers','suppliers'] LOOP
    IF has_table_privilege('authenticated',format('public.%I',v_master_table),'INSERT')
       OR has_table_privilege('authenticated',format('public.%I',v_master_table),'UPDATE')
       OR has_table_privilege('authenticated',format('public.%I',v_master_table),'DELETE')
       OR has_any_column_privilege('authenticated',format('public.%I',v_master_table),'INSERT')
       OR has_any_column_privilege('authenticated',format('public.%I',v_master_table),'UPDATE') THEN
      RAISE EXCEPTION 'Authenticated role retains a direct DML grant on public.%',v_master_table;
    END IF;
  END LOOP;

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
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Idempotency key reused with different operation or payload%' THEN RAISE; END IF;
    v_denied:=TRUE;
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
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Authenticated user does not belong to the requested store%' THEN RAISE; END IF;
    v_denied:=TRUE;
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
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Outbox payload contains protected or unsupported fields%' THEN RAISE; END IF;
    v_denied:=TRUE;
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
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Outbox payload contains protected or unsupported fields%' THEN RAISE; END IF;
    v_denied:=TRUE;
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
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Outbox payload contains protected or unsupported fields%' THEN RAISE; END IF;
    v_denied:=TRUE;
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

   -- Replaying a completed soft delete must not emit another audit or change-log event.
   SELECT id,deleted_at INTO v_tombstone,v_deleted_at_before
     FROM public.tombstones
    WHERE store_id=v_store AND table_name='categories' AND record_uuid=v_child;
   SELECT count(*) INTO v_audit_count_before FROM public.audit_logs
    WHERE store_id=v_store AND entity_type='categories' AND entity_id=v_child AND action='DELETE';
   SELECT count(*) INTO v_change_count_before FROM public.change_log
    WHERE store_id=v_store
      AND ((table_name='categories' AND record_uuid=v_child)
        OR (table_name='tombstones' AND record_uuid=v_tombstone));
   PERFORM public.soft_delete_record('categories',v_child,v_store,v_user);
   IF (SELECT count(*) FROM public.audit_logs
        WHERE store_id=v_store AND entity_type='categories' AND entity_id=v_child AND action='DELETE')
        IS DISTINCT FROM v_audit_count_before THEN
     RAISE EXCEPTION 'Repeated soft delete created a duplicate audit record';
   END IF;
   IF (SELECT count(*) FROM public.change_log
        WHERE store_id=v_store
          AND ((table_name='categories' AND record_uuid=v_child)
            OR (table_name='tombstones' AND record_uuid=v_tombstone)))
        IS DISTINCT FROM v_change_count_before THEN
     RAISE EXCEPTION 'Repeated soft delete emitted duplicate change-log events';
   END IF;
   IF (SELECT deleted_at FROM public.tombstones WHERE id=v_tombstone)
        IS DISTINCT FROM v_deleted_at_before THEN
     RAISE EXCEPTION 'Repeated soft delete changed the original tombstone timestamp';
   END IF;

   -- Brands must have the lifecycle column used by the shared soft-delete RPC.
   INSERT INTO public.brands(id,store_id,name,is_active)
   VALUES(v_brand,v_store,'Soft-delete regression brand',TRUE);
   PERFORM public.soft_delete_record('brands',v_brand,v_store,v_user);
   IF NOT EXISTS(SELECT 1 FROM public.brands WHERE id=v_brand AND store_id=v_store AND is_active=FALSE)
      OR NOT EXISTS(SELECT 1 FROM public.tombstones
        WHERE store_id=v_store AND table_name='brands' AND record_uuid=v_brand AND deleted_by=v_user) THEN
     RAISE EXCEPTION 'Brand soft delete did not persist its lifecycle state and tombstone';
   END IF;

  -- Generic conflict resolution must not reactivate a record with a tombstone.
  INSERT INTO public.sync_conflicts(id,store_id,table_name,record_uuid,conflict_type,
    local_record_json,remote_record_json)
  VALUES(v_reactivation_conflict,v_store,'categories',v_child,'DUPLICATE',
    jsonb_build_object('id',v_child,'store_id',v_store,'name','Deleted category','is_active',FALSE),
    jsonb_build_object('id',v_child,'store_id',v_store,'name','Attempted revival','is_active',TRUE));
  v_denied := FALSE;
  BEGIN
    PERFORM public.resolve_sync_conflict(v_reactivation_conflict,'ACCEPT_REMOTE',v_user,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Cannot reactivate a tombstoned record%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied
     OR NOT EXISTS(SELECT 1 FROM public.categories WHERE id=v_child AND is_active=FALSE)
     OR NOT EXISTS(SELECT 1 FROM public.sync_conflicts
       WHERE id=v_reactivation_conflict AND resolution_status='PENDING') THEN
    RAISE EXCEPTION 'Generic conflict resolution reactivated a tombstoned record or consumed the pending conflict';
  END IF;

  -- An injected audit failure must roll back both the tombstone and live-row UPDATE.
  INSERT INTO public.categories(id,store_id,name,is_active)
  VALUES(v_rollback_category,v_store,'Soft-delete rollback fixture',TRUE);
  v_rollback_error := NULL;
  BEGIN
    PERFORM public.soft_delete_record('categories',v_rollback_category,v_store,v_user);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_rollback_error = MESSAGE_TEXT;
  END;
  IF v_rollback_error IS DISTINCT FROM 'forced soft-delete audit failure' THEN
    RAISE EXCEPTION 'Expected injected audit failure, received: %',v_rollback_error;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.categories
      WHERE id=v_rollback_category AND store_id=v_store AND is_active=TRUE)
     OR EXISTS(SELECT 1 FROM public.tombstones
      WHERE store_id=v_store AND table_name='categories' AND record_uuid=v_rollback_category) THEN
    RAISE EXCEPTION 'Soft-delete audit failure did not roll back row state and tombstone atomically';
  END IF;

  -- Generic conflict resolution cannot edit role grants or protected financial fields.
  INSERT INTO public.sync_conflicts(id,store_id,table_name,record_uuid,conflict_type,
    local_record_json,remote_record_json)
  VALUES(v_role_conflict,v_store,'user_roles','96000000-0000-4000-8000-000000000001',
    'DUPLICATE','{}'::jsonb,'{}'::jsonb);
  v_denied:=FALSE;
  BEGIN
    PERFORM public.resolve_sync_conflict(v_role_conflict,'ACCEPT_REMOTE',v_user,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Generic conflict resolution is disabled for table user_roles%' THEN RAISE; END IF;
    v_denied:=TRUE;
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


DROP TRIGGER IF EXISTS trg_test_soft_delete_audit_failure ON public.audit_logs;
DROP FUNCTION IF EXISTS pg_temp.fail_soft_delete_audit_for_rollback_test();
