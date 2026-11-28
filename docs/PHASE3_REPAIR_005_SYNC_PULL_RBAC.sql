-- D3.2 / R1: enforce the existing owner/seller read contract inside SECURITY DEFINER Pull.
-- This migration is applied only after RBAC read hardening and owner/seller role consolidation.
BEGIN;

CREATE OR REPLACE FUNCTION public.can_read_sync_change(
    p_store_id UUID,
    p_table_name TEXT,
    p_operation TEXT,
    p_record_json JSONB
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $sync_visibility$
DECLARE
    v_user_id UUID;
    v_owner BOOLEAN := FALSE;
    v_permission TEXT;
    v_created_by UUID;
    v_parent_store UUID;
    v_target_table TEXT;
BEGIN
    IF p_store_id IS NULL
       OR NULLIF(btrim(p_table_name), '') IS NULL
       OR p_record_json IS NULL
       OR jsonb_typeof(p_record_json) <> 'object' THEN
        RETURN FALSE;
    END IF;

    -- Trusted service-role jobs retain the existing server-to-server path.
    IF auth.uid() IS NULL THEN
        RETURN COALESCE(auth.role(), '') = 'service_role';
    END IF;

    IF p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RETURN FALSE;
    END IF;

    SELECT u.id
      INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    IF v_user_id IS NULL THEN
        RETURN FALSE;
    END IF;

    v_owner := public.has_store_permission(p_store_id, 'users.manage');

    -- A tombstone is visible only when the caller may read the entity it deletes.
    -- Its target identity is taken from the server-created change-log payload.
    IF p_table_name = 'tombstones' THEN
        IF NULLIF(p_record_json->>'store_id', '')::UUID IS DISTINCT FROM p_store_id THEN
            RETURN FALSE;
        END IF;
        v_target_table := p_record_json->>'table_name';
        v_permission := CASE v_target_table
            WHEN 'categories' THEN 'products.read'
            WHEN 'brands' THEN 'products.read'
            WHEN 'products' THEN 'products.read'
            WHEN 'customers' THEN 'customers.read'
            WHEN 'suppliers' THEN 'suppliers.read'
            ELSE NULL
        END;
        RETURN v_permission IS NOT NULL
           AND public.has_store_permission(p_store_id, v_permission);
    END IF;

    -- Tables with direct store ownership or store-wide visibility.
    v_permission := CASE p_table_name
        WHEN 'stores' THEN NULL
        WHEN 'categories' THEN 'products.read'
        WHEN 'brands' THEN 'products.read'
        WHEN 'products' THEN 'products.read'
        WHEN 'customers' THEN 'customers.read'
        WHEN 'suppliers' THEN 'suppliers.read'
        WHEN 'purchases' THEN 'purchases.read'
        WHEN 'purchase_returns' THEN 'purchases.read'
        WHEN 'purchase_receipts' THEN 'purchases.read'
        WHEN 'purchase_closures' THEN 'purchases.read'
        WHEN 'purchase_amendments' THEN 'purchases.read'
        WHEN 'expenses' THEN 'reports.financial'
        WHEN 'revenues' THEN 'reports.financial'
        WHEN 'stock_adjustments' THEN 'inventory.adjust'
        WHEN 'inventory_batches' THEN 'inventory.adjust'
        WHEN 'stock_alerts' THEN 'inventory.adjust'
        WHEN 'chart_of_accounts' THEN 'reports.financial'
        WHEN 'general_ledger' THEN 'reports.financial'
        WHEN 'journal_entries' THEN 'reports.financial'
        WHEN 'stock' THEN 'inventory.read'
        WHEN 'stock_movements' THEN 'inventory.adjust'
        WHEN 'locations' THEN 'inventory.read'
        WHEN 'supplier_ledger' THEN 'suppliers.payments'
        WHEN 'supplier_payments' THEN 'suppliers.payments'
        WHEN 'purchase_items' THEN 'purchases.read'
        WHEN 'purchase_return_items' THEN 'purchases.read'
        WHEN 'purchase_receipt_items' THEN 'purchases.read'
        WHEN 'purchase_closure_items' THEN 'purchases.read'
        WHEN 'product_units' THEN 'products.read'
        WHEN 'invoices' THEN 'sales.read'
        WHEN 'invoice_items' THEN 'sales.read'
        WHEN 'sales_returns' THEN 'sales.read'
        WHEN 'return_items' THEN 'sales.read'
        WHEN 'customer_payments' THEN 'customers.payments'
        WHEN 'customer_ledgers' THEN 'customers.payments'
        WHEN 'payment_allocations' THEN 'customers.payments'
        ELSE NULL
    END;

    IF p_table_name = 'stores' THEN
        RETURN (p_record_json->>'id')::UUID = p_store_id;
    END IF;

    IF v_permission IS NULL
       OR NOT public.has_store_permission(p_store_id, v_permission) THEN
        RETURN FALSE;
    END IF;

    -- Reject inconsistent store identity in the logged payload before evaluating
    -- any table-specific visibility rule.
    IF p_record_json ? 'store_id'
       AND NULLIF(p_record_json->>'store_id', '')::UUID IS DISTINCT FROM p_store_id THEN
        RETURN FALSE;
    END IF;

    -- Seller-owned sales records must follow the same ownership rules as RLS.
    IF p_table_name = 'invoices' THEN
        v_created_by := NULLIF(p_record_json->>'created_by', '')::UUID;
        RETURN v_owner OR v_created_by = v_user_id;
    ELSIF p_table_name = 'invoice_items' THEN
        SELECT i.store_id, i.created_by
          INTO v_parent_store, v_created_by
          FROM public.invoices i
         WHERE i.id = NULLIF(p_record_json->>'invoice_id', '')::UUID;
        RETURN v_parent_store = p_store_id
           AND (v_owner OR v_created_by = v_user_id);
    ELSIF p_table_name = 'sales_returns' THEN
        SELECT i.store_id, i.created_by
          INTO v_parent_store, v_created_by
          FROM public.invoices i
         WHERE i.id = NULLIF(p_record_json->>'original_invoice_id', '')::UUID;
        RETURN v_parent_store = p_store_id
           AND (v_owner OR v_created_by = v_user_id);
    ELSIF p_table_name = 'return_items' THEN
        SELECT i.store_id, i.created_by
          INTO v_parent_store, v_created_by
          FROM public.sales_returns sr
          JOIN public.invoices i ON i.id = sr.original_invoice_id
         WHERE sr.id = NULLIF(p_record_json->>'return_id', '')::UUID
           AND sr.store_id = p_store_id;
        RETURN v_parent_store = p_store_id
           AND (v_owner OR v_created_by = v_user_id);
    ELSIF p_table_name IN ('customer_payments', 'customer_ledgers') THEN
        SELECT c.store_id
          INTO v_parent_store
          FROM public.customers c
         WHERE c.id = NULLIF(p_record_json->>'customer_id', '')::UUID;
        v_created_by := NULLIF(p_record_json->>'created_by', '')::UUID;
        RETURN v_parent_store = p_store_id
           AND (v_owner OR v_created_by = v_user_id);
    ELSIF p_table_name = 'payment_allocations' THEN
        RETURN EXISTS (
            SELECT 1
              FROM public.customer_payments cp
              JOIN public.customers c ON c.id = cp.customer_id
              JOIN public.invoices i ON i.id = NULLIF(p_record_json->>'invoice_id', '')::UUID
             WHERE cp.id = NULLIF(p_record_json->>'payment_id', '')::UUID
               AND i.customer_id = cp.customer_id
               AND c.store_id = p_store_id
               AND i.store_id = p_store_id
               AND (
                   v_owner
                   OR (
                       cp.created_by = v_user_id
                       AND i.created_by = v_user_id
                   )
               )
        );
    END IF;

    -- Child records inherit store scope from their authoritative parent.
    IF p_table_name = 'product_units' THEN
        SELECT p.store_id INTO v_parent_store
          FROM public.products p
         WHERE p.id = NULLIF(p_record_json->>'product_id', '')::UUID;
    ELSIF p_table_name = 'stock' OR p_table_name = 'stock_movements' THEN
        SELECT p.store_id INTO v_parent_store
          FROM public.products p
         WHERE p.id = NULLIF(p_record_json->>'product_id', '')::UUID;
    ELSIF p_table_name = 'purchase_items' THEN
        SELECT p.store_id INTO v_parent_store
          FROM public.purchases p
         WHERE p.id = NULLIF(p_record_json->>'purchase_id', '')::UUID;
    ELSIF p_table_name IN ('supplier_ledger', 'supplier_payments') THEN
        SELECT s.store_id INTO v_parent_store
          FROM public.suppliers s
         WHERE s.id = NULLIF(p_record_json->>'supplier_id', '')::UUID;
    ELSIF p_table_name = 'purchase_return_items' THEN
        SELECT pr.store_id INTO v_parent_store
          FROM public.purchase_returns pr
         WHERE pr.id = NULLIF(p_record_json->>'return_id', '')::UUID;
    ELSIF p_table_name = 'purchase_receipt_items' THEN
        SELECT pr.store_id INTO v_parent_store
          FROM public.purchase_receipts pr
         WHERE pr.id = NULLIF(p_record_json->>'receipt_id', '')::UUID;
    ELSIF p_table_name = 'purchase_closure_items' THEN
        SELECT pc.store_id INTO v_parent_store
          FROM public.purchase_closures pc
         WHERE pc.id = NULLIF(p_record_json->>'closure_id', '')::UUID;
    ELSE
        -- For all remaining allowlisted store-owned tables, the Change Log's
        -- store_id is authoritative and any payload store_id was checked above.
        RETURN TRUE;
    END IF;

    RETURN v_parent_store = p_store_id;
END;
$sync_visibility$;

REVOKE ALL ON FUNCTION public.can_read_sync_change(UUID, TEXT, TEXT, JSONB)
    FROM PUBLIC, anon, authenticated, service_role;

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
        'return_items','expenses','revenues','purchase_returns','purchase_return_items',
        'stock_adjustments','inventory_batches','stock_alerts','chart_of_accounts',
        'journal_entries','general_ledger','purchase_receipts','purchase_receipt_items',
        'purchase_closures','purchase_closure_items','purchase_amendments','tombstones','locations'
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
       AND public.can_read_sync_change(
           p_store_id,
           p_table_name,
           cl.operation,
           CASE WHEN cl.operation = 'DELETE' THEN cl.old_values_json ELSE cl.new_values_json END
       )
     ORDER BY cl.sync_cursor ASC
     LIMIT 500;
END;
$sync_pull$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION public.get_unsynced_records(UUID,TEXT,TEXT,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_unsynced_records(UUID,TEXT,TEXT,BIGINT) TO authenticated, service_role;

COMMIT;
