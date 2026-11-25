-- Audit event coverage regressions for core master data and administration.
BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);

INSERT INTO public.customers(id,store_id,code,name,is_active)
VALUES ('99000000-0000-4000-8000-000000000001',
        '10000000-0000-4000-8000-000000000001',
        'AUDIT-CUST-001','Audit Event Customer',TRUE);

UPDATE public.customers
   SET name='Audit Event Customer Updated'
 WHERE id='99000000-0000-4000-8000-000000000001';

-- Lifecycle transitions must be represented distinctly: CREATE, VOID, then DELETE.
INSERT INTO public.categories(id,store_id,name,is_active)
VALUES('99000000-0000-4000-8000-000000000004',
       '10000000-0000-4000-8000-000000000001','Audit Lifecycle Category',TRUE);
UPDATE public.categories SET is_active=FALSE
 WHERE id='99000000-0000-4000-8000-000000000004';
DELETE FROM public.categories
 WHERE id='99000000-0000-4000-8000-000000000004';

-- Synchronization metadata alone is intentionally not a business audit event.
UPDATE public.customers SET sync_status='SYNCED'
 WHERE id='99000000-0000-4000-8000-000000000001';

DO $audit_events$
DECLARE
  v_count INTEGER;
  v_create JSONB;
  v_update_old JSONB;
  v_update_new JSONB;
BEGIN
  SELECT count(*) INTO v_count FROM public.audit_logs
   WHERE store_id='10000000-0000-4000-8000-000000000001'
     AND entity_type='customers'
     AND entity_id='99000000-0000-4000-8000-000000000001';
  IF v_count<>2 THEN
    RAISE EXCEPTION 'Expected exactly CREATE and UPDATE audit events, got %',v_count;
  END IF;

  SELECT new_values_json INTO v_create FROM public.audit_logs
   WHERE entity_type='customers' AND entity_id='99000000-0000-4000-8000-000000000001'
     AND action='CREATE';
  IF v_create->>'name' IS DISTINCT FROM 'Audit Event Customer'
     OR v_create ? 'auth_user_id' OR v_create ? 'password_hash' THEN
    RAISE EXCEPTION 'CREATE audit snapshot is incorrect or contains authentication secrets: %',v_create;
  END IF;

  SELECT old_values_json,new_values_json INTO v_update_old,v_update_new
    FROM public.audit_logs
   WHERE entity_type='customers' AND entity_id='99000000-0000-4000-8000-000000000001'
     AND action='UPDATE';
  IF v_update_old->>'name' IS DISTINCT FROM 'Audit Event Customer'
     OR v_update_new->>'name' IS DISTINCT FROM 'Audit Event Customer Updated' THEN
    RAISE EXCEPTION 'UPDATE audit before/after snapshots are incorrect';
  END IF;
  IF (SELECT count(*) FROM public.audit_logs
       WHERE store_id='10000000-0000-4000-8000-000000000001'
         AND entity_type='categories'
         AND entity_id='99000000-0000-4000-8000-000000000004')<>3
     OR NOT EXISTS(SELECT 1 FROM public.audit_logs
       WHERE entity_type='categories' AND entity_id='99000000-0000-4000-8000-000000000004'
         AND action='CREATE' AND new_values_json->>'name'='Audit Lifecycle Category')
     OR NOT EXISTS(SELECT 1 FROM public.audit_logs
       WHERE entity_type='categories' AND entity_id='99000000-0000-4000-8000-000000000004'
         AND action='VOID' AND old_values_json->>'is_active'='true'
         AND new_values_json->>'is_active'='false')
     OR NOT EXISTS(SELECT 1 FROM public.audit_logs
       WHERE entity_type='categories' AND entity_id='99000000-0000-4000-8000-000000000004'
         AND action='DELETE' AND old_values_json->>'name'='Audit Lifecycle Category') THEN
    RAISE EXCEPTION 'Category lifecycle audit events or snapshots are incomplete';
  END IF;
  RAISE NOTICE 'PASS: authenticated business changes are audited with before/after snapshots and no auth secrets or sync-only noise';
END
$audit_events$;

-- Administration changes are attributed to the authenticated actor, while
-- authentication identifiers are excluded from the stored snapshot.
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES ('99000000-0000-4000-8000-000000000002',
        '99000000-0000-4000-8000-000000000003',
        '10000000-0000-4000-8000-000000000001',
        'audit_target_user','Audit Target User',TRUE);

DO $user_audit$
DECLARE v_snapshot JSONB; v_actor UUID;
BEGIN
  SELECT new_values_json,user_id INTO v_snapshot,v_actor
    FROM public.audit_logs
   WHERE entity_type='users' AND entity_id='99000000-0000-4000-8000-000000000002'
     AND action='CREATE';
  IF v_actor IS DISTINCT FROM '30000000-0000-4000-8000-000000000001'::UUID
     OR v_snapshot ? 'auth_user_id' OR v_snapshot ? 'password_hash' THEN
    RAISE EXCEPTION 'User administration audit attribution or secret filtering failed';
  END IF;
  RAISE NOTICE 'PASS: user administration events are attributed and authentication identifiers are excluded';
END
$user_audit$;
ROLLBACK;
