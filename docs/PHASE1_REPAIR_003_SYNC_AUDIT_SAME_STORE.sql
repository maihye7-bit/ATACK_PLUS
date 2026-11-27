-- Phase 1 Repair 003: same-store integrity for devices, sync metadata and audit rows.
-- Apply after Phase 3 sync/audit table hardening.
BEGIN;

DO $precondition$
DECLARE v_required TEXT[]:=ARRAY['devices','sync_cursors','sync_outbox','sync_conflicts','tombstones','sync_log','audit_logs'];
        v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY v_required LOOP
    IF to_regclass('public.'||v_table) IS NULL THEN
      RAISE EXCEPTION 'Required sync/audit table public.% is missing',v_table;
    END IF;
  END LOOP;
END
$precondition$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_devices_id_store_repair ON public.devices(id,store_id);



CREATE OR REPLACE FUNCTION public.validate_sync_device_store()
RETURNS TRIGGER AS $$
DECLARE v_device_store UUID;
BEGIN
  IF TG_TABLE_NAME='sync_outbox' THEN
    IF NULLIF(NEW.record_json->>'id','')::UUID IS DISTINCT FROM NEW.record_uuid
       OR NULLIF(NEW.record_json->>'store_id','')::UUID IS DISTINCT FROM NEW.store_id THEN
      RAISE EXCEPTION 'Outbox payload identity must match its store and record key';
    END IF;
  END IF;

  IF NEW.device_id IS NULL OR NULLIF(btrim(NEW.device_id),'') IS NULL THEN
    IF TG_TABLE_NAME='audit_logs' THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'A registered device ID is required for %',TG_TABLE_NAME;
  END IF;
  SELECT store_id INTO v_device_store FROM public.devices
   WHERE id::TEXT=NEW.device_id FOR SHARE;
  IF v_device_store IS NULL OR v_device_store IS DISTINCT FROM NEW.store_id THEN
    RAISE EXCEPTION 'Device % is not registered to store %',NEW.device_id,NEW.store_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.prevent_device_store_reassignment()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.store_id IS DISTINCT FROM OLD.store_id AND (
    EXISTS(SELECT 1 FROM public.sync_cursors WHERE device_id=OLD.id::TEXT) OR
    EXISTS(SELECT 1 FROM public.sync_outbox WHERE device_id=OLD.id::TEXT) OR
    EXISTS(SELECT 1 FROM public.sync_log WHERE device_id=OLD.id::TEXT) OR
    EXISTS(SELECT 1 FROM public.audit_logs WHERE device_id=OLD.id::TEXT)
  ) THEN
    RAISE EXCEPTION 'Cannot change device store after sync or audit history exists';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_tombstone_target_store()
RETURNS TRIGGER AS $$
DECLARE v_target_store UUID;
BEGIN
  IF NEW.table_name NOT IN ('categories','brands','products','customers','suppliers') THEN
    RAISE EXCEPTION 'Tombstones are not enabled for table %',NEW.table_name;
  END IF;
  EXECUTE format('SELECT store_id FROM public.%I WHERE id=$1 FOR SHARE',NEW.table_name)
    INTO v_target_store USING NEW.record_uuid;
  IF v_target_store IS NULL OR v_target_store IS DISTINCT FROM NEW.store_id THEN
    RAISE EXCEPTION 'Tombstone target must exist in the same store';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.resolve_sync_entity_store(p_table_name TEXT,p_record_uuid UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_store UUID;
BEGIN
  CASE p_table_name
    WHEN 'stores' THEN SELECT id INTO v_store FROM public.stores WHERE id=p_record_uuid;
    WHEN 'categories' THEN SELECT store_id INTO v_store FROM public.categories WHERE id=p_record_uuid;
    WHEN 'brands' THEN SELECT store_id INTO v_store FROM public.brands WHERE id=p_record_uuid;
    WHEN 'products' THEN SELECT store_id INTO v_store FROM public.products WHERE id=p_record_uuid;
    WHEN 'customers' THEN SELECT store_id INTO v_store FROM public.customers WHERE id=p_record_uuid;
    WHEN 'suppliers' THEN SELECT store_id INTO v_store FROM public.suppliers WHERE id=p_record_uuid;
    WHEN 'purchases' THEN SELECT store_id INTO v_store FROM public.purchases WHERE id=p_record_uuid;
    WHEN 'invoices' THEN SELECT store_id INTO v_store FROM public.invoices WHERE id=p_record_uuid;
    WHEN 'sales_returns' THEN SELECT store_id INTO v_store FROM public.sales_returns WHERE id=p_record_uuid;
    WHEN 'expenses' THEN SELECT store_id INTO v_store FROM public.expenses WHERE id=p_record_uuid;
    WHEN 'revenues' THEN SELECT store_id INTO v_store FROM public.revenues WHERE id=p_record_uuid;
    WHEN 'purchase_returns' THEN SELECT store_id INTO v_store FROM public.purchase_returns WHERE id=p_record_uuid;
    WHEN 'stock_adjustments' THEN SELECT store_id INTO v_store FROM public.stock_adjustments WHERE id=p_record_uuid;
    WHEN 'inventory_batches' THEN SELECT store_id INTO v_store FROM public.inventory_batches WHERE id=p_record_uuid;
    WHEN 'stock_alerts' THEN SELECT store_id INTO v_store FROM public.stock_alerts WHERE id=p_record_uuid;
    WHEN 'chart_of_accounts' THEN SELECT store_id INTO v_store FROM public.chart_of_accounts WHERE id=p_record_uuid;
    WHEN 'journal_entries' THEN SELECT store_id INTO v_store FROM public.journal_entries WHERE id=p_record_uuid;
    WHEN 'general_ledger' THEN SELECT store_id INTO v_store FROM public.general_ledger WHERE id=p_record_uuid;
    WHEN 'purchase_receipts' THEN SELECT store_id INTO v_store FROM public.purchase_receipts WHERE id=p_record_uuid;
    WHEN 'purchase_receipt_items' THEN SELECT store_id INTO v_store FROM public.purchase_receipt_items WHERE id=p_record_uuid;
    WHEN 'purchase_closures' THEN SELECT store_id INTO v_store FROM public.purchase_closures WHERE id=p_record_uuid;
    WHEN 'purchase_closure_items' THEN SELECT store_id INTO v_store FROM public.purchase_closure_items WHERE id=p_record_uuid;
    WHEN 'purchase_amendments' THEN SELECT store_id INTO v_store FROM public.purchase_amendments WHERE id=p_record_uuid;
    WHEN 'tombstones' THEN SELECT store_id INTO v_store FROM public.tombstones WHERE id=p_record_uuid;
    WHEN 'stock' THEN SELECT p.store_id INTO v_store FROM public.stock x JOIN public.products p ON p.id=x.product_id WHERE x.id=p_record_uuid;
    WHEN 'stock_movements' THEN SELECT p.store_id INTO v_store FROM public.stock_movements x JOIN public.products p ON p.id=x.product_id WHERE x.id=p_record_uuid;
    WHEN 'product_units' THEN SELECT p.store_id INTO v_store FROM public.product_units x JOIN public.products p ON p.id=x.product_id WHERE x.id=p_record_uuid;
    WHEN 'purchase_items' THEN SELECT p.store_id INTO v_store FROM public.purchase_items x JOIN public.purchases p ON p.id=x.purchase_id WHERE x.id=p_record_uuid;
    WHEN 'invoice_items' THEN SELECT i.store_id INTO v_store FROM public.invoice_items x JOIN public.invoices i ON i.id=x.invoice_id WHERE x.id=p_record_uuid;
    WHEN 'return_items' THEN SELECT r.store_id INTO v_store FROM public.return_items x JOIN public.sales_returns r ON r.id=x.return_id WHERE x.id=p_record_uuid;
    WHEN 'purchase_return_items' THEN SELECT r.store_id INTO v_store FROM public.purchase_return_items x JOIN public.purchase_returns r ON r.id=x.return_id WHERE x.id=p_record_uuid;
    WHEN 'customer_payments' THEN SELECT c.store_id INTO v_store FROM public.customer_payments x JOIN public.customers c ON c.id=x.customer_id WHERE x.id=p_record_uuid;
    WHEN 'customer_ledgers' THEN SELECT c.store_id INTO v_store FROM public.customer_ledgers x JOIN public.customers c ON c.id=x.customer_id WHERE x.id=p_record_uuid;
    WHEN 'supplier_payments' THEN SELECT s.store_id INTO v_store FROM public.supplier_payments x JOIN public.suppliers s ON s.id=x.supplier_id WHERE x.id=p_record_uuid;
    WHEN 'supplier_ledger' THEN SELECT s.store_id INTO v_store FROM public.supplier_ledger x JOIN public.suppliers s ON s.id=x.supplier_id WHERE x.id=p_record_uuid;
    WHEN 'payment_allocations' THEN SELECT i.store_id INTO v_store FROM public.payment_allocations x JOIN public.invoices i ON i.id=x.invoice_id WHERE x.id=p_record_uuid;
    ELSE RAISE EXCEPTION 'Table % is not enabled for sync conflict identity validation',p_table_name;
  END CASE;
  RETURN v_store;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_sync_entity_store(TEXT,UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.validate_sync_conflict_store_payload()
RETURNS TRIGGER AS $$
DECLARE v_target_store UUID;
BEGIN
  IF NEW.local_record_json IS NULL OR jsonb_typeof(NEW.local_record_json)<>'object'
     OR NEW.remote_record_json IS NULL OR jsonb_typeof(NEW.remote_record_json)<>'object' THEN
    RAISE EXCEPTION 'Sync conflict snapshots must be JSON objects';
  END IF;
  IF (NEW.local_record_json ? 'store_id'
      AND NULLIF(NEW.local_record_json->>'store_id','')::UUID IS DISTINCT FROM NEW.store_id)
     OR (NEW.remote_record_json ? 'store_id'
      AND NULLIF(NEW.remote_record_json->>'store_id','')::UUID IS DISTINCT FROM NEW.store_id)
     OR (NEW.local_record_json ? 'id'
      AND NULLIF(NEW.local_record_json->>'id','')::UUID IS DISTINCT FROM NEW.record_uuid)
     OR (NEW.remote_record_json ? 'id'
      AND NULLIF(NEW.remote_record_json->>'id','')::UUID IS DISTINCT FROM NEW.record_uuid) THEN
    RAISE EXCEPTION 'Sync conflict snapshots must preserve the conflict record identity and store';
  END IF;
  -- Role grants are deliberately excluded from generic conflict mutation and
  -- do not have a single-row UUID key; retain their conflict record but never resolve it generically.
  IF NEW.table_name<>'user_roles' THEN
    v_target_store:=public.resolve_sync_entity_store(NEW.table_name,NEW.record_uuid);
    IF v_target_store IS NULL OR v_target_store IS DISTINCT FROM NEW.store_id THEN
      RAISE EXCEPTION 'Sync conflict target must exist in the same store';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

DROP TRIGGER IF EXISTS trg_sync_cursors_device_store ON public.sync_cursors;
CREATE TRIGGER trg_sync_cursors_device_store BEFORE INSERT OR UPDATE ON public.sync_cursors
FOR EACH ROW EXECUTE FUNCTION public.validate_sync_device_store();

DROP TRIGGER IF EXISTS trg_sync_outbox_device_store ON public.sync_outbox;
CREATE TRIGGER trg_sync_outbox_device_store BEFORE INSERT OR UPDATE ON public.sync_outbox
FOR EACH ROW EXECUTE FUNCTION public.validate_sync_device_store();

DROP TRIGGER IF EXISTS trg_sync_log_device_store ON public.sync_log;
CREATE TRIGGER trg_sync_log_device_store BEFORE INSERT OR UPDATE ON public.sync_log
FOR EACH ROW EXECUTE FUNCTION public.validate_sync_device_store();

DROP TRIGGER IF EXISTS trg_audit_logs_device_store ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_device_store BEFORE INSERT OR UPDATE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.validate_sync_device_store();

DROP TRIGGER IF EXISTS trg_tombstones_target_store ON public.tombstones;
CREATE TRIGGER trg_tombstones_target_store BEFORE INSERT OR UPDATE ON public.tombstones
FOR EACH ROW EXECUTE FUNCTION public.validate_tombstone_target_store();

DROP TRIGGER IF EXISTS trg_sync_conflicts_target_store ON public.sync_conflicts;
CREATE TRIGGER trg_sync_conflicts_target_store BEFORE INSERT OR UPDATE ON public.sync_conflicts
FOR EACH ROW EXECUTE FUNCTION public.validate_sync_conflict_store_payload();

DROP TRIGGER IF EXISTS trg_devices_store_immutable_with_history ON public.devices;
CREATE TRIGGER trg_devices_store_immutable_with_history BEFORE UPDATE OF store_id ON public.devices
FOR EACH ROW EXECUTE FUNCTION public.prevent_device_store_reassignment();

-- Validate existing tombstone and conflict identities before installing the new contract.
DO $record_preflight$
DECLARE
  r RECORD;
  v_target_store UUID;
BEGIN
  FOR r IN SELECT store_id,table_name,record_uuid FROM public.tombstones LOOP
    IF r.table_name NOT IN ('categories','brands','products','customers','suppliers') THEN
      RAISE EXCEPTION 'Existing tombstone table % is outside the supported soft-delete allowlist',r.table_name;
    END IF;
    EXECUTE format('SELECT store_id FROM public.%I WHERE id=$1',r.table_name)
      INTO v_target_store USING r.record_uuid;
    IF v_target_store IS NULL OR v_target_store IS DISTINCT FROM r.store_id THEN
      RAISE EXCEPTION 'Existing tombstone target %/% is missing or belongs to another store',r.table_name,r.record_uuid;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.sync_conflicts sc
    WHERE (sc.local_record_json ? 'store_id'
       AND NULLIF(sc.local_record_json->>'store_id','')::UUID IS DISTINCT FROM sc.store_id)
       OR (sc.remote_record_json ? 'store_id'
       AND NULLIF(sc.remote_record_json->>'store_id','')::UUID IS DISTINCT FROM sc.store_id)
       OR (sc.local_record_json ? 'id'
       AND NULLIF(sc.local_record_json->>'id','')::UUID IS DISTINCT FROM sc.record_uuid)
       OR (sc.remote_record_json ? 'id'
       AND NULLIF(sc.remote_record_json->>'id','')::UUID IS DISTINCT FROM sc.record_uuid)
  ) THEN RAISE EXCEPTION 'Existing sync_conflicts contain snapshots with mismatched record/store identity'; END IF;
END
$record_preflight$;

-- Validate historical device links before accepting the new trigger contract.
DO $sync_preflight$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.sync_cursors sc
    LEFT JOIN public.devices d ON d.id::TEXT=sc.device_id
    WHERE d.id IS NULL OR d.store_id IS DISTINCT FROM sc.store_id
  ) THEN RAISE EXCEPTION 'Existing sync_cursors contain unregistered or cross-store devices'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.sync_outbox so
    LEFT JOIN public.devices d ON d.id::TEXT=so.device_id
    WHERE d.id IS NULL OR d.store_id IS DISTINCT FROM so.store_id
  ) THEN RAISE EXCEPTION 'Existing sync_outbox contains unregistered or cross-store devices'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.sync_log sl
    LEFT JOIN public.devices d ON d.id::TEXT=sl.device_id
    WHERE d.id IS NULL OR d.store_id IS DISTINCT FROM sl.store_id
  ) THEN RAISE EXCEPTION 'Existing sync_log contains unregistered or cross-store devices'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.audit_logs al
    LEFT JOIN public.devices d ON d.id::TEXT=al.device_id
    WHERE al.device_id IS NOT NULL AND (d.id IS NULL OR d.store_id IS DISTINCT FROM al.store_id)
  ) THEN RAISE EXCEPTION 'Existing audit_logs contain unregistered or cross-store devices'; END IF;
END
$sync_preflight$;

COMMIT;
