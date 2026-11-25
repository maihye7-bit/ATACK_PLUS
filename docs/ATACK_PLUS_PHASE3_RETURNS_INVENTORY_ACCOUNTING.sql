-- ============================================================
-- ATACK PLUS - Phase 3: Returns, Inventory Management, Accounting
-- Target: Supabase PostgreSQL 15+
-- Requires: POSTGRES_SCHEMA_PHASE1_FIXED.sql and ATACK_PLUS_PHASE2_BUSINESS_RPCS.sql applied first
-- ============================================================

BEGIN;

-- ============================================================
-- 1. PURCHASE RETURNS (مرتجعات المشتريات)
-- ============================================================

-- جدول مرتجعات المشتريات
CREATE TABLE IF NOT EXISTS public.purchase_returns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    return_number TEXT NOT NULL,
    original_purchase_id UUID NOT NULL,
    reason TEXT,
    total_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    refund_method TEXT CHECK(refund_method IN ('CREDIT', 'CASH', 'BANK_TRANSFER', 'MOBILE')),
    notes TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (original_purchase_id) REFERENCES purchases(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_returns_store_number ON purchase_returns(store_id, return_number);
CREATE INDEX IF NOT EXISTS idx_purchase_returns_purchase ON purchase_returns(original_purchase_id);
CREATE INDEX IF NOT EXISTS idx_purchase_returns_created ON purchase_returns(created_at);
CREATE INDEX IF NOT EXISTS idx_purchase_returns_synced ON purchase_returns(is_synced);

-- بنود المرتجع
CREATE TABLE IF NOT EXISTS purchase_return_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    quantity_unit_id TEXT NOT NULL,
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (return_id) REFERENCES purchase_returns(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (quantity_unit_id) REFERENCES units(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_purchase_return_items_return ON purchase_return_items(return_id);
CREATE INDEX IF NOT EXISTS idx_purchase_return_items_product ON purchase_return_items(product_id);

-- ============================================================
-- 2. STOCK ADJUSTMENTS (تسويات المخزون)
-- ============================================================

-- جدول التسويات
CREATE TABLE IF NOT EXISTS public.stock_adjustments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    adjustment_number TEXT NOT NULL,
    product_id UUID NOT NULL,
    adjustment_type TEXT NOT NULL CHECK(adjustment_type IN ('INCREASE', 'DECREASE')),
    reason TEXT NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    unit_id TEXT NOT NULL,
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    total_value NUMERIC(18,4) NOT NULL CHECK(total_value >= 0),
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (unit_id) REFERENCES units(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_stock_adjustments_store_number ON stock_adjustments(store_id, adjustment_number);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_product ON stock_adjustments(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_created ON stock_adjustments(created_at);

-- ============================================================
-- 3. PROCUREMENT/BATCH/LOT TRACKING (تتبع الدفعات)
-- ============================================================

-- جدول الدفعات
CREATE TABLE IF NOT EXISTS public.inventory_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    product_id UUID NOT NULL,
    batch_number TEXT NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity >= 0),
    reserved_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(reserved_quantity >= 0 AND reserved_quantity <= quantity),
    available_quantity NUMERIC(18,4) GENERATED ALWAYS AS (quantity - reserved_quantity) STORED,
    expiry_date TIMESTAMPTZ,
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (product_id) REFERENCES products(id),
    UNIQUE(store_id, product_id, batch_number)
);

CREATE INDEX IF NOT EXISTS idx_inventory_batches_product ON inventory_batches(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_batches_expiry ON inventory_batches(expiry_date) WHERE expiry_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_batches_batch ON inventory_batches(batch_number);

-- جدول تحذيرات انخفاض المخزون
CREATE TABLE IF NOT EXISTS public.stock_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    product_id UUID NOT NULL,
    alert_type TEXT NOT NULL CHECK(alert_type IN ('LOW_STOCK', 'EXPIRY_SOON')),
    current_quantity NUMERIC(18,4) NOT NULL,
    threshold NUMERIC(18,4) NOT NULL,
    message TEXT NOT NULL,
    is_acknowledged BOOLEAN DEFAULT FALSE,
    acknowledged_by UUID,
    acknowledged_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (acknowledged_by) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_stock_alerts_product ON stock_alerts(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_alerts_type ON stock_alerts(alert_type);
CREATE INDEX IF NOT EXISTS idx_stock_alerts_unacked ON stock_alerts(is_acknowledged) WHERE is_acknowledged = FALSE;

-- ============================================================
-- 4. GENERAL LEDGER & CHART OF ACCOUNTS (دفتر الأستاذ العام)
-- ============================================================

-- دليل حسابات
CREATE TABLE IF NOT EXISTS public.chart_of_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    account_code TEXT NOT NULL,
    account_name TEXT NOT NULL,
    account_type TEXT NOT NULL CHECK(account_type IN (
        'ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE',
        'CURRENT_ASSET', 'CURRENT_LIABILITY', 'COST_OF_GOODS_SOLD', 'INCOME'
    )),
    parent_id UUID,
    is_active BOOLEAN DEFAULT TRUE,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (parent_id) REFERENCES chart_of_accounts(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chart_accounts_store_code ON chart_of_accounts(store_id, account_code);
CREATE INDEX IF NOT EXISTS idx_chart_accounts_type ON chart_of_accounts(account_type);

-- دفتر الأستاذ العام (General Ledger Entries - Double Entry)
CREATE TABLE IF NOT EXISTS public.general_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    journal_entry_id UUID NOT NULL,  -- ربط بـ journal_entries
    account_id UUID NOT NULL,
    entry_type TEXT NOT NULL CHECK(entry_type IN ('DEBIT', 'CREDIT')),
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    currency TEXT NOT NULL DEFAULT 'DZD',
    description TEXT,
    reference_id UUID,  -- معرف الفاتلة أو العملية المرتبطة
    reference_table TEXT,
    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (account_id) REFERENCES chart_of_accounts(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_general_ledger_account ON general_ledger(account_id);
CREATE INDEX IF NOT EXISTS idx_general_ledger_journal ON general_ledger(journal_entry_id);
CREATE INDEX IF NOT EXISTS idx_general_ledger_reference ON general_ledger(reference_table, reference_id);

-- جدول كران الأستاذ (Journal Entries)
CREATE TABLE IF NOT EXISTS public.journal_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    entry_number TEXT NOT NULL,
    entry_date TIMESTAMPTZ NOT NULL,
    description TEXT,
    source_type TEXT CHECK(source_type IN ('SALE', 'PURCHASE', 'RETURN', 'PAYMENT', 'EXPENSE', 'REVENUE', 'ADJUSTMENT', 'TRANSFER')),
    source_id UUID,  -- ID of the related business record
    total_debit NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_credit NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_posted BOOLEAN DEFAULT TRUE,
    posted_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (posted_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_entries_store_number ON journal_entries(store_id, entry_number);
CREATE INDEX IF NOT EXISTS idx_journal_entries_date ON journal_entries(entry_date);

-- ============================================================
-- 5. FINANCIAL REPORTS VIEW
-- ============================================================

-- كشف حساب (Trial Balance View)
CREATE OR REPLACE VIEW public.v_trial_balance AS
SELECT
    coa.account_code,
    coa.account_name,
    coa.account_type,
    COALESCE(SUM(CASE WHEN gl.entry_type = 'DEBIT' THEN gl.amount ELSE 0 END), 0) AS total_debit,
    COALESCE(SUM(CASE WHEN gl.entry_type = 'CREDIT' THEN gl.amount ELSE 0 END), 0) AS total_credit,
    COALESCE(
        SUM(CASE WHEN gl.entry_type = 'DEBIT' THEN gl.amount ELSE 0 END) -
        SUM(CASE WHEN gl.entry_type = 'CREDIT' THEN gl.amount ELSE 0 END),
        0
    ) AS balance
FROM chart_of_accounts coa
LEFT JOIN general_ledger gl ON gl.account_id = coa.id AND coa.is_active = TRUE
WHERE coa.is_active = TRUE
GROUP BY coa.id, coa.account_code, coa.account_name, coa.account_type
ORDER BY coa.account_code;

-- ميزان المراجعة (Balance Sheet View)
CREATE OR REPLACE VIEW public.v_balance_sheet AS
SELECT
    coa.account_code,
    coa.account_name,
    coa.account_type,
    COALESCE(SUM(CASE WHEN gl.entry_type = 'DEBIT' THEN gl.amount ELSE 0 END) -
             SUM(CASE WHEN gl.entry_type = 'CREDIT' THEN gl.amount ELSE 0 END), 0) AS balance
FROM chart_of_accounts coa
LEFT JOIN general_ledger gl ON gl.account_id = coa.id
WHERE coa.account_type IN ('ASSET', 'LIABILITY', 'EQUITY', 'CURRENT_ASSET', 'CURRENT_LIABILITY')
GROUP BY coa.id, coa.account_code, coa.account_name, coa.account_type
HAVING COALESCE(SUM(CASE WHEN gl.entry_type = 'DEBIT' THEN gl.amount ELSE 0 END) -
                SUM(CASE WHEN gl.entry_type = 'CREDIT' THEN gl.amount ELSE 0 END), 0) <> 0
ORDER BY coa.account_code;

-- قائمة الدخل والخسائر (Income Statement View)
CREATE OR REPLACE VIEW public.v_income_statement AS
SELECT
    coa.account_code,
    coa.account_name,
    coa.account_type,
    COALESCE(SUM(CASE WHEN gl.entry_type = 'DEBIT' THEN gl.amount ELSE 0 END) -
             SUM(CASE WHEN gl.entry_type = 'CREDIT' THEN gl.amount ELSE 0 END), 0) AS balance
FROM chart_of_accounts coa
LEFT JOIN general_ledger gl ON gl.account_id = coa.id
WHERE coa.account_type IN ('REVENUE', 'EXPENSE', 'COST_OF_GOODS_SOLD', 'INCOME')
GROUP BY coa.id, coa.account_code, coa.account_name, coa.account_type
HAVING COALESCE(SUM(CASE WHEN gl.entry_type = 'DEBIT' THEN gl.amount ELSE 0 END) -
                SUM(CASE WHEN gl.entry_type = 'CREDIT' THEN gl.amount ELSE 0 END), 0) <> 0
ORDER BY coa.account_code;

-- ============================================================
-- 6. SUPPLIER PURCHASE RETURNS RPC (مرتجع المشتريات)
-- ============================================================

CREATE OR REPLACE FUNCTION public.process_purchase_return(
    p_store_id UUID,
    p_operation_id UUID,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
DECLARE
    v_user UUID;
    v_replay BOOLEAN;
    v_return_id UUID := (p_payload->>'id')::UUID;
    v_purchase_id UUID := NULLIF(p_payload->>'purchase_id','')::UUID;
    v_total NUMERIC(18,4) := 0;
    v_refund_method TEXT := COALESCE(p_payload->>'refund_method', 'CREDIT');
    v_return_number TEXT := NULLIF(btrim(p_payload->>'return_number'), '');
    v_reason TEXT := p_payload->>'reason';
    v_created_by UUID;
    v_item JSONB;
    v_product_id UUID;
    v_qty NUMERIC(18,4);
    v_unit_price NUMERIC(18,4);
    v_line_total NUMERIC(18,4);
    v_line_qty NUMERIC(18,4);
    v_remaining_qty NUMERIC(18,4);
    v_original_qty NUMERIC(18,4);
    v_stock_id UUID;
    v_cost_per_unit NUMERIC(18,4);
    v_factor NUMERIC(18,6);
    v_unit TEXT;
    v_available_qty NUMERIC(18,4);
BEGIN
    -- Authentication and authorization
    SELECT u.id INTO v_user FROM public.users u
    WHERE u.auth_user_id = auth.uid()
      AND u.store_id = p_store_id
      AND u.is_active = TRUE;

    IF v_user IS NULL THEN
        RAISE EXCEPTION 'User is not an active member of this store' USING ERRCODE = '42501';
    END IF;

    IF NOT public.has_store_permission(p_store_id, 'purchases.return') THEN
        RAISE EXCEPTION 'Missing permission: purchases.return' USING ERRCODE = '42501';
    END IF;

    -- Idempotency check
    SELECT c.app_user_id, c.already_processed INTO v_created_by, v_replay
    FROM public._claim_business_operation(p_store_id, p_operation_id, 'purchase_return', v_return_id, p_payload, 'purchases.return') c;

    IF v_replay THEN
        RETURN jsonb_build_object('success', TRUE, 'replayed', TRUE, 'return_id', v_return_id);
    END IF;

    -- Validate purchase exists
    IF v_purchase_id IS NULL THEN
        RAISE EXCEPTION 'Original purchase ID is required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM purchases WHERE id = v_purchase_id AND store_id = p_store_id) THEN
        RAISE EXCEPTION 'Original purchase not found or does not belong to this store';
    END IF;

    -- Create the purchase return
    INSERT INTO purchase_returns(
        id, store_id, return_number, original_purchase_id, reason,
        refund_method, total_amount, created_by
    ) VALUES(
        v_return_id, p_store_id, v_return_number, v_purchase_id, v_reason,
        v_refund_method, 0, v_created_by
    ) RETURNING total_amount INTO v_total;

    -- Process return items
    IF COALESCE(jsonb_typeof(p_payload->'items'), '') <> 'array' THEN
        RAISE EXCEPTION 'Return items must be a JSON array';
    END IF;

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') AS e(value) LOOP
        v_product_id := (v_item->>'product_id')::UUID;
        v_qty := (v_item->>'quantity')::NUMERIC;
        v_unit := v_item->>'unit_id';
        v_unit_price := COALESCE(NULLIF(v_item->>'unit_price','')::NUMERIC, 0);

        IF v_qty <= 0 OR v_unit_price < 0 THEN
            RAISE EXCEPTION 'Invalid return item quantity or price';
        END IF;

        -- Validate product belongs to store
        IF NOT EXISTS (SELECT 1 FROM products WHERE id = v_product_id AND store_id = p_store_id AND is_active) THEN
            RAISE EXCEPTION 'Product does not belong to this store or is inactive';
        END IF;

        -- Get unit conversion factor
        SELECT CASE WHEN v_unit = p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
          INTO v_factor FROM products p LEFT JOIN product_units pu
            ON pu.product_id = p.id AND pu.unit_id = v_unit
         WHERE p.id = v_product_id AND p.store_id = p_store_id;

        IF v_factor IS NULL OR v_factor <= 0 THEN
            RAISE EXCEPTION 'Unit is not configured for product';
        END IF;

        v_line_qty := v_qty * v_factor;
        v_line_total := v_line_qty * v_unit_price;
        v_total := v_total + v_line_total;

        -- Check available quantity in stock (must have been received)
        SELECT COALESCE((SELECT quantity FROM stock s JOIN purchase_items pi ON pi.id = ANY(
            SELECT id FROM purchase_items WHERE purchase_id = v_purchase_id AND product_id = v_product_id
        )) - (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements sm
              WHERE sm.product_id = v_product_id AND sm.type = 'OUT'), 0) INTO v_available_qty;

        IF v_available_qty < v_line_qty THEN
            RAISE EXCEPTION 'Insufficient stock available for product % to return', v_product_id;
        END IF;

        -- Insert return item
        INSERT INTO purchase_return_items(
            return_id, product_id, quantity, quantity_unit_id, unit_price, line_total,
            batch_number, expiry_date
        ) VALUES(
            v_return_id, v_product_id, v_qty, v_unit, v_unit_price, v_line_total,
            NULLIF(v_item->>'batch_number',''), NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ
        );

        -- Get stock movement info for refund
        SELECT s.id INTO v_stock_id FROM stock s
        WHERE s.product_id = v_product_id AND s.location_id = 'main';

        SELECT p.cost_price INTO v_cost_per_unit FROM products p
        WHERE p.id = v_product_id AND p.store_id = p_store_id;

        -- Create reverse stock movement (RETURN_OUT for purchase)
        INSERT INTO stock_movements(
            product_id, location_id, type, quantity, unit_id,
            cost_per_unit, total_value, reference_id, reference_type,
            batch_number, expiry_date, reason, user_id
        ) VALUES(
            v_product_id, 'main', 'RETURN_OUT', v_line_qty, v_unit,
            v_cost_per_unit / v_factor, v_line_qty * v_cost_per_unit / v_factor,
            v_return_id, 'purchase_return',
            NULLIF(v_item->>'batch_number',''), NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,
            'Purchase return ' || v_return_number, v_created_by
        );

        -- Reduce stock
        UPDATE stock SET quantity = quantity - v_line_qty WHERE id = v_stock_id;
    END LOOP;

    -- Update return total
    UPDATE purchase_returns SET total_amount = v_total WHERE id = v_return_id;

    -- Create supplier ledger entry for refund (negative for credit, positive for cash refund)
    IF v_refund_method = 'CREDIT' THEN
        INSERT INTO supplier_ledger(
            supplier_id, type, amount, balance, reference_id, description, created_by
        ) SELECT
            p.supplier_id, 'RETURN', -v_total, s.current_debt - v_total, v_return_id,
            'Purchase return ' || v_return_number, v_created_by
        FROM purchases p JOIN suppliers s ON s.id = p.supplier_id
        WHERE p.id = v_purchase_id AND p.store_id = p_store_id;

        UPDATE suppliers SET current_debt = current_debt - v_total
        WHERE id = (SELECT supplier_id FROM purchases WHERE id = v_purchase_id);
    ELSE
        -- Cash/Bank refund - create a payment entry
        INSERT INTO supplier_payments(
            id, supplier_id, amount, payment_method, reference_no, notes, created_by
        ) SELECT
            gen_random_uuid(), p.supplier_id, v_total, v_refund_method, p_payload->>'reference_no',
            'Refund for purchase return ' || v_return_number, v_created_by
        FROM purchases p WHERE p.id = v_purchase_id AND p.store_id = p_store_id;

        INSERT INTO supplier_ledger(
            supplier_id, type, amount, balance, reference_id, description, created_by
        ) SELECT
            p.supplier_id, 'PAYMENT', -v_total, s.current_debt - v_total, gen_last_oid(),
            'Refund for purchase return ' || v_return_number, v_created_by
        FROM purchases p JOIN suppliers s ON s.id = p.supplier_id
        WHERE p.id = v_purchase_id AND p.store_id = p_store_id;

        UPDATE suppliers SET current_debt = current_debt - v_total
        WHERE id = (SELECT supplier_id FROM purchases WHERE id = v_purchase_id);
    END IF;

    RETURN jsonb_build_object(
        'success', TRUE,
        'replayed', FALSE,
        'return_id', v_return_id,
        'total_amount', v_total
    );
END;
$$;

-- ============================================================
-- 7. SALES RETURNS RPC (مرتجعات المبيعات)
-- ============================================================

CREATE OR REPLACE FUNCTION public.process_sale_return(
    p_store_id UUID,
    p_operation_id UUID,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
DECLARE
    v_user UUID;
    v_replay BOOLEAN;
    v_return_id UUID := (p_payload->>'id')::UUID;
    v_invoice_id UUID := NULLIF(p_payload->>'invoice_id','')::UUID;
    v_total NUMERIC(18,4) := 0;
    v_refund_method TEXT := COALESCE(p_payload->>'refund_method', 'CREDIT');
    v_return_number TEXT := NULLIF(btrim(p_payload->>'return_number'), '');
    v_reason TEXT := p_payload->>'reason';
    v_created_by UUID;
    v_item JSONB;
    v_product_id UUID;
    v_qty NUMERIC(18,4);
    v_unit_price NUMERIC(18,4);
    v_line_total NUMERIC(18,4);
    v_line_qty NUMERIC(18,4);
    v_stock_id UUID;
    v_factor NUMERIC(18,6);
    v_unit TEXT;
    v_return_condition TEXT := COALESCE(p_payload->>'return_condition', 'GOOD');
    v_available_qty NUMERIC(18,4);
    v_customer_id UUID;
    v_customer_debt NUMERIC(18,4);
BEGIN
    -- Authentication and authorization
    SELECT u.id INTO v_user FROM public.users u
    WHERE u.auth_user_id = auth.uid()
      AND u.store_id = p_store_id
      AND u.is_active = TRUE;

    IF v_user IS NULL THEN
        RAISE EXCEPTION 'User is not an active member of this store' USING ERRCODE = '42501';
    END IF;

    IF NOT public.has_store_permission(p_store_id, 'sales.write') THEN
        RAISE EXCEPTION 'Missing permission: sales.write' USING ERRCODE = '42501';
    END IF;

    -- Idempotency check
    SELECT c.app_user_id, c.already_processed INTO v_created_by, v_replay
    FROM public._claim_business_operation(p_store_id, p_operation_id, 'sale_return', v_return_id, p_payload, 'sales.write') c;

    IF v_replay THEN
        RETURN jsonb_build_object('success', TRUE, 'replayed', TRUE, 'return_id', v_return_id);
    END IF;

    -- Validate original invoice exists and belongs to store
    IF v_invoice_id IS NULL THEN
        RAISE EXCEPTION 'Original invoice ID is required';
    END IF;

    SELECT i.customer_id, i.total_amount, i.paid_amount INTO v_customer_id, v_total, v_customer_debt
    FROM invoices i
    WHERE i.id = v_invoice_id AND i.store_id = p_store_id AND i.type = 'SALE' AND i.status != 'CANCELLED';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Original sale invoice not found or not valid for return';
    END IF;

    -- Create the sale return
    INSERT INTO sales_returns(
        id, store_id, return_number, original_invoice_id, reason,
        refund_method, total_amount, created_by
    ) VALUES(
        v_return_id, p_store_id, v_return_number, v_invoice_id, v_reason,
        v_refund_method, 0, v_created_by
    ) RETURNING total_amount INTO v_total;

    -- Process return items
    IF COALESCE(jsonb_typeof(p_payload->'items'), '') <> 'array' THEN
        RAISE EXCEPTION 'Return items must be a JSON array';
    END IF;

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') AS e(value) LOOP
        v_product_id := (v_item->>'product_id')::UUID;
        v_qty := (v_item->>'quantity')::NUMERIC;
        v_unit := v_item->>'unit_id';

        IF v_qty <= 0 THEN
            RAISE EXCEPTION 'Invalid return quantity';
        END IF;

        -- Validate product belongs to store
        IF NOT EXISTS (SELECT 1 FROM products WHERE id = v_product_id AND store_id = p_store_id AND is_active) THEN
            RAISE EXCEPTION 'Product does not belong to this store or is inactive';
        END IF;

        -- Get unit conversion factor
        SELECT CASE WHEN v_unit = p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
          INTO v_factor FROM products p LEFT JOIN product_units pu
            ON pu.product_id = p.id AND pu.unit_id = v_unit
         WHERE p.id = v_product_id AND p.store_id = p_store_id;

        IF v_factor IS NULL OR v_factor <= 0 THEN
            RAISE EXCEPTION 'Unit is not configured for product';
        END IF;

        v_line_qty := v_qty * v_factor;
        v_line_total := COALESCE(NULLIF(v_item->>'unit_price','')::NUMERIC, 0) * v_line_qty;

        -- Check available inventory (from original sale)
        SELECT COALESCE((SELECT quantity FROM stock s WHERE s.product_id = v_product_id), 0) INTO v_available_qty;

        IF v_return_condition = 'DEFECTIVE' OR v_return_condition = 'UNSALEABLE' THEN
            -- For defective/unusable items, we just record the return, no stock restoration
            NULL;
        ELSIF v_available_qty < v_line_qty THEN
            RAISE EXCEPTION 'Insufficient stock available for product % to return', v_product_id;
        END IF;

        v_total := v_total + v_line_total;

        -- Insert return item
        INSERT INTO return_items(
            return_id, product_id, quantity, unit_price, line_total,
            batch_number, expiry_date
        ) VALUES(
            v_return_id, v_product_id, v_qty,
            COALESCE(NULLIF(v_item->>'unit_price','')::NUMERIC, 0), v_line_total,
            NULLIF(v_item->>'batch_number',''), NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ
        );

        -- Only add stock back if items are good condition
        IF v_return_condition = 'GOOD' THEN
            SELECT s.id INTO v_stock_id FROM stock s
            WHERE s.product_id = v_product_id AND s.location_id = 'main';

            -- Create stock movement for return
            INSERT INTO stock_movements(
                product_id, location_id, type, quantity, unit_id,
                cost_per_unit, total_value, reference_id, reference_type,
                batch_number, expiry_date, reason, user_id
            ) VALUES(
                v_product_id, 'main', 'RETURN_IN', v_line_qty, v_unit,
                COALESCE(NULLIF(v_item->>'cost_per_unit','')::NUMERIC, 0),
                v_line_qty * COALESCE(NULLIF(v_item->>'cost_per_unit','')::NUMERIC, 0),
                v_return_id, 'return',
                NULLIF(v_item->>'batch_number',''), NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,
                'Sale return ' || v_return_number, v_created_by
            );

            -- Increase stock
            UPDATE stock SET quantity = quantity + v_line_qty WHERE id = v_stock_id;
        END IF;
    END LOOP;

    -- Update return total
    UPDATE sales_returns SET total_amount = v_total WHERE id = v_return_id;

    -- Handle customer refund
    IF v_customer_id IS NOT NULL THEN
        -- Create return ledger entry
        INSERT INTO customer_ledgers(
            customer_id, type, amount, balance, reference_id, description, created_by
        ) SELECT
            v_customer_id, 'RETURN', v_total, current_debt - v_total, v_return_id,
            'Sale return ' || v_return_number, v_created_by
        FROM customers
        WHERE id = v_customer_id AND store_id = p_store_id;

        -- Update customer debt
        UPDATE customers SET current_debt = current_debt - v_total
        WHERE id = v_customer_id AND store_id = p_store_id;

        -- Handle refund method
        IF v_refund_method = 'CREDIT' THEN
            -- Keep as credit, customer can use later
            NULL;  -- Already handled in ledger above
        ELSE
            -- CASH/CARD/BANK_TRANSFER refund
            INSERT INTO customer_payments(
                id, customer_id, amount, payment_method, notes, created_by
            ) VALUES(
                gen_random_uuid(), v_customer_id, v_total, v_refund_method,
                'Refund for sale return ' || v_return_number, v_created_by
            );
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', TRUE,
        'replayed', FALSE,
        'return_id', v_return_id,
        'total_amount', v_total
    );
END;
$$;

-- ============================================================
-- 8. STOCK ADJUSTMENT RPC
-- ============================================================

CREATE OR REPLACE FUNCTION public.process_stock_adjustment(
    p_store_id UUID,
    p_operation_id UUID,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
DECLARE
    v_user UUID;
    v_replay BOOLEAN;
    v_adjustment_id UUID := (p_payload->>'id')::UUID;
    v_product_id UUID := (p_payload->>'product_id')::UUID;
    v_adjustment_type TEXT := p_payload->>'adjustment_type';
    v_reason TEXT := p_payload->>'reason';
    v_quantity NUMERIC(18,4) := (p_payload->>'quantity')::NUMERIC;
    v_unit TEXT := p_payload->>'unit_id';
    v_cost_per_unit NUMERIC(18,4) := COALESCE(NULLIF(p_payload->>'cost_per_unit','')::NUMERIC, 0);
    v_line_qty NUMERIC(18,4);
    v_factor NUMERIC(18,6);
    v_line_total NUMERIC(18,4);
    v_stock_id UUID;
    v_adjustment_number TEXT := (p_payload->>'adjustment_number')::TEXT;
    v_refund_method TEXT := COALESCE(p_payload->>'refund_method', 'CREDIT');
BEGIN
    -- Authentication and authorization
    SELECT u.id INTO v_user FROM public.users u
    WHERE u.auth_user_id = auth.uid()
      AND u.store_id = p_store_id
      AND u.is_active = TRUE;

    IF v_user IS NULL THEN
        RAISE EXCEPTION 'User is not an active member of this store' USING ERRCODE = '42501';
    END IF;

    IF NOT public.has_store_permission(p_store_id, 'inventory.write') THEN
        RAISE EXCEPTION 'Missing permission: inventory.write' USING ERRCODE = '42501';
    END IF;

    -- Idempotency check
    SELECT c.app_user_id, c.already_processed INTO v_user, v_replay
    FROM public._claim_business_operation(p_store_id, p_operation_id, 'stock_adjustment', v_adjustment_id, p_payload, 'inventory.write') c;

    IF v_replay THEN
        RETURN jsonb_build_object('success', TRUE, 'replayed', TRUE, 'adjustment_id', v_adjustment_id);
    END IF;

    -- Validate adjustment type
    IF v_adjustment_type NOT IN ('INCREASE', 'DECREASE') THEN
        RAISE EXCEPTION 'Invalid adjustment type: %', v_adjustment_type;
    END IF;

    -- Validate reason is required
    IF v_reason IS NULL OR trim(v_reason) = '' THEN
        RAISE EXCEPTION 'Reason for adjustment is required';
    END IF;

    -- Validate quantity
    IF v_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- Validate product belongs to store
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = v_product_id AND store_id = p_store_id AND is_active) THEN
        RAISE EXCEPTION 'Product does not belong to this store or is inactive';
    END IF;

    -- Get unit conversion factor
    SELECT CASE WHEN v_unit = p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
      INTO v_factor FROM products p LEFT JOIN product_units pu
        ON pu.product_id = p.id AND pu.unit_id = v_unit
     WHERE p.id = v_product_id AND p.store_id = p_store_id;

    IF v_factor IS NULL OR v_factor <= 0 THEN
        RAISE EXCEPTION 'Unit is not configured for product';
    END IF;

    v_line_qty := v_quantity * v_factor;
    v_line_total := v_line_qty * v_cost_per_unit;

    -- Get or create stock record
    INSERT INTO stock(product_id, location_id, quantity, reserved_quantity)
    VALUES(v_product_id, 'main', 0, 0) ON CONFLICT(product_id, location_id) DO NOTHING;

    SELECT id INTO v_stock_id FROM stock WHERE product_id = v_product_id AND location_id = 'main';

    -- Check for negative stock if decreasing
    IF v_adjustment_type = 'DECREASE' THEN
        IF (SELECT quantity FROM stock WHERE id = v_stock_id) < v_line_qty THEN
            RAISE EXCEPTION 'Cannot decrease stock below zero';
        END IF;
    END IF;

    -- Create adjustment record
    INSERT INTO stock_adjustments(
        id, store_id, adjustment_number, product_id, adjustment_type,
        reason, quantity, unit_id, cost_per_unit, total_value,
        created_by
    ) VALUES(
        v_adjustment_id, p_store_id, v_adjustment_number, v_product_id, v_adjustment_type,
        v_reason, v_quantity, v_unit, v_cost_per_unit, v_line_total,
        v_user
    );

    -- Update stock
    IF v_adjustment_type = 'INCREASE' THEN
        UPDATE stock SET quantity = quantity + v_line_qty WHERE id = v_stock_id;
    ELSE
        UPDATE stock SET quantity = quantity - v_line_qty WHERE id = v_stock_id;
    END IF;

    -- Create stock movement
    INSERT INTO stock_movements(
        product_id, location_id, type, quantity, unit_id,
        cost_per_unit, total_value, reference_id, reference_type,
        reason, user_id
    ) VALUES(
        v_product_id, 'main', 'ADJUSTMENT', v_line_qty, v_unit,
        v_cost_per_unit, v_line_total, v_adjustment_id, 'adjustment',
        'Stock adjustment: ' || v_reason, v_user
    );

    -- Create journal entry for accounting
    INSERT INTO journal_entries(
        id, store_id, entry_number, entry_date, description, source_type, source_id,
        total_debit, total_credit, posted_by
    ) VALUES(
        gen_random_uuid(), p_store_id,
        'ADJ-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(floor(random()*10000)::text, 5, '0'),
        NOW(), 'Stock adjustment: ' || v_reason, 'ADJUSTMENT', v_adjustment_id,
        CASE WHEN v_adjustment_type = 'INCREASE' THEN v_line_total ELSE 0 END,
        CASE WHEN v_adjustment_type = 'INCREASE' THEN 0 ELSE v_line_total END,
        v_user
    );

    -- Create ledger entries
    INSERT INTO general_ledger(
        store_id, journal_entry_id, account_id, entry_type, amount,
        description, reference_id, reference_table, created_by
    )
    SELECT
        p_store_id, je.id, coa.id,
        CASE WHEN 'INCREASE' = 'INCREASE' THEN 'CREDIT' ELSE 'DEBIT' END,
        v_line_total,
        'Stock adjustment for ' || p.product_id, v_adjustment_id, 'ADJUSTMENT', v_user
    FROM journal_entries je
    JOIN products p ON p.id = v_product_id
    JOIN chart_of_accounts coa ON coa.account_code = '1200'  -- Inventory account
    WHERE je.source_id = v_adjustment_id AND je.store_id = p_store_id;

    RETURN jsonb_build_object(
        'success', TRUE,
        'replayed', FALSE,
        'adjustment_id', v_adjustment_id
    );
END;
$$;

-- ============================================================
-- 9. INVENTORY BATCH/EXPIRY FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_inventory_expiry(
    p_store_id UUID
) RETURNS TABLE(
    product_id UUID,
    product_name TEXT,
    batch_number TEXT,
    expiry_date TIMESTAMPTZ,
    quantity NUMERIC(18,4)
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
BEGIN
    IF NOT public.has_store_permission(p_store_id, 'reports.view') THEN
        RAISE EXCEPTION 'Permission denied' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        i.product_id,
        p.name as product_name,
        i.batch_number,
        i.expiry_date,
        i.quantity
    FROM inventory_batches i
    JOIN products p ON p.id = i.product_id
    WHERE i.store_id = p_store_id
      AND i.expiry_date IS NOT NULL
      AND i.expiry_date <= NOW() + INTERVAL '30 days'
      AND i.quantity > 0
    ORDER BY i.expiry_date ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_low_stock(
    p_store_id UUID
) RETURNS TABLE(
    product_id UUID,
    product_name TEXT,
    quantity NUMERIC(18,4),
    minimum_stock NUMERIC(18,4)
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
BEGIN
    IF NOT public.has_store_permission(p_store_id, 'reports.view') THEN
        RAISE EXCEPTION 'Permission denied' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        s.product_id,
        p.name as product_name,
        (s.quantity - s.reserved_quantity) as quantity,
        p.minimum_stock
    FROM stock s
    JOIN products p ON p.id = s.product_id
    WHERE p.store_id = p_store_id
      AND (s.quantity - s.reserved_quantity) <= p.minimum_stock
      AND p.is_active = TRUE
    ORDER BY p.name;
END;
$$;

-- ============================================================
-- 10. REVOKE direct access, GRANT RPC access
-- ============================================================

-- Sales Returns
REVOKE ALL ON FUNCTION public.process_sale_return(UUID, UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_sale_return(UUID, UUID, JSONB) TO authenticated;

-- Purchase Returns
REVOKE ALL ON FUNCTION public.process_purchase_return(UUID, UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_return(UUID, UUID, JSONB) TO authenticated;

-- Stock Adjustment
REVOKE ALL ON FUNCTION public.process_stock_adjustment(UUID, UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_stock_adjustment(UUID, UUID, JSONB) TO authenticated;

-- Reports
REVOKE ALL ON FUNCTION public.check_inventory_expiry(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_inventory_expiry(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.check_low_stock(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_low_stock(UUID) TO authenticated;

-- ============================================================
-- 11. RLS Policies for new tables
-- ============================================================

-- Sales returns RLS
ALTER TABLE purchase_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE general_ledger ENABLE ROW LEVEL SECURITY;

-- Store isolation policies for new tables
CREATE POLICY purchase_returns_store_isolation ON purchase_returns
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY purchase_return_items_store_isolation ON purchase_return_items
    FOR ALL USING (EXISTS (SELECT 1 FROM purchase_returns pr WHERE pr.id = return_id AND pr.store_id = public.current_user_store_id()));

CREATE POLICY stock_adjustments_store_isolation ON stock_adjustments
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY inventory_batches_store_isolation ON inventory_batches
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY stock_alerts_store_isolation ON stock_alerts
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY chart_of_accounts_store_isolation ON chart_of_accounts
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY journal_entries_store_isolation ON journal_entries
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY general_ledger_store_isolation ON general_ledger
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

-- ============================================================
-- 12. Cross-store validation triggers
-- ============================================================

-- Validation function for store references
CREATE OR REPLACE FUNCTION public.validate_purchase_return_same_store()
RETURNS TRIGGER AS $$
DECLARE
    v_purchase_store UUID;
BEGIN
    SELECT p.store_id INTO v_purchase_store FROM purchases p WHERE p.id = NEW.original_purchase_id;
    IF v_purchase_store IS DISTINCT FROM NEW.store_id THEN
        RAISE EXCEPTION 'Purchase return must reference a purchase from the same store';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_returns_same_store
    BEFORE INSERT OR UPDATE ON purchase_returns
    FOR EACH ROW EXECUTE FUNCTION public.validate_purchase_return_same_store();

-- ============================================================
-- 13. Audit logging triggers for new tables
-- ============================================================

-- Resolve return-item ownership through the correct parent table.
-- Phase 1's generic return_id branch is sales-specific; purchase returns use
-- purchase_returns -> purchases and must not be resolved through sales_returns.
CREATE OR REPLACE FUNCTION public.trg_log_change()
RETURNS TRIGGER AS $log_change$
DECLARE
    v_row JSONB;
    v_store_id UUID;
    v_record_id UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_row := to_jsonb(OLD);
    ELSE
        v_row := to_jsonb(NEW);
    END IF;

    IF TG_TABLE_NAME = 'stores' THEN
        v_store_id := (v_row->>'id')::UUID;
    ELSIF v_row ? 'store_id' THEN
        v_store_id := (v_row->>'store_id')::UUID;
    ELSIF v_row ? 'invoice_id' THEN
        SELECT store_id INTO v_store_id FROM public.invoices
        WHERE id = (v_row->>'invoice_id')::UUID;
    ELSIF v_row ? 'purchase_id' THEN
        SELECT store_id INTO v_store_id FROM public.purchases
        WHERE id = (v_row->>'purchase_id')::UUID;
    ELSIF v_row ? 'customer_id' THEN
        SELECT store_id INTO v_store_id FROM public.customers
        WHERE id = (v_row->>'customer_id')::UUID;
    ELSIF v_row ? 'supplier_id' THEN
        SELECT store_id INTO v_store_id FROM public.suppliers
        WHERE id = (v_row->>'supplier_id')::UUID;
    ELSIF v_row ? 'original_invoice_id' THEN
        SELECT store_id INTO v_store_id FROM public.invoices
        WHERE id = (v_row->>'original_invoice_id')::UUID;
    ELSIF TG_TABLE_NAME = 'purchase_return_items' AND v_row ? 'return_id' THEN
        SELECT p.store_id INTO v_store_id
        FROM public.purchase_returns pr
        JOIN public.purchases p ON p.id = pr.original_purchase_id
        WHERE pr.id = (v_row->>'return_id')::UUID;
    ELSIF TG_TABLE_NAME = 'return_items' AND v_row ? 'return_id' THEN
        SELECT i.store_id INTO v_store_id
        FROM public.sales_returns r
        JOIN public.invoices i ON i.id = r.original_invoice_id
        WHERE r.id = (v_row->>'return_id')::UUID;
    ELSIF v_row ? 'product_id' THEN
        SELECT store_id INTO v_store_id FROM public.products
        WHERE id = (v_row->>'product_id')::UUID;
    ELSE
        RAISE EXCEPTION 'Cannot resolve store_id for change-log table %', TG_TABLE_NAME;
    END IF;

    IF v_store_id IS NULL THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Cannot resolve store for change-log row in %', TG_TABLE_NAME;
    END IF;

    v_record_id := (v_row->>'id')::UUID;
    IF TG_OP = 'INSERT' THEN
        PERFORM public.log_change(v_store_id, TG_TABLE_NAME, v_record_id, 'INSERT', NULL, to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        PERFORM public.log_change(v_store_id, TG_TABLE_NAME, v_record_id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSE
        PERFORM public.log_change(v_store_id, TG_TABLE_NAME, v_record_id, 'DELETE', to_jsonb(OLD), NULL);
        RETURN OLD;
    END IF;
END;
$log_change$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Change log triggers for purchase_returns
CREATE TRIGGER trg_purchase_returns_log_change
    AFTER INSERT OR UPDATE OR DELETE ON purchase_returns
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

CREATE TRIGGER trg_purchase_return_items_log_change
    AFTER INSERT OR UPDATE OR DELETE ON purchase_return_items
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- Change log triggers for stock_adjustments
CREATE TRIGGER trg_stock_adjustments_log_change
    AFTER INSERT OR UPDATE OR DELETE ON stock_adjustments
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- Change log triggers for inventory_batches
CREATE TRIGGER trg_inventory_batches_log_change
    AFTER INSERT OR UPDATE OR DELETE ON inventory_batches
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- Change log triggers for journal_entries
CREATE TRIGGER trg_journal_entries_log_change
    AFTER INSERT OR UPDATE OR DELETE ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- Change log triggers for general_ledger
CREATE TRIGGER trg_general_ledger_log_change
    AFTER INSERT OR UPDATE OR DELETE ON general_ledger
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- Change log triggers for stock_alerts
CREATE TRIGGER trg_stock_alerts_log_change
    AFTER INSERT OR UPDATE OR DELETE ON stock_alerts
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- Change log triggers for chart_of_accounts
CREATE TRIGGER trg_chart_of_accounts_log_change
    AFTER INSERT OR UPDATE OR DELETE ON chart_of_accounts
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

-- ============================================================
-- 14. Idempotency in outbox processing
-- ============================================================

-- Update apply_outbox_operation to include new tables
-- (This is a note for the existing function modification)

-- ============================================================
-- 15. Migration complete
-- ============================================================

COMMIT;