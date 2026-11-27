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

DO $sync_fks$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.sync_conflicts'::regclass AND conname='fk_sync_conflicts_resolver_store') THEN
    ALTER TABLE public.sync_conflicts ADD CONSTRAINT fk_sync_conflicts_resolver_store
      FOREIGN KEY(resolved_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.tombstones'::regclass AND conname='fk_tombstones_deleter_store') THEN
    ALTER TABLE public.tombstones ADD CONSTRAINT fk_tombstones_deleter_store
      FOREIGN KEY(deleted_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.audit_logs'::regclass AND conname='fk_audit_logs_actor_store') THEN
    ALTER TABLE public.audit_logs ADD CONSTRAINT fk_audit_logs_actor_store
      FOREIGN KEY(user_id,store_id) REFERENCES public.users(id,store_id);
  END IF;
END
$sync_fks$;

CREATE OR REPLACE FUNCTION public.validate_sync_device_store()
RETURNS TRIGGER AS $$
DECLARE v_device_store UUID;
BEGIN
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
  IF NEW.table_name IN ('categories','brands','products','customers','suppliers') THEN
    EXECUTE format('SELECT store_id FROM public.%I WHERE id=$1 FOR SHARE',NEW.table_name)
      INTO v_target_store USING NEW.record_uuid;
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
