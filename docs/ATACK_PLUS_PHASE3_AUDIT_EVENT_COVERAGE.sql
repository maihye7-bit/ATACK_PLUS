-- Phase 3 audit event coverage:
-- capture authenticated business and administration mutations in the append-only audit log.
BEGIN;

CREATE OR REPLACE FUNCTION public.audit_business_row_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $audit_business$
DECLARE
  v_row JSONB;
  v_old JSONB;
  v_new JSONB;
  v_store_id UUID;
  v_actor_id UUID;
  v_entity_id UUID;
  v_action TEXT;
BEGIN
  v_row := CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  v_entity_id := NULLIF(v_row->>'id','')::UUID;

  IF TG_TABLE_NAME='stores' THEN
    v_store_id := v_entity_id;
  ELSIF v_row ? 'store_id' THEN
    v_store_id := NULLIF(v_row->>'store_id','')::UUID;
  ELSIF TG_TABLE_NAME='customer_payments' THEN
    SELECT store_id INTO v_store_id FROM public.customers
     WHERE id=NULLIF(v_row->>'customer_id','')::UUID;
  ELSIF TG_TABLE_NAME='supplier_payments' THEN
    SELECT store_id INTO v_store_id FROM public.suppliers
     WHERE id=NULLIF(v_row->>'supplier_id','')::UUID;
  ELSIF TG_TABLE_NAME='user_roles' THEN
    SELECT store_id INTO v_store_id FROM public.users
     WHERE id=NULLIF(v_row->>'user_id','')::UUID;
  ELSE
    RAISE EXCEPTION 'Audit store resolution is not defined for %',TG_TABLE_NAME;
  END IF;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Cannot resolve audit store for %.%',TG_TABLE_SCHEMA,TG_TABLE_NAME;
  END IF;

  IF auth.uid() IS NOT NULL THEN
    SELECT u.id INTO v_actor_id FROM public.users u
     WHERE u.auth_user_id=auth.uid() AND u.store_id=v_store_id AND u.is_active=TRUE
     LIMIT 1;
  END IF;

  IF v_actor_id IS NULL THEN
    v_actor_id := COALESCE(
      NULLIF(v_row->>'created_by','')::UUID,
      NULLIF(v_row->>'user_id','')::UUID,
      NULLIF(v_row->>'received_by','')::UUID,
      NULLIF(v_row->>'changed_by','')::UUID,
      NULLIF(v_row->>'granted_by','')::UUID
    );
    IF v_actor_id IS NOT NULL AND NOT EXISTS(
      SELECT 1 FROM public.users u WHERE u.id=v_actor_id AND u.store_id=v_store_id
    ) THEN
      v_actor_id := NULL;
    END IF;
  END IF;

  -- Background maintenance without an attributable application user is not
  -- misattributed to another person; it is left to operational/system logs.
  IF v_actor_id IS NULL THEN
    IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF TG_OP='INSERT' THEN
    v_action := 'CREATE';
    v_new := v_row - ARRAY[
      'password_hash','auth_user_id','failed_login_attempts','locked_until',
      'last_login_at','password_changed_at','device_sync_id','is_synced',
      'sync_status','synced_at'
    ];
  ELSIF TG_OP='DELETE' THEN
    v_action := 'DELETE';
    v_old := v_row - ARRAY[
      'password_hash','auth_user_id','failed_login_attempts','locked_until',
      'last_login_at','password_changed_at','device_sync_id','is_synced',
      'sync_status','synced_at'
    ];
  ELSE
    v_old := to_jsonb(OLD) - ARRAY[
      'password_hash','auth_user_id','failed_login_attempts','locked_until',
      'last_login_at','password_changed_at','device_sync_id','is_synced',
      'sync_status','synced_at','updated_at'
    ];
    v_new := to_jsonb(NEW) - ARRAY[
      'password_hash','auth_user_id','failed_login_attempts','locked_until',
      'last_login_at','password_changed_at','device_sync_id','is_synced',
      'sync_status','synced_at','updated_at'
    ];
    IF v_old IS NOT DISTINCT FROM v_new THEN
      RETURN NEW;
    END IF;
    IF (to_jsonb(NEW)->>'status' IN ('CANCELLED','DELETED'))
       AND (to_jsonb(OLD)->>'status' IS DISTINCT FROM to_jsonb(NEW)->>'status') THEN
      v_action := 'VOID';
    ELSIF (to_jsonb(OLD)->>'is_active'='true')
       AND (to_jsonb(NEW)->>'is_active'='false') THEN
      v_action := 'VOID';
    ELSE
      v_action := 'UPDATE';
    END IF;
  END IF;

  INSERT INTO public.audit_logs(
    store_id,user_id,entity_type,entity_id,action,old_values_json,new_values_json
  ) VALUES (
    v_store_id,v_actor_id,TG_TABLE_NAME,v_entity_id,v_action,v_old,v_new
  );

  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$audit_business$;

REVOKE ALL ON FUNCTION public.audit_business_row_change() FROM PUBLIC,anon,authenticated,service_role;

-- Explicit top-level entities only: avoid duplicate line-item and ledger noise.
-- Purchase receipt and amendment RPCs already emit their own domain-specific audit events.
DO $audit_triggers$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'users','devices','user_roles',
    'categories','brands','products','customers','suppliers',
    'invoices','purchases','sales_returns',
    'customer_payments','supplier_payments',
    'expenses','revenues',
    'purchase_returns','stock_adjustments'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_business_row ON public.%I',t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit_business_row AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.audit_business_row_change()',
      t
    );
  END LOOP;
END
$audit_triggers$;

COMMIT;
