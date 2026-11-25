-- Phase 3 sync hardening, part 1:
-- constrain Pull/ACK to trigger-backed tables and require a registered device.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_unsynced_records(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_since_cursor BIGINT DEFAULT 0
) RETURNS TABLE(
    record_uuid UUID,
    operation TEXT,
    record_json JSONB,
    sync_cursor BIGINT,
    changed_at TIMESTAMPTZ
) AS $sync_pull$
DECLARE
    v_allowed_tables CONSTANT TEXT[] := ARRAY[
        'stores','products','customers','suppliers','purchases','invoices',
        'sales_returns','customer_payments','supplier_payments','stock_movements',
        'categories','brands','product_units','stock','purchase_items',
        'customer_ledgers','payment_allocations','invoice_items','supplier_ledger',
        'return_items','expenses','revenues',
        'purchase_returns','purchase_return_items','stock_adjustments','inventory_batches',
        'stock_alerts','chart_of_accounts','journal_entries','general_ledger',
        'purchase_receipts','purchase_receipt_items','purchase_closures',
        'purchase_closure_items','purchase_amendments'
    ];
BEGIN
    IF p_store_id IS NULL OR NULLIF(btrim(p_device_id),'') IS NULL
       OR NULLIF(btrim(p_table_name),'') IS NULL OR p_since_cursor IS NULL
       OR p_since_cursor < 0 THEN
        RAISE EXCEPTION 'Store, device, table and a non-negative cursor are required';
    END IF;

    IF NOT (p_table_name = ANY(v_allowed_tables)) THEN
        RAISE EXCEPTION 'Table % is not enabled for incremental sync',p_table_name;
    END IF;

    IF auth.uid() IS NOT NULL THEN
        IF p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
            RAISE EXCEPTION 'Store membership required';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.devices d
             WHERE d.id::TEXT = p_device_id AND d.store_id = p_store_id
        ) THEN
            RAISE EXCEPTION 'Device is not registered for this store';
        END IF;
    ELSIF COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    RETURN QUERY
    SELECT cl.record_uuid,
           cl.operation,
           CASE WHEN cl.operation = 'DELETE' THEN cl.old_values_json ELSE cl.new_values_json END,
           cl.sync_cursor,
           cl.created_at
      FROM public.change_log cl
     WHERE cl.store_id = p_store_id
       AND cl.table_name = p_table_name
       AND cl.sync_cursor > p_since_cursor
     ORDER BY cl.sync_cursor ASC
     LIMIT 500;
END;
$sync_pull$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.acknowledge_sync_cursor(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_cursor BIGINT
) RETURNS BOOLEAN AS $sync_ack$
DECLARE
    v_max_cursor BIGINT;
    v_allowed_tables CONSTANT TEXT[] := ARRAY[
        'stores','products','customers','suppliers','purchases','invoices',
        'sales_returns','customer_payments','supplier_payments','stock_movements',
        'categories','brands','product_units','stock','purchase_items',
        'customer_ledgers','payment_allocations','invoice_items','supplier_ledger',
        'return_items','expenses','revenues',
        'purchase_returns','purchase_return_items','stock_adjustments','inventory_batches',
        'stock_alerts','chart_of_accounts','journal_entries','general_ledger',
        'purchase_receipts','purchase_receipt_items','purchase_closures',
        'purchase_closure_items','purchase_amendments'
    ];
BEGIN
    IF p_store_id IS NULL OR NULLIF(btrim(p_device_id),'') IS NULL
       OR NULLIF(btrim(p_table_name),'') IS NULL OR p_cursor IS NULL OR p_cursor < 0 THEN
        RAISE EXCEPTION 'Store, device, table and a non-negative cursor are required';
    END IF;

    IF NOT (p_table_name = ANY(v_allowed_tables)) THEN
        RAISE EXCEPTION 'Table % is not enabled for incremental sync',p_table_name;
    END IF;

    IF auth.uid() IS NOT NULL THEN
        IF p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
            RAISE EXCEPTION 'Store membership required';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.devices d
             WHERE d.id::TEXT = p_device_id AND d.store_id = p_store_id
        ) THEN
            RAISE EXCEPTION 'Device is not registered for this store';
        END IF;
    ELSIF COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT COALESCE(MAX(cl.sync_cursor), 0) INTO v_max_cursor
      FROM public.change_log cl
     WHERE cl.store_id = p_store_id AND cl.table_name = p_table_name;

    IF p_cursor > v_max_cursor THEN
        RAISE EXCEPTION 'Cannot acknowledge a cursor beyond the latest change';
    END IF;
    IF p_cursor > 0 AND NOT EXISTS (
        SELECT 1 FROM public.change_log cl
         WHERE cl.store_id = p_store_id
           AND cl.table_name = p_table_name
           AND cl.sync_cursor = p_cursor
    ) THEN
        RAISE EXCEPTION 'Acknowledged cursor must identify a change for this table';
    END IF;

    INSERT INTO public.sync_cursors(store_id, device_id, table_name, last_pull_seq, cursor_value)
    VALUES (p_store_id, p_device_id, p_table_name, p_cursor, p_cursor::TEXT)
    ON CONFLICT (store_id, device_id, table_name)
    DO UPDATE SET
        last_pull_seq = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq),
        cursor_value = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq)::TEXT,
        updated_at = NOW();

    RETURN TRUE;
END;
$sync_ack$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION public.get_unsynced_records(UUID,TEXT,TEXT,BIGINT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.acknowledge_sync_cursor(UUID,TEXT,TEXT,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_unsynced_records(UUID,TEXT,TEXT,BIGINT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID,TEXT,TEXT,BIGINT) TO authenticated, service_role;

COMMIT;
