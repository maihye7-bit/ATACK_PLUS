-- Phase 3 security hardening, part 4:
-- remove direct user-account mutation and provide controlled profile provisioning.
BEGIN;

REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON TABLE public.users FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.users TO authenticated;

CREATE OR REPLACE FUNCTION public.create_store_user_profile(
  p_auth_user_id UUID,
  p_username TEXT,
  p_full_name TEXT,
  p_role_id TEXT DEFAULT 'cashier',
  p_email TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,auth,pg_temp
AS $create_store_user$
DECLARE
  v_store_id UUID;
  v_user_id UUID;
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  v_store_id:=public.current_user_store_id();
  IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id,'users.manage') THEN
    RAISE EXCEPTION 'users.manage permission required';
  END IF;
  IF p_auth_user_id IS NULL OR NULLIF(btrim(p_username),'') IS NULL
     OR NULLIF(btrim(p_full_name),'') IS NULL
     OR NULLIF(btrim(p_role_id),'') IS NULL THEN
    RAISE EXCEPTION 'Auth identity, username, full name and role are required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM auth.users au WHERE au.id=p_auth_user_id) THEN
    RAISE EXCEPTION 'Auth identity does not exist in Supabase Auth';
  END IF;
  IF EXISTS(SELECT 1 FROM public.users u WHERE u.auth_user_id=p_auth_user_id) THEN
    RAISE EXCEPTION 'Auth identity is already linked to an application user';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.roles r WHERE r.id=p_role_id AND r.is_active=TRUE) THEN
    RAISE EXCEPTION 'Requested role is missing or inactive';
  END IF;

  INSERT INTO public.users(
    auth_user_id,store_id,username,password_hash,full_name,email,phone,is_active
  ) VALUES (
    p_auth_user_id,v_store_id,btrim(p_username),NULL,btrim(p_full_name),
    NULLIF(btrim(p_email),''),NULLIF(btrim(p_phone),''),TRUE
  ) RETURNING id INTO v_user_id;

  v_result:=public.manage_store_user_role(v_user_id,p_role_id,'GRANT');
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Could not grant initial user role: %',v_result;
  END IF;
  RETURN v_user_id;
END;
$create_store_user$;

CREATE OR REPLACE FUNCTION public.update_store_user_profile(
  p_target_user_id UUID,
  p_full_name TEXT,
  p_email TEXT,
  p_phone TEXT,
  p_is_active BOOLEAN
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $update_store_user$
DECLARE
  v_store_id UUID;
  v_actor_id UUID;
  v_target RECORD;
  v_missing_permissions TEXT[];
  v_active_owners INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  v_store_id:=public.current_user_store_id();
  IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id,'users.manage') THEN
    RAISE EXCEPTION 'users.manage permission required';
  END IF;
  SELECT id INTO v_actor_id FROM public.users
   WHERE auth_user_id=auth.uid() AND store_id=v_store_id AND is_active=TRUE;
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Active store user not found'; END IF;
  IF NULLIF(btrim(p_full_name),'') IS NULL OR p_is_active IS NULL THEN
    RAISE EXCEPTION 'Full name and active status are required';
  END IF;

  SELECT u.id,u.is_active INTO v_target
    FROM public.users u WHERE u.id=p_target_user_id AND u.store_id=v_store_id
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target user does not exist in this store'; END IF;

  IF p_is_active=FALSE AND v_target.is_active=TRUE THEN
    IF p_target_user_id=v_actor_id THEN
      RAISE EXCEPTION 'A user cannot deactivate their own account';
    END IF;

    SELECT array_agg(DISTINCT p.code ORDER BY p.code) INTO v_missing_permissions
      FROM public.user_roles target_ur
      JOIN public.role_permissions target_rp ON target_rp.role_id=target_ur.role_id
      JOIN public.permissions p ON p.id=target_rp.permission_id
     WHERE target_ur.user_id=p_target_user_id
       AND NOT EXISTS(
         SELECT 1 FROM public.user_roles actor_ur
         JOIN public.role_permissions actor_rp ON actor_rp.role_id=actor_ur.role_id
         WHERE actor_ur.user_id=v_actor_id
           AND actor_rp.permission_id=target_rp.permission_id
       );
    IF COALESCE(cardinality(v_missing_permissions),0)>0 THEN
      RAISE EXCEPTION 'Cannot deactivate a user holding permissions the caller does not hold: %',
        array_to_string(v_missing_permissions,', ');
    END IF;

    IF EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=p_target_user_id AND role_id='owner') THEN
      SELECT count(*) INTO v_active_owners
        FROM public.users u JOIN public.user_roles ur ON ur.user_id=u.id
       WHERE u.store_id=v_store_id AND u.is_active=TRUE AND ur.role_id='owner';
      IF v_active_owners<=1 THEN RAISE EXCEPTION 'Cannot deactivate the store''s last active owner'; END IF;
    END IF;
  END IF;

  UPDATE public.users
     SET full_name=btrim(p_full_name),
         email=NULLIF(btrim(p_email),''),
         phone=NULLIF(btrim(p_phone),''),
         is_active=p_is_active,
         updated_at=NOW()
   WHERE id=p_target_user_id AND store_id=v_store_id;
  RETURN TRUE;
END;
$update_store_user$;

REVOKE ALL ON FUNCTION public.create_store_user_profile(UUID,TEXT,TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.update_store_user_profile(UUID,TEXT,TEXT,TEXT,BOOLEAN)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.create_store_user_profile(UUID,TEXT,TEXT,TEXT,TEXT,TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_store_user_profile(UUID,TEXT,TEXT,TEXT,BOOLEAN)
  TO authenticated;

COMMIT;
