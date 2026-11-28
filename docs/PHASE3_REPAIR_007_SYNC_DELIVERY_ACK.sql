-- D3.2 / R3: record each server-issued Pull page and bind ACK to that delivery.
-- Hidden events are skipped server-side without exposing their count or identity.
BEGIN;

CREATE TABLE public.sync_delivery_pages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
    device_id UUID NOT NULL REFERENCES public.devices(id) ON DELETE RESTRICT,
    table_name TEXT NOT NULL,
    cursor_after BIGINT NOT NULL CHECK (cursor_after >= 0),
    cursor_through BIGINT NOT NULL CHECK (cursor_through > cursor_after),
    event_count INTEGER NOT NULL CHECK (event_count BETWEEN 1 AND 500),
    has_more BOOLEAN NOT NULL,
    page_hash TEXT NOT NULL CHECK (page_hash ~ '^[0-9a-f]{64}$'),
    credential_version INTEGER NOT NULL CHECK (credential_version > 0),
    issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    acknowledged_at TIMESTAMPTZ,
    acknowledged_cursor BIGINT,
    CONSTRAINT uq_sync_delivery_page UNIQUE (
        store_id, device_id, table_name, cursor_after, cursor_through,
        page_hash, credential_version
    ),
    CONSTRAINT sync_delivery_ack_state CHECK (
        (acknowledged_at IS NULL AND acknowledged_cursor IS NULL)
        OR (acknowledged_at IS NOT NULL AND acknowledged_cursor = cursor_through)
    )
);

CREATE INDEX idx_sync_delivery_pending
    ON public.sync_delivery_pages(store_id, device_id, table_name, cursor_after)
    WHERE acknowledged_at IS NULL;

ALTER TABLE public.sync_delivery_pages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sync_delivery_pages FROM PUBLIC, anon, authenticated, service_role;

-- The R2 page-shaped legacy Pull/ACK overloads do not carry delivery proof.
-- Keep them for trusted service-role jobs only.
REVOKE EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_unsynced_records_page(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_device_token TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $pull_page$
DECLARE
    v_device_id UUID;
    v_user_id UUID;
    v_credential_version INTEGER;
    v_cursor_after BIGINT := 0;
    v_cursor_through BIGINT;
    v_raw_max BIGINT;
    v_page_max BIGINT;
    v_visible_count INTEGER := 0;
    v_event_count INTEGER := 0;
    v_has_more BOOLEAN := FALSE;
    v_events JSONB := '[]'::JSONB;
    v_page_hash TEXT;
    v_delivery_id UUID;
    v_allowed_tables CONSTANT TEXT[] := ARRAY[
        'stores','products','customers','suppliers','purchases','invoices',
        'sales_returns','customer_payments','supplier_payments','stock_movements',
        'categories','brands','product_units','stock','purchase_items',
        'customer_ledgers','payment_allocations','invoice_items','supplier_ledger',
        'return_items','expenses','revenues','purchase_returns','purchase_return_items',
        'stock_adjustments','inventory_batches','stock_alerts','chart_of_accounts',
        'journal_entries','general_ledger','purchase_receipts','purchase_receipt_items',
        'purchase_closures','purchase_closure_items','purchase_amendments','tombstones'
    ];
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authenticated device session required';
    END IF;
    IF p_store_id IS NULL OR NULLIF(btrim(p_table_name), '') IS NULL
       OR NOT (p_table_name = ANY(v_allowed_tables)) THEN
        RAISE EXCEPTION 'Invalid store or table for Pull';
    END IF;

    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    v_device_id := p_device_id::UUID;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_credential_version
      FROM public.device_credentials dc
     WHERE dc.device_id = v_device_id
       AND dc.store_id = p_store_id
       AND dc.user_id = v_user_id
       AND dc.revoked_at IS NULL;

    IF v_credential_version IS NULL THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    SELECT COALESCE(sc.last_pull_seq, 0)
      INTO v_cursor_after
      FROM (SELECT 1) seed
      LEFT JOIN public.sync_cursors sc
        ON sc.store_id = p_store_id
       AND sc.device_id = p_device_id
       AND sc.table_name = p_table_name;

    -- Select at most 501 visible rows. Hidden rows never affect has_more or the
    -- event count returned to the caller. If <=500 visible rows exist, the
    -- checkpoint advances over the raw hidden tail without exposing its size.
    WITH visible AS MATERIALIZED (
        SELECT cl.record_uuid,
               cl.operation,
               CASE WHEN cl.operation = 'DELETE' THEN cl.old_values_json ELSE cl.new_values_json END AS record_json,
               cl.sync_cursor,
               cl.created_at
          FROM public.change_log cl
         WHERE cl.store_id = p_store_id
           AND cl.table_name = p_table_name
           AND cl.sync_cursor > v_cursor_after
           AND public.can_read_sync_change(
               p_store_id,
               p_table_name,
               cl.operation,
               CASE WHEN cl.operation = 'DELETE' THEN cl.old_values_json ELSE cl.new_values_json END
           )
         ORDER BY cl.sync_cursor ASC
         LIMIT 501
    ),
    page AS MATERIALIZED (
        SELECT * FROM visible
         ORDER BY sync_cursor ASC
         LIMIT 500
    )
    SELECT
        (SELECT COUNT(*)::INTEGER FROM visible),
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'record_uuid', p.record_uuid,
                    'operation', p.operation,
                    'record_json', p.record_json,
                    'sync_cursor', p.sync_cursor,
                    'changed_at', p.created_at
                ) ORDER BY p.sync_cursor
            ) FROM page p
        ), '[]'::JSONB),
        (SELECT MAX(p.sync_cursor) FROM page p),
        (
            SELECT COALESCE(MAX(cl.sync_cursor), v_cursor_after)
              FROM public.change_log cl
             WHERE cl.store_id = p_store_id
               AND cl.table_name = p_table_name
               AND cl.sync_cursor > v_cursor_after
        )
      INTO v_visible_count, v_events, v_page_max, v_raw_max;

    v_has_more := v_visible_count > 500;
    v_event_count := LEAST(v_visible_count, 500);
    v_cursor_through := CASE
        WHEN v_has_more THEN v_page_max
        ELSE v_raw_max
    END;

    -- No visible events: safely checkpoint the invisible range server-side.
    -- The response is indistinguishable from an empty stream; no hidden count,
    -- cursor or record identity is disclosed and no ACK is required.
    IF v_event_count = 0 THEN
        IF v_cursor_through > v_cursor_after THEN
            INSERT INTO public.sync_cursors(
                store_id, device_id, table_name, last_pull_seq, cursor_value
            ) VALUES (
                p_store_id, p_device_id, p_table_name,
                v_cursor_through, v_cursor_through::TEXT
            )
            ON CONFLICT (store_id, device_id, table_name)
            DO UPDATE SET
                last_pull_seq = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq),
                cursor_value = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq)::TEXT,
                updated_at = NOW();
        END IF;

        RETURN jsonb_build_object(
            'delivery_id', NULL,
            'table_name', p_table_name,
            'event_count', 0,
            'has_more', FALSE,
            'events', '[]'::JSONB
        );
    END IF;

    v_page_hash := encode(
        public.atack_digest(
            convert_to(jsonb_build_object(
                'store_id', p_store_id,
                'device_id', v_device_id,
                'table_name', p_table_name,
                'cursor_after', v_cursor_after,
                'cursor_through', v_cursor_through,
                'credential_version', v_credential_version,
                'event_count', v_event_count,
                'has_more', v_has_more,
                'events', v_events
            )::TEXT, 'UTF8'),
            'sha256'
        ),
        'hex'
    );

    INSERT INTO public.sync_delivery_pages(
        store_id, device_id, table_name, cursor_after, cursor_through,
        event_count, has_more, page_hash, credential_version
    ) VALUES (
        p_store_id, v_device_id, p_table_name, v_cursor_after, v_cursor_through,
        v_event_count, v_has_more, v_page_hash, v_credential_version
    )
    ON CONFLICT ON CONSTRAINT uq_sync_delivery_page
    DO UPDATE SET last_issued_at = NOW()
    RETURNING id INTO v_delivery_id;

    RETURN jsonb_build_object(
        'delivery_id', v_delivery_id,
        'table_name', p_table_name,
        'event_count', v_event_count,
        'has_more', v_has_more,
        'page_hash', v_page_hash,
        'events', v_events
    );
END;
$pull_page$;

CREATE OR REPLACE FUNCTION public.acknowledge_sync_cursor(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_delivery_id UUID,
    p_device_token TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $delivery_ack$
DECLARE
    v_device_id UUID;
    v_user_id UUID;
    v_credential_version INTEGER;
    v_page public.sync_delivery_pages%ROWTYPE;
    v_current_cursor BIGINT := 0;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authenticated device session required'; END IF;
    IF p_store_id IS NULL OR p_delivery_id IS NULL OR NULLIF(btrim(p_table_name), '') IS NULL THEN
        RAISE EXCEPTION 'Store, table and delivery ID are required';
    END IF;

    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    v_device_id := p_device_id::UUID;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_credential_version
      FROM public.device_credentials dc
     WHERE dc.device_id = v_device_id
       AND dc.store_id = p_store_id
       AND dc.user_id = v_user_id
       AND dc.revoked_at IS NULL;

    IF v_credential_version IS NULL THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    SELECT dp.*
      INTO v_page
      FROM public.sync_delivery_pages dp
     WHERE dp.id = p_delivery_id
       AND dp.store_id = p_store_id
       AND dp.device_id = v_device_id
       AND dp.table_name = p_table_name
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Delivery page is not registered for this device';
    END IF;
    IF v_page.credential_version <> v_credential_version THEN
        RAISE EXCEPTION 'Delivery page credential version is no longer current';
    END IF;

    IF v_page.acknowledged_at IS NOT NULL THEN
        IF v_page.acknowledged_cursor = v_page.cursor_through THEN
            RETURN TRUE;
        END IF;
        RAISE EXCEPTION 'Delivery page was acknowledged with a different cursor';
    END IF;

    SELECT COALESCE(sc.last_pull_seq, 0)
      INTO v_current_cursor
      FROM (SELECT 1) seed
      LEFT JOIN public.sync_cursors sc
        ON sc.store_id = p_store_id
       AND sc.device_id = p_device_id
       AND sc.table_name = p_table_name;

    IF v_page.cursor_after <> v_current_cursor THEN
        RAISE EXCEPTION 'Delivery page is out of order for this device';
    END IF;
    IF v_page.cursor_through <= v_page.cursor_after
       OR NOT EXISTS (
           SELECT 1 FROM public.change_log cl
            WHERE cl.store_id = p_store_id
              AND cl.table_name = p_table_name
              AND cl.sync_cursor = v_page.cursor_through
       ) THEN
        RAISE EXCEPTION 'Delivery page cursor contract is invalid';
    END IF;

    INSERT INTO public.sync_cursors(
        store_id, device_id, table_name, last_pull_seq, cursor_value
    ) VALUES (
        p_store_id, p_device_id, p_table_name,
        v_page.cursor_through, v_page.cursor_through::TEXT
    )
    ON CONFLICT (store_id, device_id, table_name)
    DO UPDATE SET
        last_pull_seq = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq),
        cursor_value = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq)::TEXT,
        updated_at = NOW();

    UPDATE public.sync_delivery_pages
       SET acknowledged_at = NOW(),
           acknowledged_cursor = v_page.cursor_through
     WHERE id = p_delivery_id;

    RETURN TRUE;
END;
$delivery_ack$;

REVOKE ALL ON FUNCTION public.get_unsynced_records_page(UUID, TEXT, TEXT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, UUID, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_unsynced_records_page(UUID, TEXT, TEXT, TEXT)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, UUID, TEXT)
    TO authenticated;

COMMIT;
