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

        -- A reference must be either fully absent or resolve to a record in
        -- the same store as the movement's product. Lock the referenced row
        -- so a concurrent ownership change cannot pass this check unnoticed.
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
                SELECT store_id INTO v_store_c FROM sales_returns WHERE id = NEW.reference_id FOR SHARE;
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

COMMIT;
