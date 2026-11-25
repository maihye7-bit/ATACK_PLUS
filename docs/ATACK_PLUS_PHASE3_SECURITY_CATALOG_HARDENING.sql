-- Phase 3 complete security catalog hardening.
-- Normalize SECURITY DEFINER execution context and remove implicit PUBLIC/anon entry points.
-- Existing explicit authenticated/service_role grants are preserved.
BEGIN;

DO $security_catalog$
DECLARE
  r RECORD;
  v_signature TEXT;
BEGIN
  FOR r IN
    SELECT p.oid, n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) AS identity_args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosecdef
     ORDER BY p.proname, p.oid
  LOOP
    v_signature := format('%I.%I(%s)', r.nspname, r.proname, r.identity_args);
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', v_signature);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', v_signature);
  END LOOP;
END
$security_catalog$;

COMMIT;
