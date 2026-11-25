-- Ensure every atomic business RPC takes the per-store sync cursor lock
-- before acquiring business row locks. This prevents lock-order deadlocks when
-- concurrent RPCs emit change-log entries for the same store.
BEGIN;

CREATE OR REPLACE FUNCTION public._claim_business_operation(
    p_store_id UUID,
    p_operation_id UUID,
    p_operation_name TEXT,
    p_entity_id UUID,
    p_payload JSONB,
    p_permission TEXT
) RETURNS TABLE(app_user_id UUID, already_processed BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_hash TEXT;
    v_existing_hash TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
    END IF;
    IF p_store_id IS NULL OR p_operation_id IS NULL OR p_entity_id IS NULL
       OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RAISE EXCEPTION 'store_id, operation_id, entity_id and object payload are required';
    END IF;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User is not an active member of this store' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_store_permission(p_store_id, p_permission) THEN
        RAISE EXCEPTION 'Missing permission: %', p_permission USING ERRCODE = '42501';
    END IF;

    -- Acquire the per-store change-cursor mutex before any business-row locks.
    -- log_change retains this row lock until commit; taking it here establishes
    -- one lock order across concurrent business RPCs and prevents deadlocks
    -- between row locks and the transactional sync-cursor allocator.
    INSERT INTO public.store_sync_counters(store_id, last_cursor)
    VALUES (p_store_id, 0)
    ON CONFLICT (store_id) DO NOTHING;
    PERFORM 1
      FROM public.store_sync_counters
     WHERE store_id = p_store_id
     FOR UPDATE;

    v_hash := encode(public.atack_digest(convert_to(p_operation_name || ':' || p_payload::text, 'UTF8'), 'sha256'), 'hex');
    INSERT INTO public.processed_operations(
        store_id, operation_id, operation_type, entity_table, entity_uuid, payload_hash
    ) VALUES (
        p_store_id, p_operation_id, 'sync_insert', p_operation_name, p_entity_id, v_hash
    ) ON CONFLICT (store_id, operation_id) DO NOTHING;

    IF NOT FOUND THEN
        SELECT po.payload_hash INTO v_existing_hash
          FROM public.processed_operations po
         WHERE po.store_id = p_store_id AND po.operation_id = p_operation_id
         FOR UPDATE;
        IF v_existing_hash IS DISTINCT FROM v_hash THEN
            RAISE EXCEPTION 'Idempotency key reused with a different payload' USING ERRCODE = '23505';
        END IF;
        RETURN QUERY SELECT v_user_id, TRUE;
        RETURN;
    END IF;

    RETURN QUERY SELECT v_user_id, FALSE;
END;
$$;

REVOKE ALL ON FUNCTION public._claim_business_operation(UUID,UUID,TEXT,UUID,JSONB,TEXT) FROM PUBLIC, anon, authenticated;

COMMIT;
