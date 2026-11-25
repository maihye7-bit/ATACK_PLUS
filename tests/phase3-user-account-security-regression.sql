-- Controlled user profile creation/update security regressions.
INSERT INTO auth.users(id)
VALUES ('20000000-0000-4000-8000-000000000009')
ON CONFLICT (id) DO NOTHING;

DO $user_acl$
BEGIN
  IF has_table_privilege('authenticated','public.users','INSERT')
     OR has_table_privilege('authenticated','public.users','UPDATE')
     OR has_table_privilege('authenticated','public.users','DELETE')
     OR has_table_privilege('authenticated','public.users','TRUNCATE') THEN
    RAISE EXCEPTION 'authenticated retains direct user account write privileges';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'public.create_store_user_profile(uuid,text,text,text,text,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated',
       'public.update_store_user_profile(uuid,text,text,text,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'Controlled user profile RPCs are not executable by authenticated';
  END IF;
  RAISE NOTICE 'PASS: direct user table writes are revoked and controlled profile RPCs are granted';
END
$user_acl$;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_user_management$
DECLARE v_user UUID; denied BOOLEAN:=FALSE; v_auth UUID; v_name TEXT; v_active BOOLEAN; v_error TEXT;
BEGIN
  v_user:=public.create_store_user_profile(
    '20000000-0000-4000-8000-000000000009',
    'managed_cashier','Managed Cashier','cashier','cashier@example.test','0555000009'
  );
  IF NOT EXISTS(SELECT 1 FROM public.users WHERE id=v_user
      AND store_id='10000000-0000-4000-8000-000000000001'
      AND auth_user_id='20000000-0000-4000-8000-000000000009')
     OR NOT EXISTS(SELECT 1 FROM public.user_roles
      WHERE user_id=v_user AND role_id='cashier') THEN
    RAISE EXCEPTION 'Owner-created user profile or initial role was not persisted';
  END IF;

  PERFORM public.update_store_user_profile(
    v_user,'Managed Cashier Updated','cashier-updated@example.test','0555000010',TRUE
  );
  SELECT auth_user_id,full_name,is_active INTO v_auth,v_name,v_active
    FROM public.users WHERE id=v_user;
  IF v_auth IS DISTINCT FROM '20000000-0000-4000-8000-000000000009'::UUID
     OR v_name IS DISTINCT FROM 'Managed Cashier Updated' OR v_active IS NOT TRUE THEN
    RAISE EXCEPTION 'Profile update changed protected identity or failed to persist';
  END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.create_store_user_profile(
      '20000000-0000-4000-8000-000000000010',
      'invalid_auth_user','Invalid Auth User','cashier',NULL,NULL
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Auth identity does not exist in Supabase Auth%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'User profile was created for an Auth identity that does not exist'; END IF;

  denied:=FALSE;
  BEGIN
    INSERT INTO public.users(auth_user_id,store_id,username,full_name)
    VALUES('20000000-0000-4000-8000-000000000010',
           '10000000-0000-4000-8000-000000000001','direct_user_insert','Direct User');
  EXCEPTION WHEN insufficient_privilege THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Direct user INSERT was not denied'; END IF;

  denied:=FALSE;
  BEGIN
    UPDATE public.users SET auth_user_id='20000000-0000-4000-8000-000000000010'
     WHERE id=v_user;
  EXCEPTION WHEN insufficient_privilege THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Direct auth_user_id mutation was not denied'; END IF;

  denied:=FALSE;
  BEGIN
    DELETE FROM public.users WHERE id=v_user;
  EXCEPTION WHEN insufficient_privilege THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Direct user DELETE was not denied'; END IF;

  IF NOT EXISTS(SELECT 1 FROM public.audit_logs
    WHERE entity_type='users' AND entity_id=v_user AND action='CREATE')
     OR NOT EXISTS(SELECT 1 FROM public.audit_logs
    WHERE entity_type='users' AND entity_id=v_user AND action='UPDATE') THEN
    RAISE EXCEPTION 'User create/update operations were not audited';
  END IF;
  RAISE NOTICE 'PASS: owner can provision Auth-backed profiles, update safe fields, and cannot mutate protected identity directly';
END
$owner_user_management$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000005',TRUE);
SET LOCAL ROLE authenticated;
DO $admin_user_limits$
DECLARE denied BOOLEAN:=FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM public.create_store_user_profile(
      '20000000-0000-4000-8000-000000000010',
      'admin_cannot_create_owner','Admin Cannot Create Owner','owner',NULL,NULL
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Could not grant initial user role%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Admin created a user with owner-level permissions'; END IF;
  IF EXISTS(SELECT 1 FROM public.users WHERE auth_user_id='20000000-0000-4000-8000-000000000010') THEN
    RAISE EXCEPTION 'Failed elevated-role provisioning left a partial user row';
  END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.update_store_user_profile(
      '30000000-0000-4000-8000-000000000001',
      'Owner Account','owner@example.test',NULL,FALSE
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Cannot deactivate a user holding permissions the caller does not hold%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Admin deactivated an owner holding permissions it does not have'; END IF;
  RAISE NOTICE 'PASS: admin cannot provision elevated owner role or deactivate a more-privileged owner';
END
$admin_user_limits$;
ROLLBACK;
