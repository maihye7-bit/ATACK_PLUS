-- Phase 3 audit and synchronization observability access regressions.
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES ('30000000-0000-4000-8000-000000000003',
        '20000000-0000-4000-8000-000000000003',
        '10000000-0000-4000-8000-000000000001',
        'phase3_audit_cashier','Phase 3 Audit Cashier',TRUE)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.user_roles(user_id,role_id)
VALUES ('30000000-0000-4000-8000-000000000003','cashier')
ON CONFLICT DO NOTHING;

INSERT INTO public.audit_logs(id,store_id,user_id,entity_type,entity_id,action,new_values_json)
VALUES
 ('97000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001','audit_test','97000000-0000-4000-8000-000000000011',
  'CREATE','{"fixture":true}'),
 ('97000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002',
  '30000000-0000-4000-8000-000000000002','audit_test','97000000-0000-4000-8000-000000000012',
  'CREATE','{"fixture":true}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.sync_log(id,store_id,device_id,operation,status,records_processed)
VALUES
 ('98000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',
  '91000000-0000-4000-8000-000000000001','PULL','SUCCESS',1),
 ('98000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002',
  '92000000-0000-4000-8000-000000000002','PULL','SUCCESS',1)
ON CONFLICT (id) DO NOTHING;

DO $audit_acl$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['audit_logs','sync_log','sync_outbox','sync_conflicts'] LOOP
    IF NOT has_table_privilege('authenticated',format('public.%I',t),'SELECT') THEN
      RAISE EXCEPTION 'authenticated cannot SELECT %',t;
    END IF;
    IF EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,acldefault('r',c.relowner))) a
      WHERE n.nspname='public' AND c.relname=t AND a.grantee=0
        AND a.privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')
    ) THEN RAISE EXCEPTION 'PUBLIC retains write ACL on %',t; END IF;
    IF has_table_privilege('authenticated',format('public.%I',t),'INSERT')
       OR has_table_privilege('authenticated',format('public.%I',t),'UPDATE')
       OR has_table_privilege('authenticated',format('public.%I',t),'DELETE')
       OR has_table_privilege('authenticated',format('public.%I',t),'TRUNCATE') THEN
      RAISE EXCEPTION 'authenticated retains direct write privilege on %',t;
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
             WHERE n.nspname='public' AND c.relname=t) THEN
      RAISE EXCEPTION 'RLS is not enabled on %',t;
    END IF;
  END LOOP;
  IF has_table_privilege('authenticated','public.change_log','SELECT')
     OR has_table_privilege('authenticated','public.processed_operations','SELECT')
     OR has_table_privilege('authenticated','public.sync_cursors','SELECT')
     OR has_table_privilege('authenticated','public.store_sync_counters','SELECT')
     OR has_table_privilege('authenticated','public.tombstones','SELECT') THEN
    RAISE EXCEPTION 'Internal sync state is directly readable by authenticated';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.role_permissions rp
      JOIN public.roles r ON r.id=rp.role_id
      JOIN public.permissions p ON p.id=rp.permission_id
      WHERE r.id='owner' AND p.code='audit.read')
     OR NOT EXISTS (SELECT 1 FROM public.role_permissions rp
      JOIN public.roles r ON r.id=rp.role_id
      JOIN public.permissions p ON p.id=rp.permission_id
      WHERE r.id='admin' AND p.code='audit.read')
     OR EXISTS (SELECT 1 FROM public.role_permissions rp
      JOIN public.roles r ON r.id=rp.role_id
      JOIN public.permissions p ON p.id=rp.permission_id
      WHERE r.id NOT IN ('owner','admin') AND p.code='audit.read') THEN
    RAISE EXCEPTION 'audit.read role assignment is not least-privilege';
  END IF;
  RAISE NOTICE 'PASS: audit and sync observability ACLs, RLS, and least-privilege role mapping';
END
$audit_acl$;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_visibility$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.audit_logs WHERE entity_type='audit_test';
  IF n<>1 OR EXISTS(SELECT 1 FROM public.audit_logs WHERE store_id='10000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Audit reader can see another store or misses its own audit record';
  END IF;
  SELECT count(*) INTO n FROM public.sync_log;
  IF n<>1 THEN RAISE EXCEPTION 'Sync manager cannot see only its own sync log'; END IF;
  RAISE NOTICE 'PASS: owner audit and sync-log visibility is store-scoped';
END
$owner_visibility$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000003',TRUE);
SET LOCAL ROLE authenticated;
DO $cashier_denial$
DECLARE n INTEGER; denied BOOLEAN:=FALSE;
BEGIN
  SELECT count(*) INTO n FROM public.audit_logs;
  IF n<>0 THEN RAISE EXCEPTION 'Cashier can read audit logs without audit.read'; END IF;
  SELECT count(*) INTO n FROM public.sync_log;
  IF n<>0 THEN RAISE EXCEPTION 'Cashier can read sync logs without sync.manage'; END IF;
  BEGIN
    INSERT INTO public.audit_logs(store_id,user_id,action)
    VALUES('10000000-0000-4000-8000-000000000001',
           '30000000-0000-4000-8000-000000000003','CREATE');
  EXCEPTION WHEN insufficient_privilege THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Cashier direct audit insert was not denied'; END IF;
  RAISE NOTICE 'PASS: non-privileged user cannot read audit/sync logs or write audit records';
END
$cashier_denial$;
ROLLBACK;

DO $append_only$
DECLARE denied BOOLEAN:=FALSE;
BEGIN
  BEGIN
    UPDATE public.audit_logs SET new_values_json='{"tampered":true}'
     WHERE id='97000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Audit log UPDATE was not blocked by append-only trigger'; END IF;
  denied:=FALSE;
  BEGIN
    DELETE FROM public.audit_logs WHERE id='97000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Audit log DELETE was not blocked by append-only trigger'; END IF;
  RAISE NOTICE 'PASS: audit log is append-only even for privileged database roles';
END
$append_only$;
