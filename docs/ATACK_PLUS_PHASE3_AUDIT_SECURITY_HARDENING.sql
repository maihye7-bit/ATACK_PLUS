-- Phase 3 security hardening, part 2:
-- least-privilege access to audit and synchronization observability tables.
BEGIN;

-- Explicit audit visibility permission: owner/admin only.
INSERT INTO public.permissions(code,description)
VALUES ('audit.read','Read the store audit trail')
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.id,p.id
  FROM public.roles r
  CROSS JOIN public.permissions p
 WHERE r.id IN ('owner','admin') AND p.code='audit.read'
ON CONFLICT (role_id,permission_id) DO NOTHING;

-- Audit trail: append-only, visible only to users with audit.read in their store.
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_isolation_all ON public.audit_logs;
DROP POLICY IF EXISTS audit_logs_store_select ON public.audit_logs;
CREATE POLICY audit_logs_store_select ON public.audit_logs
  FOR SELECT TO authenticated
  USING (store_id=public.current_user_store_id()
         AND public.has_store_permission(store_id,'audit.read'));
DROP POLICY IF EXISTS audit_logs_deny_insert ON public.audit_logs;
DROP POLICY IF EXISTS audit_logs_deny_update ON public.audit_logs;
DROP POLICY IF EXISTS audit_logs_deny_delete ON public.audit_logs;
CREATE POLICY audit_logs_deny_insert ON public.audit_logs
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (FALSE);
CREATE POLICY audit_logs_deny_update ON public.audit_logs
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (FALSE) WITH CHECK (FALSE);
CREATE POLICY audit_logs_deny_delete ON public.audit_logs
  AS RESTRICTIVE FOR DELETE TO authenticated USING (FALSE);
REVOKE ALL ON TABLE public.audit_logs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.audit_logs TO authenticated;

-- Audit records must never be rewritten or deleted, including by trusted API roles.
CREATE OR REPLACE FUNCTION public.reject_audit_log_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $audit_immutable$
BEGIN
  RAISE EXCEPTION 'audit_logs is append-only; % is forbidden',TG_OP;
END;
$audit_immutable$;

DROP TRIGGER IF EXISTS trg_audit_logs_immutable_update_delete ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_immutable_update_delete
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.reject_audit_log_mutation();

DROP TRIGGER IF EXISTS trg_audit_logs_immutable_truncate ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_immutable_truncate
BEFORE TRUNCATE ON public.audit_logs
FOR EACH STATEMENT EXECUTE FUNCTION public.reject_audit_log_mutation();

REVOKE ALL ON FUNCTION public.reject_audit_log_mutation() FROM PUBLIC,anon,authenticated,service_role;

-- Synchronization activity log: readable only by sync managers; never directly writable.
ALTER TABLE public.sync_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_isolation_select_sync_log ON public.sync_log;
DROP POLICY IF EXISTS store_isolation_all ON public.sync_log;
DROP POLICY IF EXISTS sync_log_store_select ON public.sync_log;
CREATE POLICY sync_log_store_select ON public.sync_log
  FOR SELECT TO authenticated
  USING (store_id=public.current_user_store_id()
         AND public.has_store_permission(store_id,'sync.manage'));
DROP POLICY IF EXISTS sync_log_deny_insert ON public.sync_log;
DROP POLICY IF EXISTS sync_log_deny_update ON public.sync_log;
DROP POLICY IF EXISTS sync_log_deny_delete ON public.sync_log;
CREATE POLICY sync_log_deny_insert ON public.sync_log
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (FALSE);
CREATE POLICY sync_log_deny_update ON public.sync_log
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (FALSE) WITH CHECK (FALSE);
CREATE POLICY sync_log_deny_delete ON public.sync_log
  AS RESTRICTIVE FOR DELETE TO authenticated USING (FALSE);
REVOKE ALL ON TABLE public.sync_log FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.sync_log TO authenticated;

-- Internal synchronization state is accessed through SECURITY DEFINER RPCs only.
-- sync_outbox and sync_conflicts are exposed read-only to sync managers.
DO $system_tables$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'change_log','processed_operations','sync_cursors',
    'store_sync_counters','tombstones'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['sync_outbox','sync_conflicts'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('DROP POLICY IF EXISTS store_isolation_select_%I ON public.%I',t,t);
    EXECUTE format('DROP POLICY IF EXISTS store_isolation_all ON public.%I',t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_store_select',t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (store_id=public.current_user_store_id() AND public.has_store_permission(store_id,''sync.manage''))',
      t||'_manager_select',t
    );
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',t);
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated',t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (FALSE)',
      t||'_deny_insert',t
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (FALSE) WITH CHECK (FALSE)',
      t||'_deny_update',t
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (FALSE)',
      t||'_deny_delete',t
    );
  END LOOP;
END
$system_tables$;

COMMIT;
