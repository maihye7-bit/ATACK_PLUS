-- ATACK PLUS - Phase 2: Atomic business RPCs
-- Target: Supabase PostgreSQL 15+
-- Apply AFTER POSTGRES_SCHEMA_PHASE1_FIXED.sql.
-- All monetary values are NUMERIC(18,4). Client supplies UUIDs and line inputs;
-- server derives store/user identity from Supabase Auth and recalculates totals.

BEGIN;

-- D-052: persist received quantities independently from ordered quantities.
ALTER TABLE public.purchase_items ADD COLUMN IF NOT EXISTS received_quantity NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_received_quantity_check;
ALTER TABLE public.purchase_items ADD CONSTRAINT purchase_items_received_quantity_check CHECK (received_quantity >= 0 AND received_quantity <= quantity);
UPDATE public.purchase_items SET received_quantity=quantity WHERE received=TRUE AND received_quantity=0;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS receiving_status TEXT NOT NULL DEFAULT 'PENDING';
ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_receiving_status_check;
ALTER TABLE public.purchases ADD CONSTRAINT purchases_receiving_status_check CHECK (receiving_status IN ('PENDING','PARTIAL','COMPLETE','CLOSED'));
UPDATE public.purchases p SET receiving_status=CASE
 WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity>0) THEN 'PENDING'
 WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity<pi.quantity) THEN 'PARTIAL'
 ELSE 'COMPLETE' END;

-- Correct allocation validation: invoice.remaining_amount is the authoritative
-- outstanding amount and is decremented in the same locked transaction. Summing
-- historical allocations against the already-decremented remainder double-counts
-- prior payments. Supplier payments are bounded by the locked current debt; old
-- payment rows must not be summed against a debt that already reflects them.
CREATE OR REPLACE FUNCTION public.validate_payment_allocations()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_invoice_remaining NUMERIC(18,4);
    v_payment_amount NUMERIC(18,4);
    v_payment_allocated NUMERIC(18,4);
    v_invoice_customer UUID;
    v_payment_customer UUID;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Payment allocations are immutable; use a reversal operation';
    END IF;
    PERFORM 1 FROM public.invoices WHERE id=NEW.invoice_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found'; END IF;
    PERFORM 1 FROM public.customer_payments WHERE id=NEW.payment_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Customer payment not found'; END IF;
    SELECT remaining_amount,customer_id INTO v_invoice_remaining,v_invoice_customer
      FROM public.invoices WHERE id=NEW.invoice_id;
    SELECT amount,customer_id INTO v_payment_amount,v_payment_customer
      FROM public.customer_payments WHERE id=NEW.payment_id;
    IF v_invoice_customer IS NULL OR v_invoice_customer IS DISTINCT FROM v_payment_customer THEN
        RAISE EXCEPTION 'Payment and invoice must belong to the same customer';
    END IF;
    SELECT COALESCE(SUM(allocated_amount),0) INTO v_payment_allocated
      FROM public.payment_allocations
     WHERE payment_id=NEW.payment_id AND id IS DISTINCT FROM NEW.id;
    IF NEW.allocated_amount > v_invoice_remaining THEN
        RAISE EXCEPTION 'Allocation exceeds invoice remaining amount';
    END IF;
    IF v_payment_allocated + NEW.allocated_amount > v_payment_amount THEN
        RAISE EXCEPTION 'Total allocations exceed payment amount';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_supplier_payment_allocations()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_supplier_debt NUMERIC(18,4);
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Supplier payments are immutable; use a reversal operation';
    END IF;
    SELECT current_debt INTO v_supplier_debt
      FROM public.suppliers WHERE id=NEW.supplier_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Supplier not found'; END IF;
    IF NEW.amount <= 0 OR NEW.amount > v_supplier_debt THEN
        RAISE EXCEPTION 'Supplier payment exceeds current outstanding debt';
    END IF;
    RETURN NEW;
END;
$$;

-- A business operation is claimed exactly once per store. Reusing an operation_id
-- with different JSON is rejected; replaying the identical payload is harmless.
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

    v_hash := encode(digest(convert_to(p_operation_name || ':' || p_payload::text, 'UTF8'), 'sha256'), 'hex');
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

-- SALE: invoice + invoice lines + stock decrements + stock movements + customer
-- ledger/debt + optional customer payment/allocation are one transaction.
-- Payload: {id, invoice_number, customer_id?, invoice_date?, due_date?, notes?,
--           location_id?, paid_amount?, payment_method?, items:[{id?,product_id,
--           quantity,unit_id,unit_price,discount_amount?,tax_rate?,batch_number?,expiry_date?}]}
CREATE OR REPLACE FUNCTION public.process_sale_invoice(
    p_store_id UUID, p_operation_id UUID, p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
DECLARE
    v_user UUID; v_replay BOOLEAN;
    v_invoice_id UUID := (p_payload->>'id')::UUID;
    v_customer_id UUID := NULLIF(p_payload->>'customer_id','')::UUID;
    v_location TEXT := COALESCE(NULLIF(p_payload->>'location_id',''), 'main');
    v_invoice_no TEXT := NULLIF(btrim(p_payload->>'invoice_number'), '');
    v_date TIMESTAMPTZ := COALESCE(NULLIF(p_payload->>'invoice_date','')::TIMESTAMPTZ, NOW());
    v_paid NUMERIC(18,4) := COALESCE(NULLIF(p_payload->>'paid_amount','')::NUMERIC, 0);
    v_subtotal NUMERIC(18,4) := 0; v_discount NUMERIC(18,4) := 0;
    v_tax NUMERIC(18,4) := 0; v_total NUMERIC(18,4) := 0;
    v_due NUMERIC(18,4); v_customer_debt NUMERIC(18,4);
    v_item JSONB; v_product UUID; v_item_id UUID; v_qty NUMERIC(18,4);
    v_unit TEXT; v_price NUMERIC(18,4); v_discount_line NUMERIC(18,4);
    v_tax_rate NUMERIC(5,2); v_tax_line NUMERIC(18,4); v_line_total NUMERIC(18,4);
    v_factor NUMERIC(18,6); v_base_qty NUMERIC(18,4); v_cost NUMERIC(18,4);
    v_stock_id UUID; v_payment_id UUID; v_method TEXT;
BEGIN
    IF COALESCE(jsonb_typeof(p_payload->'items'),'') <> 'array' THEN
        RAISE EXCEPTION 'Sale items must be a JSON array';
    END IF;
    IF jsonb_array_length(p_payload->'items') = 0 THEN
        RAISE EXCEPTION 'Sale must contain at least one item';
    END IF;
    SELECT c.app_user_id, c.already_processed INTO v_user, v_replay
      FROM public._claim_business_operation(p_store_id, p_operation_id, 'sale_invoice', v_invoice_id,
                                            p_payload, 'sales.write') c;
    IF v_replay THEN RETURN jsonb_build_object('success', TRUE, 'replayed', TRUE, 'invoice_id', v_invoice_id); END IF;
    IF v_invoice_no IS NULL THEN RAISE EXCEPTION 'invoice_number is required'; END IF;
    IF v_paid < 0 THEN RAISE EXCEPTION 'paid_amount cannot be negative'; END IF;
    IF v_location NOT IN ('main','warehouse','storage') THEN RAISE EXCEPTION 'Invalid stock location'; END IF;
    IF v_customer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.customers c WHERE c.id=v_customer_id AND c.store_id=p_store_id AND c.is_active
    ) THEN RAISE EXCEPTION 'Customer does not belong to this store or is inactive'; END IF;

    -- Validate and calculate every line before creating the invoice.
    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') AS e(value) ORDER BY e.value->>'product_id' LOOP
        v_product := (v_item->>'product_id')::UUID;
        v_qty := (v_item->>'quantity')::NUMERIC;
        v_unit := v_item->>'unit_id';
        v_price := (v_item->>'unit_price')::NUMERIC;
        v_discount_line := COALESCE(NULLIF(v_item->>'discount_amount','')::NUMERIC,0);
        -- D-029: TVA is deferred in v1. Keep tax columns, but never calculate tax.
        v_tax_rate := 0;
        IF v_qty <= 0 OR v_price < 0 OR v_discount_line < 0 OR v_tax_rate NOT BETWEEN 0 AND 100 THEN
            RAISE EXCEPTION 'Invalid sale line quantity, price, discount or tax rate';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id=v_product AND p.store_id=p_store_id AND p.is_active AND p.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Product % is not active in this store', v_product;
        END IF;
        SELECT CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
          INTO v_factor FROM public.products p LEFT JOIN public.product_units pu
            ON pu.product_id=p.id AND pu.unit_id=v_unit WHERE p.id=v_product AND p.store_id=p_store_id;
        IF v_factor IS NULL OR v_factor <= 0 THEN RAISE EXCEPTION 'Unit % is not configured for product %', v_unit, v_product; END IF;
        v_line_total := v_qty*v_price-v_discount_line;
        IF v_line_total < 0 THEN RAISE EXCEPTION 'Line discount exceeds line gross amount'; END IF;
        v_tax_line := 0;
        v_subtotal := v_subtotal + v_qty*v_price;
        v_discount := v_discount + v_discount_line;
        v_tax := v_tax + v_tax_line;
    END LOOP;
    v_total := v_subtotal-v_discount+v_tax;
    IF v_paid > v_total THEN RAISE EXCEPTION 'Paid amount exceeds invoice total'; END IF;
    v_due := v_total-v_paid;
    IF v_due > 0 AND v_customer_id IS NULL THEN RAISE EXCEPTION 'Credit sale requires a customer'; END IF;

    INSERT INTO public.invoices(id,store_id,invoice_number,type,customer_id,invoice_date,due_date,
        subtotal,discount_total,tax_total,total_amount,paid_amount,remaining_amount,payment_method,
        notes,created_by,status)
    VALUES(v_invoice_id,p_store_id,v_invoice_no,'SALE',v_customer_id,v_date,
        NULLIF(p_payload->>'due_date','')::TIMESTAMPTZ,v_subtotal,v_discount,v_tax,v_total,0,v_total,
        NULLIF(p_payload->>'payment_method',''),p_payload->>'notes',v_user,'OPEN');

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') AS e(value) ORDER BY e.value->>'product_id' LOOP
        v_product := (v_item->>'product_id')::UUID; v_qty := (v_item->>'quantity')::NUMERIC;
        v_unit := v_item->>'unit_id'; v_price := (v_item->>'unit_price')::NUMERIC;
        v_discount_line := COALESCE(NULLIF(v_item->>'discount_amount','')::NUMERIC,0);
        -- D-029: TVA is deferred in v1. Keep tax columns, but never calculate tax.
        v_tax_rate := 0;
        SELECT CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END, p.cost_price, p.primary_unit_id
          INTO v_factor,v_cost,v_method FROM public.products p LEFT JOIN public.product_units pu
            ON pu.product_id=p.id AND pu.unit_id=v_unit WHERE p.id=v_product AND p.store_id=p_store_id;
        v_base_qty := v_qty*v_factor;
        v_line_total := v_qty*v_price-v_discount_line;
        v_tax_line := 0;
        v_item_id := COALESCE(NULLIF(v_item->>'id','')::UUID,gen_random_uuid());

        INSERT INTO public.invoice_items(id,invoice_id,product_id,quantity,quantity_unit_id,unit_price,
            cost_per_unit,discount_amount,tax_rate,tax_amount,line_total,batch_number,expiry_date)
        VALUES(v_item_id,v_invoice_id,v_product,v_qty,v_unit,v_price,v_cost,v_discount_line,
            v_tax_rate,v_tax_line,v_line_total+v_tax_line,v_item->>'batch_number',
            NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ);

        INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
        VALUES(v_product,v_location,0,0) ON CONFLICT(product_id,location_id) DO NOTHING;
        SELECT s.id INTO v_stock_id FROM public.stock s WHERE s.product_id=v_product AND s.location_id=v_location FOR UPDATE;
        IF (SELECT quantity-reserved_quantity FROM public.stock WHERE id=v_stock_id) < v_base_qty THEN
            RAISE EXCEPTION 'Insufficient available stock for product %', v_product USING ERRCODE='23514';
        END IF;
        UPDATE public.stock SET quantity=quantity-v_base_qty WHERE id=v_stock_id;
        INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
            reference_id,reference_type,batch_number,expiry_date,reason,user_id)
        VALUES(v_product,v_location,'OUT',v_base_qty,v_method,v_cost,v_base_qty*v_cost,
            v_invoice_id,'invoice',v_item->>'batch_number',NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,
            'Sale invoice '||v_invoice_no,v_user);
    END LOOP;

    IF v_customer_id IS NOT NULL THEN
        SELECT current_debt INTO v_customer_debt FROM public.customers WHERE id=v_customer_id FOR UPDATE;
        INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,description,created_by)
        VALUES(v_customer_id,'SALE',v_total,v_customer_debt+v_total,v_invoice_id,'Sale invoice '||v_invoice_no,v_user);
        UPDATE public.customers SET current_debt=current_debt+v_due,total_sales=total_sales+v_total WHERE id=v_customer_id;
        IF v_paid > 0 THEN
            v_method := COALESCE(NULLIF(p_payload->>'payment_method',''),'CASH');
            INSERT INTO public.customer_payments(customer_id,amount,payment_method,notes,created_by)
            VALUES(v_customer_id,v_paid,v_method,'Payment on sale invoice '||v_invoice_no,v_user)
            RETURNING id INTO v_payment_id;
            INSERT INTO public.payment_allocations(payment_id,invoice_id,allocated_amount)
            VALUES(v_payment_id,v_invoice_id,v_paid);
            UPDATE public.invoices SET paid_amount=v_paid,remaining_amount=v_due,
                status=CASE WHEN v_due=0 THEN 'PAID' ELSE 'PARTIAL' END WHERE id=v_invoice_id;
            INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,description,created_by)
            VALUES(v_customer_id,'PAYMENT',-v_paid,v_customer_debt+v_total-v_paid,v_payment_id,'Payment on sale invoice '||v_invoice_no,v_user);
        END IF;
    ELSE
        UPDATE public.invoices SET paid_amount=v_paid,remaining_amount=v_due,
            status=CASE WHEN v_due=0 THEN 'PAID' WHEN v_paid>0 THEN 'PARTIAL' ELSE 'OPEN' END
         WHERE id=v_invoice_id;
    END IF;
    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'invoice_id',v_invoice_id,
        'subtotal',v_subtotal,'discount',v_discount,'tax',v_tax,'total',v_total,'paid',v_paid,'remaining',v_due);
END;
$$;

-- PURCHASE: purchase + items + stock receipts + supplier ledger/debt + optional
-- supplier payment are committed together.
-- Payload: {id,purchase_number,supplier_id,purchase_date?,location_id?,paid_amount?,
--           payment_method?,notes?,items:[{id?,product_id,quantity,unit_id,unit_price,
--           cost_per_unit?,tax_rate?,batch_number?,expiry_date?}]}
CREATE OR REPLACE FUNCTION public.process_purchase(
    p_store_id UUID, p_operation_id UUID, p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, extensions, public, pg_temp
AS $$
DECLARE
    v_user UUID; v_replay BOOLEAN; v_id UUID := (p_payload->>'id')::UUID;
    v_supplier UUID := (p_payload->>'supplier_id')::UUID;
    v_location TEXT := COALESCE(NULLIF(p_payload->>'location_id',''),'main');
    v_number TEXT := NULLIF(btrim(p_payload->>'purchase_number'),'');
    v_date TIMESTAMPTZ := COALESCE(NULLIF(p_payload->>'purchase_date','')::TIMESTAMPTZ,NOW());
    v_paid NUMERIC(18,4) := COALESCE(NULLIF(p_payload->>'paid_amount','')::NUMERIC,0);
    v_sub NUMERIC(18,4):=0; v_tax NUMERIC(18,4):=0; v_total NUMERIC(18,4):=0;
    v_debt NUMERIC(18,4); v_item JSONB; v_product UUID; v_qty NUMERIC(18,4);
    v_unit TEXT; v_price NUMERIC(18,4); v_cost NUMERIC(18,4); v_tax_rate NUMERIC(5,2);
    v_tax_line NUMERIC(18,4); v_line NUMERIC(18,4); v_factor NUMERIC(18,6);
    v_base NUMERIC(18,4); v_primary TEXT; v_stock UUID; v_payment UUID; v_method TEXT;
    v_old_qty NUMERIC(18,4); v_old_cost NUMERIC(18,4); v_new_cost NUMERIC(18,4);
    v_received_qty NUMERIC(18,4);
BEGIN
    IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' THEN RAISE EXCEPTION 'Purchase items must be a JSON array'; END IF;
    IF jsonb_array_length(p_payload->'items')=0 THEN RAISE EXCEPTION 'Purchase must contain at least one item'; END IF;
    SELECT c.app_user_id,c.already_processed INTO v_user,v_replay
      FROM public._claim_business_operation(p_store_id,p_operation_id,'purchase',v_id,p_payload,'purchases.write') c;
    IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'purchase_id',v_id); END IF;
    IF v_number IS NULL OR v_location NOT IN ('main','warehouse','storage') OR v_paid<0 THEN RAISE EXCEPTION 'Invalid purchase number, location or paid amount'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=v_supplier AND store_id=p_store_id AND is_active) THEN RAISE EXCEPTION 'Supplier does not belong to this store or is inactive'; END IF;

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') AS e(value) ORDER BY e.value->>'product_id' LOOP
        v_product:=(v_item->>'product_id')::UUID; v_qty:=(v_item->>'quantity')::NUMERIC;
        v_unit:=v_item->>'unit_id'; v_price:=(v_item->>'unit_price')::NUMERIC;
        v_cost:=COALESCE(NULLIF(v_item->>'cost_per_unit','')::NUMERIC,v_price);
        v_received_qty:=COALESCE(NULLIF(v_item->>'received_quantity','')::NUMERIC,v_qty);
        -- D-029: TVA is deferred in v1; retain schema fields without automatic tax.
        v_tax_rate:=0;
        IF v_qty<=0 OR v_price<0 OR v_cost<0 OR v_received_qty<0 OR v_received_qty>v_qty THEN
            RAISE EXCEPTION 'Invalid purchase quantity, received quantity or cost';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM public.products WHERE id=v_product AND store_id=p_store_id AND is_active AND deleted_at IS NULL) THEN RAISE EXCEPTION 'Product does not belong to this store or is inactive'; END IF;
        SELECT CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END INTO v_factor
          FROM public.products p LEFT JOIN public.product_units pu ON pu.product_id=p.id AND pu.unit_id=v_unit
         WHERE p.id=v_product AND p.store_id=p_store_id;
        IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Unit % is not configured for product %',v_unit,v_product; END IF;
        v_line:=v_qty*v_price; v_tax_line:=0;
        v_sub:=v_sub+v_line; v_tax:=v_tax+v_tax_line;
    END LOOP;
    v_total:=v_sub+v_tax;
    IF v_paid>v_total THEN RAISE EXCEPTION 'Paid amount exceeds purchase total'; END IF;

    INSERT INTO public.purchases(id,store_id,purchase_number,supplier_id,purchase_date,subtotal,tax_total,
        total_amount,paid_amount,remaining_amount,payment_method,notes,created_by,status)
    VALUES(v_id,p_store_id,v_number,v_supplier,v_date,v_sub,v_tax,v_total,v_paid,v_total-v_paid,
        NULLIF(p_payload->>'payment_method',''),p_payload->>'notes',v_user,
        CASE WHEN v_total=v_paid THEN 'PAID' WHEN v_paid>0 THEN 'PARTIAL' ELSE 'OPEN' END);

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') AS e(value) ORDER BY e.value->>'product_id' LOOP
        v_product:=(v_item->>'product_id')::UUID; v_qty:=(v_item->>'quantity')::NUMERIC;
        v_unit:=v_item->>'unit_id'; v_price:=(v_item->>'unit_price')::NUMERIC;
        v_cost:=COALESCE(NULLIF(v_item->>'cost_per_unit','')::NUMERIC,v_price);
        v_received_qty:=COALESCE(NULLIF(v_item->>'received_quantity','')::NUMERIC,v_qty);
        -- D-029: TVA is deferred in v1; retain schema fields without automatic tax.
        v_tax_rate:=0;
        -- Serialize receipts per product, then lock its stock rows in a stable order.
        -- This prevents concurrent purchases from overwriting the weighted average cost.
        SELECT CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END,
               p.primary_unit_id,p.cost_price
          INTO v_factor,v_primary,v_old_cost
          FROM public.products p
          LEFT JOIN public.product_units pu ON pu.product_id=p.id AND pu.unit_id=v_unit
         WHERE p.id=v_product AND p.store_id=p_store_id
         FOR UPDATE OF p;
        v_base:=v_received_qty*v_factor; v_line:=v_qty*v_price; v_tax_line:=0;
        INSERT INTO public.purchase_items(id,purchase_id,product_id,quantity,quantity_unit_id,unit_price,
            cost_per_unit,tax_rate,tax_amount,line_total,batch_number,expiry_date,received,received_date,received_quantity)
        VALUES(COALESCE(NULLIF(v_item->>'id','')::UUID,gen_random_uuid()),v_id,v_product,v_qty,v_unit,
            v_price,v_cost,v_tax_rate,v_tax_line,v_line+v_tax_line,v_item->>'batch_number',
            NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,v_received_qty=v_qty,
            CASE WHEN v_received_qty>0 THEN NOW() ELSE NULL END,v_received_qty);
        IF v_received_qty=0 THEN CONTINUE; END IF;
        INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
        VALUES(v_product,v_location,0,0) ON CONFLICT(product_id,location_id) DO NOTHING;
        PERFORM 1 FROM public.stock WHERE product_id=v_product ORDER BY location_id FOR UPDATE;
        SELECT COALESCE(SUM(quantity),0) INTO v_old_qty
          FROM public.stock WHERE product_id=v_product;
        SELECT id INTO v_stock FROM public.stock
         WHERE product_id=v_product AND location_id=v_location;
        -- cost_price is stored per primary unit. Purchase line cost is converted
        -- from the entered unit before computing the inventory weighted average.
        v_new_cost := CASE
          WHEN v_old_qty + v_base = 0 THEN v_cost/v_factor
          WHEN v_old_qty = 0 THEN v_cost/v_factor
          ELSE round(((v_old_qty*v_old_cost)+(v_received_qty*v_cost))/(v_old_qty+v_base),4)
        END;
        UPDATE public.stock SET quantity=quantity+v_base WHERE id=v_stock;
        INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
            reference_id,reference_type,batch_number,expiry_date,reason,user_id)
        VALUES(v_product,v_location,'IN',v_base,v_primary,v_cost/v_factor,v_received_qty*v_cost,v_id,'purchase',
            v_item->>'batch_number',NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,'Purchase '||v_number,v_user);
        UPDATE public.products SET cost_price=v_new_cost,updated_at=NOW() WHERE id=v_product;
    END LOOP;

    UPDATE public.purchases p SET receiving_status=CASE
      WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity>0) THEN 'PENDING'
      WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity<pi.quantity) THEN 'PARTIAL'
      ELSE 'COMPLETE' END,
      received_date=CASE WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity<pi.quantity) THEN NOW() ELSE NULL END
     WHERE p.id=v_id;

    SELECT current_debt INTO v_debt FROM public.suppliers WHERE id=v_supplier FOR UPDATE;
    INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
    VALUES(v_supplier,'PURCHASE',v_total,v_debt+v_total,v_id,'Purchase '||v_number,v_user);
    UPDATE public.suppliers SET current_debt=current_debt+v_total WHERE id=v_supplier;
    IF v_paid>0 THEN
        v_method:=COALESCE(NULLIF(p_payload->>'payment_method',''),'CASH');
        INSERT INTO public.supplier_payments(supplier_id,amount,payment_method,notes,created_by)
        VALUES(v_supplier,v_paid,v_method,'Payment on purchase '||v_number,v_user) RETURNING id INTO v_payment;
        INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
        VALUES(v_supplier,'PAYMENT',-v_paid,v_debt+v_total-v_paid,v_payment,'Payment on purchase '||v_number,v_user);
        UPDATE public.suppliers SET current_debt=current_debt-v_paid WHERE id=v_supplier;
    END IF;
    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'purchase_id',v_id,'subtotal',v_sub,'tax',v_tax,
        'total',v_total,'paid',v_paid,'remaining',v_total-v_paid);
END;
$$;

-- PARTIAL PURCHASE RECEIVING: each receipt is atomic and independently idempotent.
-- Payload: {id: receipt UUID, purchase_id, location_id?, items:[{purchase_item_id, quantity}]}
CREATE OR REPLACE FUNCTION public.process_purchase_receipt(
    p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_receipt$
DECLARE
    v_user UUID; v_replay BOOLEAN; v_receipt_id UUID := (p_payload->>'id')::UUID;
    v_purchase_id UUID := (p_payload->>'purchase_id')::UUID;
    v_location TEXT := COALESCE(NULLIF(p_payload->>'location_id',''),'main');
    v_row JSONB; v_item_id UUID; v_qty NUMERIC(18,4); v_product UUID;
    v_ordered NUMERIC(18,4); v_received NUMERIC(18,4); v_factor NUMERIC(18,6);
    v_primary TEXT; v_cost NUMERIC(18,4); v_old_cost NUMERIC(18,4);
    v_old_qty NUMERIC(18,4); v_base NUMERIC(18,4); v_stock UUID;
    v_purchase_number TEXT; v_received_total NUMERIC(18,4) := 0;
BEGIN
    IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' OR jsonb_array_length(p_payload->'items')=0 THEN
        RAISE EXCEPTION 'Receipt items must be a non-empty JSON array';
    END IF;
    IF v_location NOT IN ('main','warehouse','storage') THEN RAISE EXCEPTION 'Invalid stock location'; END IF;
    SELECT c.app_user_id,c.already_processed INTO v_user,v_replay
      FROM public._claim_business_operation(p_store_id,p_operation_id,'purchase_receipt',v_receipt_id,p_payload,'purchases.receive') c;
    IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'receipt_id',v_receipt_id); END IF;
    SELECT purchase_number INTO v_purchase_number FROM public.purchases
     WHERE id=v_purchase_id AND store_id=p_store_id AND status<>'CANCELLED' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found or cancelled'; END IF;

    FOR v_row IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
                 ORDER BY e.value->>'purchase_item_id'
    LOOP
      v_item_id:=(v_row->>'purchase_item_id')::UUID;
      v_qty:=(v_row->>'quantity')::NUMERIC;
      IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'Receipt quantity must be positive'; END IF;
      SELECT pi.product_id,pi.quantity,pi.received_quantity,pi.cost_per_unit,
             p.primary_unit_id,p.cost_price,
             CASE WHEN pi.quantity_unit_id=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
        INTO v_product,v_ordered,v_received,v_cost,v_primary,v_old_cost,v_factor
        FROM public.purchase_items pi JOIN public.products p ON p.id=pi.product_id
        LEFT JOIN public.product_units pu ON pu.product_id=p.id AND pu.unit_id=pi.quantity_unit_id
       WHERE pi.id=v_item_id AND pi.purchase_id=v_purchase_id FOR UPDATE OF pi,p;
      IF NOT FOUND THEN RAISE EXCEPTION 'Purchase item not found in this purchase'; END IF;
      IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Purchase item unit conversion is invalid'; END IF;
      IF v_received+v_qty>v_ordered THEN
        RAISE EXCEPTION 'Receipt quantity exceeds outstanding purchase quantity for item %',v_item_id USING ERRCODE='23514';
      END IF;
      v_base:=v_qty*v_factor;
      INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
      VALUES(v_product,v_location,0,0) ON CONFLICT(product_id,location_id) DO NOTHING;
      PERFORM 1 FROM public.stock WHERE product_id=v_product ORDER BY location_id FOR UPDATE;
      SELECT COALESCE(SUM(quantity),0) INTO v_old_qty FROM public.stock WHERE product_id=v_product;
      SELECT id INTO v_stock FROM public.stock WHERE product_id=v_product AND location_id=v_location;
      UPDATE public.stock SET quantity=quantity+v_base WHERE id=v_stock;
      UPDATE public.purchase_items SET received_quantity=received_quantity+v_qty,
        received=(received_quantity+v_qty)>=quantity,
        received_date=CASE WHEN (received_quantity+v_qty)>=quantity THEN NOW() ELSE received_date END
       WHERE id=v_item_id;
      UPDATE public.products SET cost_price=CASE WHEN v_old_qty=0 THEN round(v_cost/v_factor,4)
        ELSE round(((v_old_qty*v_old_cost)+(v_qty*v_cost))/(v_old_qty+v_base),4) END,updated_at=NOW()
       WHERE id=v_product;
      INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
        reference_id,reference_type,reason,user_id)
      VALUES(v_product,v_location,'IN',v_base,v_primary,v_cost/v_factor,v_qty*v_cost,
        v_purchase_id,'purchase','Partial receipt '||v_receipt_id::text||' for purchase '||v_purchase_number,v_user);
      v_received_total:=v_received_total+v_base;
    END LOOP;
    UPDATE public.purchases p SET receiving_status=CASE
      WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity>0) THEN 'PENDING'
      WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity<pi.quantity) THEN 'PARTIAL'
      ELSE 'COMPLETE' END,
      received_date=CASE WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity<pi.quantity) THEN NOW() ELSE NULL END,
      updated_at=NOW() WHERE p.id=v_purchase_id;
    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'receipt_id',v_receipt_id,
      'purchase_id',v_purchase_id,'received_base_quantity',v_received_total);
END;
$purchase_receipt$;

REVOKE ALL ON FUNCTION public.process_purchase_receipt(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_receipt(UUID,UUID,JSONB) TO authenticated;

-- CUSTOMER PAYMENT: creates payment + ledger entry + invoice allocations and
-- updates cached debt/invoice balances atomically. Payload: {id,customer_id,amount,
-- payment_method,reference_no?,notes?,allocations:[{invoice_id,amount}]}; allocations optional.
CREATE OR REPLACE FUNCTION public.process_customer_payment(
    p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $$
DECLARE
    v_user UUID; v_replay BOOLEAN; v_id UUID:=(p_payload->>'id')::UUID;
    v_customer UUID:=(p_payload->>'customer_id')::UUID; v_amount NUMERIC(18,4):=(p_payload->>'amount')::NUMERIC;
    v_method TEXT:=p_payload->>'payment_method'; v_debt NUMERIC(18,4); v_alloc NUMERIC(18,4):=0;
    v_row JSONB; v_invoice UUID; v_part NUMERIC(18,4); v_payment UUID;
    v_remaining NUMERIC(18,4); v_invoice_row RECORD;
BEGIN
    SELECT c.app_user_id,c.already_processed INTO v_user,v_replay FROM public._claim_business_operation(
        p_store_id,p_operation_id,'customer_payment',v_id,p_payload,'customers.payments') c;
    IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'payment_id',v_id); END IF;
    IF v_amount<=0 OR v_method NOT IN ('CASH','CARD','BANK_TRANSFER','MOBILE') THEN RAISE EXCEPTION 'Invalid payment amount or method'; END IF;
    SELECT current_debt INTO v_debt FROM public.customers WHERE id=v_customer AND store_id=p_store_id AND is_active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Customer does not belong to this store or is inactive'; END IF;
    IF v_amount>v_debt THEN RAISE EXCEPTION 'Payment exceeds outstanding customer debt'; END IF;
    IF p_payload ? 'allocations' THEN
        IF jsonb_typeof(p_payload->'allocations')<>'array' THEN RAISE EXCEPTION 'allocations must be an array'; END IF;
        FOR v_row IN SELECT e.value FROM jsonb_array_elements(p_payload->'allocations') AS e(value) ORDER BY e.value->>'invoice_id' LOOP
            v_invoice:=(v_row->>'invoice_id')::UUID; v_part:=(v_row->>'amount')::NUMERIC;
            IF v_part<=0 THEN RAISE EXCEPTION 'Allocation amount must be positive'; END IF;
            PERFORM 1 FROM public.invoices WHERE id=v_invoice AND store_id=p_store_id AND customer_id=v_customer AND type='SALE' AND status<>'CANCELLED' FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Allocated invoice is not an open sale invoice for this customer'; END IF;
            IF v_part>(SELECT remaining_amount FROM public.invoices WHERE id=v_invoice) THEN RAISE EXCEPTION 'Allocation exceeds invoice remaining amount'; END IF;
            v_alloc:=v_alloc+v_part;
        END LOOP;
        IF v_alloc>v_amount THEN RAISE EXCEPTION 'Allocations exceed payment amount'; END IF;
    END IF;
    INSERT INTO public.customer_payments(id,customer_id,amount,payment_method,reference_no,notes,created_by)
    VALUES(v_id,v_customer,v_amount,v_method,p_payload->>'reference_no',p_payload->>'notes',v_user) RETURNING id INTO v_payment;
    IF p_payload ? 'allocations' THEN
        FOR v_row IN SELECT value FROM jsonb_array_elements(p_payload->'allocations') LOOP
            v_invoice:=(v_row->>'invoice_id')::UUID; v_part:=(v_row->>'amount')::NUMERIC;
            INSERT INTO public.payment_allocations(payment_id,invoice_id,allocated_amount) VALUES(v_payment,v_invoice,v_part);
            UPDATE public.invoices SET paid_amount=paid_amount+v_part,remaining_amount=remaining_amount-v_part,
                status=CASE WHEN remaining_amount-v_part=0 THEN 'PAID' ELSE 'PARTIAL' END WHERE id=v_invoice;
        END LOOP;
    END IF;

    -- Any unassigned part is automatically allocated to the oldest outstanding
    -- sale invoices. This keeps customer debt and invoice balances reconcilable.
    v_remaining := v_amount-v_alloc;
    FOR v_invoice_row IN
        SELECT i.id,i.remaining_amount FROM public.invoices i
         WHERE i.store_id=p_store_id AND i.customer_id=v_customer AND i.type='SALE'
           AND i.status IN ('OPEN','PARTIAL') AND i.remaining_amount>0
           AND NOT EXISTS (SELECT 1 FROM public.payment_allocations pa
                            WHERE pa.payment_id=v_payment AND pa.invoice_id=i.id)
         ORDER BY i.invoice_date,i.id FOR UPDATE OF i
    LOOP
        EXIT WHEN v_remaining<=0;
        v_part := LEAST(v_remaining,v_invoice_row.remaining_amount);
        INSERT INTO public.payment_allocations(payment_id,invoice_id,allocated_amount)
        VALUES(v_payment,v_invoice_row.id,v_part);
        UPDATE public.invoices SET paid_amount=paid_amount+v_part,remaining_amount=remaining_amount-v_part,
            status=CASE WHEN remaining_amount-v_part=0 THEN 'PAID' ELSE 'PARTIAL' END
         WHERE id=v_invoice_row.id;
        v_remaining := v_remaining-v_part;
    END LOOP;
    IF v_remaining>0 THEN
        RAISE EXCEPTION 'Payment cannot be fully allocated to outstanding sale invoices';
    END IF;
    UPDATE public.customers SET current_debt=current_debt-v_amount WHERE id=v_customer;
    INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,description,created_by)
    VALUES(v_customer,'PAYMENT',-v_amount,v_debt-v_amount,v_payment,'Customer payment',v_user);
    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'payment_id',v_payment,'amount',v_amount,
        'allocated',v_amount,'unallocated',0,'remaining_debt',v_debt-v_amount);
END;
$$;

-- SUPPLIER PAYMENT: payment + supplier ledger + cached debt update are atomic.
CREATE OR REPLACE FUNCTION public.process_supplier_payment(
    p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $$
DECLARE
    v_user UUID; v_replay BOOLEAN; v_id UUID:=(p_payload->>'id')::UUID;
    v_supplier UUID:=(p_payload->>'supplier_id')::UUID; v_amount NUMERIC(18,4):=(p_payload->>'amount')::NUMERIC;
    v_method TEXT:=p_payload->>'payment_method'; v_debt NUMERIC(18,4); v_payment UUID;
BEGIN
    SELECT c.app_user_id,c.already_processed INTO v_user,v_replay FROM public._claim_business_operation(
        p_store_id,p_operation_id,'supplier_payment',v_id,p_payload,'suppliers.payments') c;
    IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'payment_id',v_id); END IF;
    IF v_amount<=0 OR v_method NOT IN ('CASH','CARD','BANK_TRANSFER','MOBILE') THEN RAISE EXCEPTION 'Invalid payment amount or method'; END IF;
    SELECT current_debt INTO v_debt FROM public.suppliers WHERE id=v_supplier AND store_id=p_store_id AND is_active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Supplier does not belong to this store or is inactive'; END IF;
    IF v_amount>v_debt THEN RAISE EXCEPTION 'Payment exceeds outstanding supplier debt'; END IF;
    INSERT INTO public.supplier_payments(id,supplier_id,amount,payment_method,reference_no,notes,created_by)
    VALUES(v_id,v_supplier,v_amount,v_method,p_payload->>'reference_no',p_payload->>'notes',v_user) RETURNING id INTO v_payment;
    UPDATE public.suppliers SET current_debt=current_debt-v_amount WHERE id=v_supplier;
    INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
    VALUES(v_supplier,'PAYMENT',-v_amount,v_debt-v_amount,v_payment,'Supplier payment',v_user);
    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'payment_id',v_payment,'amount',v_amount,
        'remaining_debt',v_debt-v_amount);
END;
$$;

-- Expose only RPC execution to authenticated clients; helper remains private.
REVOKE ALL ON FUNCTION public.process_sale_invoice(UUID,UUID,JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.process_purchase(UUID,UUID,JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.process_customer_payment(UUID,UUID,JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.process_supplier_payment(UUID,UUID,JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._claim_business_operation(UUID,UUID,TEXT,UUID,JSONB,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_invoice(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_purchase(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_customer_payment(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_supplier_payment(UUID,UUID,JSONB) TO authenticated;

COMMIT;
