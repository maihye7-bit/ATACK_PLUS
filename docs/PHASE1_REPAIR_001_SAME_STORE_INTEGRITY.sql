-- Phase 1 Repair 001: complete same-store validation for dependent rows.
-- Apply after POSTGRES_SCHEMA_PHASE1_FIXED.sql and Phase 3 business tables.
-- Transactional and additive: replaces one trigger function; no business rows are changed.
BEGIN;

DO $precondition$
BEGIN
  IF to_regclass('public.stock_adjustments') IS NULL THEN
    RAISE EXCEPTION 'stock_adjustments must exist before applying same-store integrity repair 001';
  END IF;
  IF to_regprocedure('public.validate_same_store_references()') IS NULL THEN
    RAISE EXCEPTION 'base validate_same_store_references() function is missing';
  END IF;
END
$precondition$;

CREATE OR REPLACE FUNCTION public.validate_same_store_references()
RETURNS TRIGGER AS $$
DECLARE
    v_store_a UUID;
    v_store_b UUID;
    v_store_c UUID;
    v_reference_count INTEGER;
    v_reference_store_count INTEGER;
BEGIN
    CASE TG_TABLE_NAME
      WHEN 'invoice_items' THEN
        SELECT store_id INTO v_store_a FROM invoices WHERE id = NEW.invoice_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM products WHERE id = NEW.product_id FOR SHARE;
      WHEN 'purchase_items' THEN
        SELECT store_id INTO v_store_a FROM purchases WHERE id = NEW.purchase_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM products WHERE id = NEW.product_id FOR SHARE;
      WHEN 'return_items' THEN
        SELECT store_id INTO v_store_a FROM sales_returns WHERE id = NEW.return_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM products WHERE id = NEW.product_id FOR SHARE;
      WHEN 'stock_movements' THEN
        SELECT store_id INTO v_store_a FROM products WHERE id = NEW.product_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.user_id FOR SHARE;
        IF (NEW.reference_type IS NULL) <> (NEW.reference_id IS NULL) THEN
            RAISE EXCEPTION 'Stock movement reference type and ID must both be NULL or both be set';
        END IF;
        IF NEW.reference_type IS NOT NULL THEN
            CASE NEW.reference_type
              WHEN 'invoice' THEN
                SELECT store_id INTO v_store_c FROM invoices WHERE id = NEW.reference_id FOR SHARE;
              WHEN 'purchase' THEN
                SELECT store_id INTO v_store_c FROM purchases WHERE id = NEW.reference_id FOR SHARE;
              WHEN 'adjustment' THEN
                SELECT store_id INTO v_store_c FROM stock_adjustments WHERE id = NEW.reference_id FOR SHARE;
              WHEN 'return' THEN
                -- The existing business model uses reference_type='return' for
                -- both sales_returns and purchase_returns. Require exactly one
                -- matching parent so a UUID collision cannot make the reference ambiguous.
                PERFORM 1 FROM sales_returns WHERE id = NEW.reference_id FOR SHARE;
                PERFORM 1 FROM purchase_returns WHERE id = NEW.reference_id FOR SHARE;
                SELECT COUNT(*), COUNT(DISTINCT store_id)
                  INTO v_reference_count, v_reference_store_count
                  FROM (
                    SELECT store_id FROM sales_returns WHERE id = NEW.reference_id
                    UNION ALL
                    SELECT store_id FROM purchase_returns WHERE id = NEW.reference_id
                  ) AS return_refs;
                IF v_reference_count <> 1 OR v_reference_store_count <> 1 THEN
                    RAISE EXCEPTION 'Stock movement return reference must resolve to exactly one return record';
                END IF;
                SELECT store_id INTO v_store_c
                  FROM (
                    SELECT store_id FROM sales_returns WHERE id = NEW.reference_id
                    UNION ALL
                    SELECT store_id FROM purchase_returns WHERE id = NEW.reference_id
                  ) AS return_refs
                 LIMIT 1;
              ELSE
                RAISE EXCEPTION 'Unsupported stock movement reference type: %', NEW.reference_type;
            END CASE;
            IF v_store_c IS NULL OR v_store_c IS DISTINCT FROM v_store_a THEN
                RAISE EXCEPTION 'Stock movement reference must belong to the product store';
            END IF;
        END IF;
      WHEN 'customer_payments' THEN
        SELECT store_id INTO v_store_a FROM customers WHERE id = NEW.customer_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'customer_ledgers' THEN
        SELECT store_id INTO v_store_a FROM customers WHERE id = NEW.customer_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'supplier_payments' THEN
        SELECT store_id INTO v_store_a FROM suppliers WHERE id = NEW.supplier_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'supplier_ledger' THEN
        SELECT store_id INTO v_store_a FROM suppliers WHERE id = NEW.supplier_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'product_units' THEN
        SELECT store_id INTO v_store_a FROM products WHERE id = NEW.product_id FOR SHARE;
        v_store_b := v_store_a;
      WHEN 'user_roles' THEN
        SELECT store_id INTO v_store_a FROM users WHERE id = NEW.user_id FOR SHARE;
        IF NEW.granted_by IS NOT NULL THEN
          SELECT store_id INTO v_store_b FROM users WHERE id = NEW.granted_by FOR SHARE;
        ELSE
          v_store_b := v_store_a;
        END IF;
      WHEN 'payment_allocations' THEN
        SELECT store_id INTO v_store_a FROM invoices WHERE id = NEW.invoice_id FOR SHARE;
        SELECT c.store_id INTO v_store_b
          FROM customer_payments cp
          JOIN customers c ON c.id = cp.customer_id
         WHERE cp.id = NEW.payment_id
         FOR SHARE OF cp, c;
        IF NOT EXISTS (
            SELECT 1 FROM invoices i
            JOIN customer_payments cp ON cp.id = NEW.payment_id
            WHERE i.id = NEW.invoice_id AND i.customer_id = cp.customer_id
        ) THEN
            RAISE EXCEPTION 'Payment allocation must link a payment and invoice for the same customer';
        END IF;
      ELSE
        RAISE EXCEPTION 'Unsupported table for same-store validation: %', TG_TABLE_NAME;
    END CASE;
    IF v_store_a IS NULL OR v_store_b IS NULL OR v_store_a IS DISTINCT FROM v_store_b THEN
        RAISE EXCEPTION 'Cross-store or missing reference rejected for table %', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.prevent_store_reassignment_with_dependents()
RETURNS TRIGGER AS $$
DECLARE
    v_has_dependents BOOLEAN := FALSE;
BEGIN
    IF NEW.store_id IS NOT DISTINCT FROM OLD.store_id THEN RETURN NEW; END IF;

    CASE TG_TABLE_NAME
      WHEN 'products' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.stock WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_movements WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.invoice_items WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.purchase_items WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.return_items WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.product_units WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_adjustments WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.purchase_return_items WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.inventory_batches WHERE product_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.purchase_receipt_items WHERE original_product_id=OLD.id OR actual_product_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'users' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.stock_movements WHERE user_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.customer_payments WHERE created_by=OLD.id) OR
          EXISTS (SELECT 1 FROM public.customer_ledgers WHERE created_by=OLD.id) OR
          EXISTS (SELECT 1 FROM public.supplier_payments WHERE created_by=OLD.id) OR
          EXISTS (SELECT 1 FROM public.supplier_ledger WHERE created_by=OLD.id) OR
          EXISTS (SELECT 1 FROM public.user_roles WHERE user_id=OLD.id OR granted_by=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_adjustments WHERE created_by=OLD.id) OR
          EXISTS (SELECT 1 FROM public.purchase_receipts WHERE received_by=OLD.id OR approved_by=OLD.id)
        INTO v_has_dependents;
      WHEN 'invoices' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.invoice_items WHERE invoice_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.payment_allocations WHERE invoice_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.sales_returns WHERE original_invoice_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_type='invoice' AND reference_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'purchases' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.purchase_items WHERE purchase_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.purchase_returns WHERE original_purchase_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.purchase_receipts WHERE purchase_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_type='purchase' AND reference_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'sales_returns' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.return_items WHERE return_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_type='return' AND reference_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'purchase_returns' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.purchase_return_items WHERE return_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_type='return' AND reference_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'stock_adjustments' THEN
        SELECT EXISTS (SELECT 1 FROM public.stock_movements
          WHERE reference_type='adjustment' AND reference_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'customers' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.customer_payments WHERE customer_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.customer_ledgers WHERE customer_id=OLD.id)
        INTO v_has_dependents;
      WHEN 'suppliers' THEN
        SELECT
          EXISTS (SELECT 1 FROM public.supplier_payments WHERE supplier_id=OLD.id) OR
          EXISTS (SELECT 1 FROM public.supplier_ledger WHERE supplier_id=OLD.id)
        INTO v_has_dependents;
      ELSE
        RAISE EXCEPTION 'Unsupported parent table for same-store ownership guard: %', TG_TABLE_NAME;
    END CASE;

    IF v_has_dependents THEN
      RAISE EXCEPTION 'Cannot change store_id for % % while dependent business records exist',
        TG_TABLE_NAME, OLD.id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_guard_product_stock_movement_store ON public.products;
CREATE TRIGGER trg_guard_product_stock_movement_store
BEFORE UPDATE OF store_id ON public.products
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_user_stock_movement_store ON public.users;
CREATE TRIGGER trg_guard_user_stock_movement_store
BEFORE UPDATE OF store_id ON public.users
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_invoice_stock_movement_store ON public.invoices;
CREATE TRIGGER trg_guard_invoice_stock_movement_store
BEFORE UPDATE OF store_id ON public.invoices
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_purchase_stock_movement_store ON public.purchases;
CREATE TRIGGER trg_guard_purchase_stock_movement_store
BEFORE UPDATE OF store_id ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_adjustment_stock_movement_store ON public.stock_adjustments;
CREATE TRIGGER trg_guard_adjustment_stock_movement_store
BEFORE UPDATE OF store_id ON public.stock_adjustments
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_sale_return_stock_movement_store ON public.sales_returns;
CREATE TRIGGER trg_guard_sale_return_stock_movement_store
BEFORE UPDATE OF store_id ON public.sales_returns
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_purchase_return_stock_movement_store ON public.purchase_returns;
CREATE TRIGGER trg_guard_purchase_return_stock_movement_store
BEFORE UPDATE OF store_id ON public.purchase_returns
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

COMMIT;
