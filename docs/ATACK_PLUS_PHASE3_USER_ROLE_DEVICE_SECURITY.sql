-- Phase 3 security hardening, part 3:
-- prevent privilege escalation through user_roles and restrict device visibility.
BEGIN;

CREATE OR REPLACE FUNCTION public.user_belongs_to_current_store(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $user_store_check$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
     WHERE u.id=p_user_id
       AND u.store_id=public.current_user_store_id()
  );
$user_store_check$;
REVOKE ALL ON FUNCTION public.user_belongs_to_current_store(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.user_belongs_to_current_store(UUID) TO authenticated;

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_isolation_select_user_roles ON public.user_roles;
DROP POLICY IF EXISTS rbac_insert_user_roles ON public.user_roles;
DROP POLICY IF EXISTS rbac_update_user_roles ON public.user_roles;
DROP POLICY IF EXISTS rbac_delete_user_roles ON public.user_roles;
DROP POLICY IF EXISTS user_roles_manager_select ON public.user_roles;
CREATE POLICY user_roles_manager_select ON public.user_roles
  FOR SELECT TO authenticated
  USING (
    public.user_belongs_to_current_store(user_roles.user_id)
    AND public.has_store_permission(public.current_user_store_id(),'users.manage')
  );
CREATE POLICY user_roles_deny_insert ON public.user_roles
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK(FALSE);
CREATE POLICY user_roles_deny_update ON public.user_roles
  AS RESTRICTIVE FOR UPDATE TO authenticated USING(FALSE) WITH CHECK(FALSE);
CREATE POLICY user_roles_deny_delete ON public.user_roles
  AS RESTRICTIVE FOR DELETE TO authenticated USING(FALSE);
REVOKE ALL ON TABLE public.user_roles FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.user_roles TO authenticated;

-- Only a caller whose effective permissions cover the target role may grant
-- or revoke it. This prevents an admin from granting/revoking owner privileges.
CREATE OR REPLACE FUNCTION public.manage_store_user_role(
  p_target_user_id UUID,
  p_role_id TEXT,
  p_action TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $manage_role$
DECLARE
  v_store_id UUID;
  v_actor_id UUID;
  v_target_store UUID;
  v_target_role_active BOOLEAN;
  v_missing_permissions TEXT[];
  v_remaining_roles INTEGER;
  v_changed INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  v_store_id := public.current_user_store_id();
  IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id,'users.manage') THEN
    RAISE EXCEPTION 'users.manage permission required';
  END IF;
  SELECT u.id INTO v_actor_id FROM public.users u
   WHERE u.auth_user_id=auth.uid() AND u.store_id=v_store_id AND u.is_active=TRUE;
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Active store user not found'; END IF;

  IF p_action NOT IN ('GRANT','REVOKE') THEN
    RAISE EXCEPTION 'Action must be GRANT or REVOKE';
  END IF;
  IF p_target_user_id IS NULL OR NULLIF(btrim(p_role_id),'') IS NULL THEN
    RAISE EXCEPTION 'Target user and role are required';
  END IF;

  SELECT u.store_id INTO v_target_store
    FROM public.users u
   WHERE u.id=p_target_user_id AND u.is_active=TRUE;
  IF v_target_store IS DISTINCT FROM v_store_id THEN
    RAISE EXCEPTION 'Target user is missing, inactive or belongs to another store';
  END IF;
  SELECT r.is_active INTO v_target_role_active
    FROM public.roles r WHERE r.id=p_role_id;
  IF v_target_role_active IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Target role does not exist or is inactive';
  END IF;

  SELECT array_agg(p.code ORDER BY p.code) INTO v_missing_permissions
    FROM public.role_permissions target_rp
    JOIN public.permissions p ON p.id=target_rp.permission_id
   WHERE target_rp.role_id=p_role_id
     AND NOT EXISTS (
       SELECT 1
         FROM public.user_roles actor_ur
         JOIN public.role_permissions actor_rp ON actor_rp.role_id=actor_ur.role_id
        WHERE actor_ur.user_id=v_actor_id
          AND actor_rp.permission_id=target_rp.permission_id
     );
  IF COALESCE(cardinality(v_missing_permissions),0)>0 THEN
    RAISE EXCEPTION 'Cannot manage a role containing permissions the caller does not hold: %',
      array_to_string(v_missing_permissions,', ');
  END IF;

  IF p_action='GRANT' THEN
    INSERT INTO public.user_roles(user_id,role_id,granted_by)
    VALUES(p_target_user_id,p_role_id,v_actor_id)
    ON CONFLICT(user_id,role_id) DO NOTHING;
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    RETURN jsonb_build_object('success',TRUE,'action','GRANT','changed',v_changed=1);
  END IF;

  SELECT count(*) INTO v_remaining_roles
    FROM public.user_roles WHERE user_id=p_target_user_id;
  IF EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=p_target_user_id AND role_id=p_role_id)
     AND v_remaining_roles<=1 THEN
    RAISE EXCEPTION 'Cannot revoke the target user''s final role';
  END IF;

  DELETE FROM public.user_roles
   WHERE user_id=p_target_user_id AND role_id=p_role_id;
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  RETURN jsonb_build_object('success',TRUE,'action','REVOKE','changed',v_changed=1);
END;
$manage_role$;

REVOKE ALL ON FUNCTION public.manage_store_user_role(UUID,TEXT,TEXT)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.manage_store_user_role(UUID,TEXT,TEXT)
  TO authenticated;

-- Device inventory is visible only to store sync managers. Existing restrictive
-- RBAC write policies continue to require sync.manage for mutations.
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_isolation_select_devices ON public.devices;
DROP POLICY IF EXISTS devices_sync_manager_select ON public.devices;
CREATE POLICY devices_sync_manager_select ON public.devices
  FOR SELECT TO authenticated
  USING (store_id=public.current_user_store_id()
         AND public.has_store_permission(store_id,'sync.manage'));
REVOKE ALL ON TABLE public.devices FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.devices TO authenticated;
REVOKE TRUNCATE ON TABLE public.devices FROM PUBLIC,anon,authenticated;

COMMIT;
