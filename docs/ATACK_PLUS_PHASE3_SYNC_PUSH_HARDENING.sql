-- Phase 3 sync hardening, part 2:
-- authenticated Push/Outbox, metadata-only generic writes, idempotency,
-- tombstone delivery and constrained conflict resolution.
BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS uq_sync_outbox_store_idempotency
    ON public.sync_outbox(store_id, idempotency_key);

-- The base schema installs an updated_at trigger on sync_conflicts; provide its target column.
ALTER TABLE public.sync_conflicts
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- A reused operation key must identify the same operation, entity and payload.
CREATE OR REPLACE FUNCTION public.atomic_process_operation(
    p_store_id UUID, p_operation_id UUID, p_operation_type TEXT,
    p_entity_table TEXT, p_entity_uuid UUID, p_payload_hash TEXT
) RETURNS TABLE(success BOOLEAN, conflict BOOLEAN, result_json JSONB)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $atomic$
DECLARE
    v_existing public.processed_operations%ROWTYPE;
    v_inserted BOOLEAN := FALSE;
BEGIN
    IF p_store_id IS NULL OR p_operation_id IS NULL OR p_entity_table IS NULL
       OR p_entity_uuid IS NULL OR p_payload_hash IS NULL THEN
        RAISE EXCEPTION 'Complete idempotency identity is required';
    END IF;

    INSERT INTO public.processed_operations
        (store_id, operation_id, operation_type, entity_table, entity_uuid, payload_hash)
    VALUES (p_store_id, p_operation_id, p_operation_type, p_entity_table, p_entity_uuid, p_payload_hash)
    ON CONFLICT (store_id, operation_id) DO NOTHING;
    v_inserted := FOUND;

    IF v_inserted THEN
        RETURN QUERY SELECT TRUE, FALSE, jsonb_build_object('new', TRUE);
        RETURN;
    END IF;

    SELECT * INTO v_existing
      FROM public.processed_operations po
     WHERE po.store_id = p_store_id AND po.operation_id = p_operation_id
     FOR UPDATE;

    RETURN QUERY SELECT
        (v_existing.payload_hash = p_payload_hash
         AND v_existing.operation_type = p_operation_type
         AND v_existing.entity_table = p_entity_table
         AND v_existing.entity_uuid = p_entity_uuid),
        (v_existing.payload_hash IS DISTINCT FROM p_payload_hash
         OR v_existing.operation_type IS DISTINCT FROM p_operation_type
         OR v_existing.entity_table IS DISTINCT FROM p_entity_table
         OR v_existing.entity_uuid IS DISTINCT FROM p_entity_uuid),
        jsonb_build_object('new', FALSE);
END;
$atomic$;

CREATE OR REPLACE FUNCTION public.create_outbox_entry(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_operation TEXT,
    p_record_uuid UUID,
    p_idempotency_key UUID,
    p_record_json JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $create_outbox$
DECLARE
    v_hash TEXT;
    v_existing public.sync_outbox%ROWTYPE;
    v_permission TEXT;
    v_user_store UUID;
    v_outbox_id UUID;
    v_allowed_columns TEXT[];
    v_invalid_columns TEXT[];
BEGIN
    IF p_store_id IS NULL OR p_record_uuid IS NULL OR p_idempotency_key IS NULL
       OR NULLIF(btrim(p_device_id), '') IS NULL
       OR p_record_json IS NULL OR jsonb_typeof(p_record_json) <> 'object' THEN
        RAISE EXCEPTION 'Store, device, record, idempotency key and object payload are required';
    END IF;
    IF p_table_name NOT IN ('categories','brands','products','customers','suppliers') THEN
        RAISE EXCEPTION 'Table % is not enabled for generic Push', p_table_name;
    END IF;
    IF p_operation NOT IN ('INSERT','UPDATE') THEN
        RAISE EXCEPTION 'Generic Push supports INSERT/UPDATE only; use soft_delete_record for deletion';
    END IF;
    IF NULLIF(p_record_json->>'id','')::UUID IS DISTINCT FROM p_record_uuid
       OR NULLIF(p_record_json->>'store_id','')::UUID IS DISTINCT FROM p_store_id THEN
        RAISE EXCEPTION 'Payload id/store_id must match the Outbox identity';
    END IF;

    IF auth.uid() IS NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF auth.uid() IS NOT NULL THEN
        v_user_store := public.current_user_store_id();
        IF v_user_store IS DISTINCT FROM p_store_id THEN
            RAISE EXCEPTION 'Authenticated user does not belong to the requested store';
        END IF;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.devices d
         WHERE d.id::TEXT = p_device_id AND d.store_id = p_store_id
    ) THEN
        RAISE EXCEPTION 'Device is not registered for this store';
    END IF;

    v_permission := CASE p_table_name
        WHEN 'categories' THEN 'products.write'
        WHEN 'brands' THEN 'products.write'
        WHEN 'products' THEN 'products.write'
        WHEN 'customers' THEN 'customers.write'
        WHEN 'suppliers' THEN 'suppliers.write'
    END;
    IF COALESCE(auth.role(), '') <> 'service_role'
       AND NOT public.has_store_permission(p_store_id, v_permission) THEN
        RAISE EXCEPTION 'Permission denied for generic Push to %', p_table_name;
    END IF;

    v_allowed_columns := CASE p_table_name
      WHEN 'categories' THEN ARRAY['parent_id','name','code','sort_order','is_active']
      WHEN 'brands' THEN ARRAY['name','scent','size','is_active']
      WHEN 'products' THEN ARRAY['barcode','name','description','category_id','brand_id',
        'primary_unit_id','minimum_stock','max_stock','weight','length','width','height',
        'expiry_enabled','batch_enabled','is_active']
      WHEN 'customers' THEN ARRAY['code','name','email','phone','address','city','tax_number','is_active']
      WHEN 'suppliers' THEN ARRAY['code','name','email','phone','address','city','tax_number',
        'contact_person','payment_terms','is_active']
    END;
    IF p_operation='UPDATE' THEN
        v_allowed_columns := array_remove(v_allowed_columns,'is_active');
        IF p_table_name='products' THEN
            v_allowed_columns := array_remove(v_allowed_columns,'primary_unit_id');
        END IF;
    END IF;
    SELECT array_agg(k) INTO v_invalid_columns
      FROM jsonb_object_keys(p_record_json) AS k
     WHERE k NOT IN ('id','store_id') AND NOT (k = ANY(v_allowed_columns));
    IF COALESCE(cardinality(v_invalid_columns),0) > 0 THEN
        RAISE EXCEPTION 'Outbox payload contains protected or unsupported fields: %', v_invalid_columns;
    END IF;

    v_hash := encode(digest(jsonb_build_object(
        'store_id', p_store_id, 'table_name', p_table_name,
        'operation', p_operation, 'record_uuid', p_record_uuid,
        'record', p_record_json
    )::TEXT, 'sha256'), 'hex');

    INSERT INTO public.sync_outbox
        (store_id, device_id, table_name, operation, record_uuid,
         idempotency_key, record_json, payload_hash)
    VALUES
        (p_store_id, p_device_id, p_table_name, p_operation, p_record_uuid,
         p_idempotency_key, p_record_json, v_hash)
    ON CONFLICT (store_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_outbox_id;

    IF v_outbox_id IS NOT NULL THEN
        RETURN v_outbox_id;
    END IF;

    SELECT * INTO v_existing
      FROM public.sync_outbox
     WHERE store_id = p_store_id AND idempotency_key = p_idempotency_key
     FOR UPDATE;
    IF v_existing.payload_hash IS DISTINCT FROM v_hash
       OR v_existing.table_name IS DISTINCT FROM p_table_name
       OR v_existing.operation IS DISTINCT FROM p_operation
       OR v_existing.record_uuid IS DISTINCT FROM p_record_uuid THEN
        RAISE EXCEPTION 'Idempotency key reused with different operation or payload';
    END IF;
    RETURN v_existing.id;
END;
$create_outbox$;

CREATE OR REPLACE FUNCTION public.apply_outbox_operation(p_outbox_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $apply_outbox$
DECLARE
    v_row public.sync_outbox%ROWTYPE;
    v_store_id UUID;
    v_permission TEXT;
    v_allowed_columns TEXT[];
    v_invalid_columns TEXT[];
    v_cols TEXT;
    v_insert_cols TEXT;
    v_hash TEXT;
    v_idempotency RECORD;
    v_affected BIGINT;
BEGIN
    SELECT * INTO v_row FROM public.sync_outbox WHERE id = p_outbox_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Outbox entry not found');
    END IF;

    IF auth.uid() IS NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF auth.uid() IS NOT NULL THEN
        v_store_id := public.current_user_store_id();
        IF v_store_id IS DISTINCT FROM v_row.store_id THEN
            RAISE EXCEPTION 'Outbox entry does not belong to the authenticated store';
        END IF;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.devices d
         WHERE d.id::TEXT = v_row.device_id AND d.store_id = v_row.store_id
    ) THEN
        RAISE EXCEPTION 'Outbox device is not registered for this store';
    END IF;

    v_permission := CASE v_row.table_name
        WHEN 'categories' THEN 'products.write'
        WHEN 'brands' THEN 'products.write'
        WHEN 'products' THEN 'products.write'
        WHEN 'customers' THEN 'customers.write'
        WHEN 'suppliers' THEN 'suppliers.write'
        ELSE NULL
    END;
    IF v_permission IS NULL THEN
        RAISE EXCEPTION 'Table % is not enabled for generic Push', v_row.table_name;
    END IF;
    IF COALESCE(auth.role(), '') <> 'service_role'
       AND NOT public.has_store_permission(v_row.store_id, v_permission) THEN
        RAISE EXCEPTION 'Permission denied for Outbox table %', v_row.table_name;
    END IF;

    IF v_row.status = 'SYNCED' THEN
        RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'outbox_id', p_outbox_id);
    END IF;
    IF v_row.status NOT IN ('PENDING','FAILED') THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Entry is not eligible for processing', 'status', v_row.status);
    END IF;
    IF v_row.retry_count >= v_row.max_retries THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Maximum Outbox retries reached');
    END IF;
    IF v_row.operation NOT IN ('INSERT','UPDATE')
       OR jsonb_typeof(v_row.record_json) <> 'object'
       OR NULLIF(v_row.record_json->>'id','')::UUID IS DISTINCT FROM v_row.record_uuid
       OR NULLIF(v_row.record_json->>'store_id','')::UUID IS DISTINCT FROM v_row.store_id THEN
        RAISE EXCEPTION 'Outbox payload identity is invalid';
    END IF;

    v_allowed_columns := CASE v_row.table_name
      WHEN 'categories' THEN ARRAY['parent_id','name','code','sort_order','is_active']
      WHEN 'brands' THEN ARRAY['name','scent','size','is_active']
      WHEN 'products' THEN ARRAY['barcode','name','description','category_id','brand_id',
        'primary_unit_id','minimum_stock','max_stock','weight','length','width','height',
        'expiry_enabled','batch_enabled','is_active']
      WHEN 'customers' THEN ARRAY['code','name','email','phone','address','city','tax_number','is_active']
      WHEN 'suppliers' THEN ARRAY['code','name','email','phone','address','city','tax_number',
        'contact_person','payment_terms','is_active']
    END;

    SELECT array_agg(k) INTO v_invalid_columns
      FROM jsonb_object_keys(v_row.record_json) AS k
     WHERE k NOT IN ('id','store_id') AND NOT (k = ANY(v_allowed_columns));
    IF COALESCE(cardinality(v_invalid_columns),0) > 0 THEN
        RAISE EXCEPTION 'Outbox payload contains protected or unsupported fields: %', v_invalid_columns;
    END IF;

    IF v_row.operation='UPDATE' THEN
        v_allowed_columns := array_remove(v_allowed_columns,'is_active');
        IF v_row.table_name='products' THEN
            v_allowed_columns := array_remove(v_allowed_columns,'primary_unit_id');
        END IF;
    END IF;

    v_hash := encode(digest(jsonb_build_object(
        'store_id', v_row.store_id, 'table_name', v_row.table_name,
        'operation', v_row.operation, 'record_uuid', v_row.record_uuid,
        'record', v_row.record_json
    )::TEXT, 'sha256'), 'hex');
    IF v_hash IS DISTINCT FROM v_row.payload_hash THEN
        RAISE EXCEPTION 'Outbox payload hash validation failed';
    END IF;

    BEGIN
        UPDATE public.sync_outbox
           SET status='IN_PROGRESS', last_attempt=NOW()
         WHERE id=p_outbox_id;

        SELECT * INTO v_idempotency FROM public.atomic_process_operation(
            v_row.store_id, v_row.idempotency_key, 'sync_' || lower(v_row.operation),
            v_row.table_name, v_row.record_uuid, v_row.payload_hash
        );
        IF v_idempotency.conflict THEN
            RAISE EXCEPTION 'Idempotency key reused with different operation identity or payload';
        END IF;
        IF NOT v_idempotency.success THEN
            RAISE EXCEPTION 'Could not register idempotency key';
        END IF;
        IF COALESCE((v_idempotency.result_json->>'new')::BOOLEAN,FALSE) = FALSE THEN
            UPDATE public.sync_outbox SET status='SYNCED', synced_at=NOW(), error_message=NULL
             WHERE id=p_outbox_id;
            RETURN jsonb_build_object('success',TRUE,'duplicate',TRUE,'outbox_id',p_outbox_id);
        END IF;

        IF v_row.operation='INSERT' THEN
            SELECT string_agg(format('%I',a.attname),', ' ORDER BY a.attnum)
              INTO v_insert_cols
              FROM pg_attribute a
             WHERE a.attrelid = format('public.%I',v_row.table_name)::regclass
               AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated=''
               AND (a.attname IN ('id','store_id') OR a.attname = ANY(v_allowed_columns))
               AND v_row.record_json ? a.attname;
            IF v_insert_cols IS NULL THEN RAISE EXCEPTION 'No permitted fields supplied for insert'; END IF;
            EXECUTE format(
                'INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I,$1)',
                v_row.table_name,v_insert_cols,v_insert_cols,v_row.table_name
            ) USING v_row.record_json;
        ELSE
            SELECT string_agg(format('%I = r.%I',a.attname,a.attname),', ' ORDER BY a.attnum)
              INTO v_cols
              FROM pg_attribute a
             WHERE a.attrelid = format('public.%I',v_row.table_name)::regclass
               AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated=''
               AND a.attname = ANY(v_allowed_columns)
               AND v_row.record_json ? a.attname;
            IF v_cols IS NULL THEN RAISE EXCEPTION 'No permitted fields to update'; END IF;
            EXECUTE format(
                'UPDATE public.%I AS t SET %s FROM (SELECT (jsonb_populate_record(NULL::public.%I,$1)).*) AS r WHERE t.id=$2 AND t.store_id=$3',
                v_row.table_name,v_cols,v_row.table_name
            ) USING v_row.record_json,v_row.record_uuid,v_row.store_id;
            GET DIAGNOSTICS v_affected = ROW_COUNT;
            IF v_affected=0 THEN RAISE EXCEPTION 'Update target not found in this store'; END IF;
        END IF;

        UPDATE public.sync_outbox
           SET status='SYNCED', synced_at=NOW(), error_message=NULL
         WHERE id=p_outbox_id;
        RETURN jsonb_build_object('success',TRUE,'outbox_id',p_outbox_id);
    EXCEPTION WHEN OTHERS THEN
        UPDATE public.sync_outbox
           SET status='FAILED', error_message=SQLERRM,
               last_attempt=NOW(), retry_count=retry_count+1
         WHERE id=p_outbox_id;
        RETURN jsonb_build_object('success',FALSE,'error',SQLERRM);
    END;
END;
$apply_outbox$;

-- The legacy status-only endpoint could mark an unapplied operation SYNCED.
REVOKE ALL ON FUNCTION public.process_outbox_entry(UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_outbox_entry(UUID,TEXT,TEXT,TEXT,UUID,UUID,JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.apply_outbox_operation(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_outbox_entry(UUID,TEXT,TEXT,TEXT,UUID,UUID,JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_outbox_operation(UUID) TO authenticated, service_role;

-- Soft delete is a store-authorized state transition plus a durable tombstone.
CREATE OR REPLACE FUNCTION public.soft_delete_record(
    p_table_name TEXT, p_record_uuid UUID, p_store_id UUID, p_deleted_by UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $soft_delete$
DECLARE
    v_user_id UUID;
    v_permission TEXT;
    v_old JSONB;
    v_new JSONB;
BEGIN
    IF auth.uid() IS NULL OR p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Authenticated store membership required';
    END IF;
    SELECT u.id INTO v_user_id FROM public.users u
     WHERE u.auth_user_id=auth.uid() AND u.store_id=p_store_id AND u.is_active=TRUE;
    IF v_user_id IS NULL OR p_deleted_by IS DISTINCT FROM v_user_id THEN
        RAISE EXCEPTION 'Deleted-by user must match the authenticated store user';
    END IF;
    v_permission := CASE p_table_name
      WHEN 'categories' THEN 'products.write'
      WHEN 'brands' THEN 'products.write'
      WHEN 'products' THEN 'products.write'
      WHEN 'customers' THEN 'customers.write'
      WHEN 'suppliers' THEN 'suppliers.write'
      ELSE NULL
    END;
    IF v_permission IS NULL THEN RAISE EXCEPTION 'Soft delete is not enabled for %',p_table_name; END IF;
    IF NOT public.has_store_permission(p_store_id,v_permission) THEN
        RAISE EXCEPTION 'Permission denied for soft delete';
    END IF;

    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id=$1 AND t.store_id=$2 FOR UPDATE',p_table_name)
       INTO v_old USING p_record_uuid,p_store_id;
    IF v_old IS NULL THEN RAISE EXCEPTION 'Delete target not found in this store'; END IF;

    INSERT INTO public.tombstones(store_id,table_name,record_uuid,deleted_by)
    VALUES(p_store_id,p_table_name,p_record_uuid,v_user_id)
    ON CONFLICT (table_name,record_uuid) DO NOTHING;
    IF NOT EXISTS (
        SELECT 1 FROM public.tombstones t
         WHERE t.table_name=p_table_name AND t.record_uuid=p_record_uuid AND t.store_id=p_store_id
    ) THEN
        RAISE EXCEPTION 'Tombstone identity belongs to another store';
    END IF;

    IF p_table_name='products' THEN
        EXECUTE 'UPDATE public.products SET is_active=FALSE, deleted_at=COALESCE(deleted_at,NOW()) WHERE id=$1 AND store_id=$2'
          USING p_record_uuid,p_store_id;
    ELSE
        EXECUTE format('UPDATE public.%I SET is_active=FALSE WHERE id=$1 AND store_id=$2',p_table_name)
          USING p_record_uuid,p_store_id;
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id=$1 AND t.store_id=$2',p_table_name)
       INTO v_new USING p_record_uuid,p_store_id;

    INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,old_values_json,new_values_json)
    VALUES(p_store_id,v_user_id,p_table_name,p_record_uuid,'DELETE',v_old,v_new);
END;
$soft_delete$;

-- Tombstones are themselves change-logged and can be pulled/acknowledged.
DROP TRIGGER IF EXISTS trg_tombstones_log_change ON public.tombstones;
CREATE TRIGGER trg_tombstones_log_change
AFTER INSERT OR UPDATE OR DELETE ON public.tombstones
FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();

-- Restrict conflict resolution to non-financial metadata and auditable columns.
CREATE OR REPLACE FUNCTION public.resolve_sync_conflict(
    p_conflict_id UUID, p_resolution TEXT, p_resolved_by UUID, p_merged_json JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $resolve_conflict$
DECLARE
    v_conflict public.sync_conflicts%ROWTYPE;
    v_user_id UUID;
    v_final JSONB;
    v_old JSONB;
    v_new JSONB;
    v_columns TEXT[];
    v_cols TEXT;
    v_invalid TEXT[];
    v_affected BIGINT;
BEGIN
    SELECT * INTO v_conflict FROM public.sync_conflicts WHERE id=p_conflict_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',FALSE,'error','Conflict not found'); END IF;
    IF auth.uid() IS NULL OR v_conflict.store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Authenticated store membership required';
    END IF;
    SELECT u.id INTO v_user_id FROM public.users u
     WHERE u.auth_user_id=auth.uid() AND u.store_id=v_conflict.store_id AND u.is_active=TRUE;
    IF v_user_id IS NULL OR p_resolved_by IS DISTINCT FROM v_user_id THEN
        RAISE EXCEPTION 'Resolved-by user does not match authenticated user';
    END IF;
    IF NOT public.has_store_permission(v_conflict.store_id,'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    IF v_conflict.resolution_status IS DISTINCT FROM 'PENDING' THEN
        RETURN jsonb_build_object('success',FALSE,'error','Conflict already resolved');
    END IF;
    IF p_resolution NOT IN ('ACCEPT_LOCAL','ACCEPT_REMOTE','MERGE') THEN
        RAISE EXCEPTION 'Invalid resolution type';
    END IF;

    v_columns := CASE v_conflict.table_name
      WHEN 'categories' THEN ARRAY['parent_id','name','code','sort_order','is_active']
      WHEN 'brands' THEN ARRAY['name','scent','size','is_active']
      WHEN 'products' THEN ARRAY['barcode','name','description','category_id','brand_id',
        'primary_unit_id','minimum_stock','max_stock','weight','length','width','height',
        'expiry_enabled','batch_enabled','is_active']
      WHEN 'customers' THEN ARRAY['code','name','email','phone','address','city','tax_number','is_active']
      WHEN 'suppliers' THEN ARRAY['code','name','email','phone','address','city','tax_number',
        'contact_person','payment_terms','is_active']
      ELSE NULL
    END;
    IF v_columns IS NULL THEN
        RAISE EXCEPTION 'Generic conflict resolution is disabled for table %',v_conflict.table_name;
    END IF;
    IF NOT public.has_store_permission(v_conflict.store_id,
        CASE v_conflict.table_name WHEN 'customers' THEN 'customers.write'
             WHEN 'suppliers' THEN 'suppliers.write' ELSE 'products.write' END) THEN
        RAISE EXCEPTION 'Permission denied for conflict table %',v_conflict.table_name;
    END IF;

    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id=$1 AND t.store_id=$2 FOR UPDATE',v_conflict.table_name)
       INTO v_old USING v_conflict.record_uuid,v_conflict.store_id;
    IF v_old IS NULL THEN RAISE EXCEPTION 'Conflict target not found in this store'; END IF;

    v_final := CASE p_resolution
      WHEN 'ACCEPT_LOCAL' THEN v_conflict.local_record_json
      WHEN 'ACCEPT_REMOTE' THEN v_conflict.remote_record_json
      ELSE p_merged_json END;
    IF v_final IS NULL OR jsonb_typeof(v_final)<>'object' THEN
        RAISE EXCEPTION 'Resolution payload must be a JSON object';
    END IF;
    IF (v_final ? 'id' AND NULLIF(v_final->>'id','')::UUID IS DISTINCT FROM v_conflict.record_uuid)
       OR (v_final ? 'store_id' AND NULLIF(v_final->>'store_id','')::UUID IS DISTINCT FROM v_conflict.store_id) THEN
        RAISE EXCEPTION 'Resolution cannot change record identity or store';
    END IF;
    SELECT array_agg(k) INTO v_invalid
      FROM jsonb_object_keys(v_final) AS k
     WHERE k NOT IN ('id','store_id') AND NOT (k=ANY(v_columns));
    IF COALESCE(cardinality(v_invalid),0)>0 THEN
        RAISE EXCEPTION 'Resolution contains protected fields: %',v_invalid;
    END IF;

    SELECT string_agg(format('%I = r.%I',a.attname,a.attname),', ' ORDER BY a.attnum)
      INTO v_cols
      FROM pg_attribute a
     WHERE a.attrelid=format('public.%I',v_conflict.table_name)::regclass
       AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated=''
       AND a.attname=ANY(v_columns) AND v_final ? a.attname;
    IF v_cols IS NULL THEN RAISE EXCEPTION 'No permitted fields in resolution payload'; END IF;
    EXECUTE format(
      'UPDATE public.%I AS t SET %s FROM (SELECT (jsonb_populate_record(NULL::public.%I,$1)).*) AS r WHERE t.id=$2 AND t.store_id=$3',
      v_conflict.table_name,v_cols,v_conflict.table_name
    ) USING v_final,v_conflict.record_uuid,v_conflict.store_id;
    GET DIAGNOSTICS v_affected=ROW_COUNT;
    IF v_affected=0 THEN RAISE EXCEPTION 'Conflict target update failed'; END IF;

    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id=$1 AND t.store_id=$2',v_conflict.table_name)
       INTO v_new USING v_conflict.record_uuid,v_conflict.store_id;
    UPDATE public.sync_conflicts
       SET resolution_status=p_resolution,resolved_by=v_user_id,
           resolved_at=NOW(),resolution_notes=p_resolution || ' applied'
     WHERE id=p_conflict_id;
    INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,old_values_json,new_values_json)
    VALUES(v_conflict.store_id,v_user_id,'sync_conflicts',p_conflict_id,'SYNC',
           jsonb_build_object('target_table',v_conflict.table_name,'record',v_old),
           jsonb_build_object('resolution',p_resolution,'record',v_new));
    RETURN jsonb_build_object('success',TRUE,'action',p_resolution);
END;
$resolve_conflict$;

-- Expose only the validated entry points.
REVOKE ALL ON FUNCTION public.soft_delete_record(TEXT,UUID,UUID,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_sync_conflict(UUID,TEXT,UUID,JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.soft_delete_record(TEXT,UUID,UUID,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_sync_conflict(UUID,TEXT,UUID,JSONB) TO authenticated;

COMMIT;
