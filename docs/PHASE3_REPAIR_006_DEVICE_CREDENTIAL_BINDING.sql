-- D3.2 / R2: bind sync calls to an authenticated app user and a per-device secret.
-- Device management remains owner-controlled through the existing sync.manage permission.
BEGIN;

CREATE TABLE public.device_credentials (
    device_id UUID PRIMARY KEY REFERENCES public.devices(id) ON DELETE RESTRICT,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    registered_by UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    token_hash TEXT,
    credential_version INTEGER NOT NULL DEFAULT 1 CHECK (credential_version > 0),
    issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT device_credentials_hash_format
      CHECK (token_hash IS NULL OR token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT device_credentials_revocation_state
      CHECK ((token_hash IS NOT NULL AND revoked_at IS NULL)
          OR (token_hash IS NULL AND revoked_at IS NOT NULL))
);

CREATE INDEX idx_device_credentials_store_user
    ON public.device_credentials(store_id, user_id);

ALTER TABLE public.device_credentials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.device_credentials FROM PUBLIC, anon, authenticated, service_role;

-- Device records can be inspected by sync managers, but registration, rotation
-- and revocation must use the audited SECURITY DEFINER lifecycle RPCs.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.devices
    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.assert_sync_device_credential(
    p_store_id UUID,
    p_device_id TEXT,
    p_device_token TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $assert_device$
DECLARE
    v_user_id UUID;
    v_device_uuid UUID;
    v_token_hash TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        IF COALESCE(auth.role(), '') = 'service_role' THEN
            RETURN;
        END IF;
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF p_store_id IS NULL
       OR NULLIF(btrim(p_device_id), '') IS NULL
       OR p_device_token IS NULL
       OR p_device_token !~ '^[0-9a-f]{64}$'
       OR p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    BEGIN
        v_device_uuid := p_device_id::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Device authentication failed';
    END;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    v_token_hash := encode(
        public.atack_digest(convert_to(p_device_token, 'UTF8'), 'sha256'),
        'hex'
    );

    PERFORM 1
      FROM public.devices d
      JOIN public.device_credentials dc
        ON dc.device_id = d.id
       AND dc.store_id = d.store_id
     WHERE d.id = v_device_uuid
       AND d.store_id = p_store_id
       AND dc.user_id = v_user_id
       AND dc.revoked_at IS NULL
       AND dc.token_hash = v_token_hash
     FOR SHARE OF d, dc;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;
END;
$assert_device$;

REVOKE ALL ON FUNCTION public.assert_sync_device_credential(UUID, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.register_sync_device(
    p_target_user_id UUID,
    p_device_name TEXT,
    p_device_type TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $register_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_device_id UUID := gen_random_uuid();
    v_token TEXT;
    v_hash TEXT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;

    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;
    IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Active store user not found'; END IF;

    IF p_target_user_id IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM public.users u
            WHERE u.id = p_target_user_id
              AND u.store_id = v_store_id
              AND u.is_active = TRUE
       ) THEN
        RAISE EXCEPTION 'Target device user must be active in this store';
    END IF;
    IF NULLIF(btrim(p_device_name), '') IS NULL OR length(btrim(p_device_name)) > 120 THEN
        RAISE EXCEPTION 'Device name is required and must not exceed 120 characters';
    END IF;
    IF p_device_type IS NULL OR p_device_type NOT IN ('PHONE', 'TABLET', 'DESKTOP') THEN
        RAISE EXCEPTION 'Unsupported device type';
    END IF;

    -- Two independently generated UUIDs provide a 64-hex-character (256-bit)
    -- high-entropy bearer credential.
    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
    v_hash := encode(public.atack_digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');

    INSERT INTO public.devices(id, store_id, device_name, device_type, is_online)
    VALUES (v_device_id, v_store_id, btrim(p_device_name), p_device_type, FALSE);

    INSERT INTO public.device_credentials(
        device_id, store_id, user_id, registered_by, token_hash,
        credential_version, issued_at
    ) VALUES (
        v_device_id, v_store_id, p_target_user_id, v_actor_id, v_hash, 1, NOW()
    );

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', v_device_id, 'CREATE',
        jsonb_build_object(
            'device_id', v_device_id,
            'device_name', btrim(p_device_name),
            'device_type', p_device_type,
            'assigned_user_id', p_target_user_id,
            'credential_version', 1
        )
    );

    -- The raw credential is returned exactly once and is never stored or audited.
    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', v_device_id,
        'assigned_user_id', p_target_user_id,
        'device_token', v_token,
        'credential_version', 1
    );
END;
$register_device$;

CREATE OR REPLACE FUNCTION public.rotate_sync_device_credential(
    p_device_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $rotate_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_token TEXT;
    v_hash TEXT;
    v_old_version INTEGER;
    v_new_version INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_old_version
      FROM public.device_credentials dc
     WHERE dc.device_id = p_device_id
       AND dc.store_id = v_store_id
       AND dc.revoked_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active device credential not found; revoked devices cannot be reactivated';
    END IF;

    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
    v_hash := encode(public.atack_digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');
    v_new_version := v_old_version + 1;

    UPDATE public.device_credentials
       SET token_hash = v_hash,
           credential_version = v_new_version,
           issued_at = NOW(),
           updated_at = NOW()
     WHERE device_id = p_device_id AND store_id = v_store_id;

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action,
        old_values_json, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', p_device_id, 'UPDATE',
        jsonb_build_object('credential_version', v_old_version, 'credential_state', 'ACTIVE'),
        jsonb_build_object('credential_version', v_new_version, 'credential_state', 'ROTATED')
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', p_device_id,
        'device_token', v_token,
        'credential_version', v_new_version
    );
END;
$rotate_device$;

CREATE OR REPLACE FUNCTION public.revoke_sync_device(
    p_device_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $revoke_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_version INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_version
      FROM public.device_credentials dc
     WHERE dc.device_id = p_device_id AND dc.store_id = v_store_id
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Device credential not found in this store'; END IF;
    IF EXISTS (
        SELECT 1 FROM public.device_credentials dc
         WHERE dc.device_id = p_device_id AND dc.store_id = v_store_id
           AND dc.revoked_at IS NOT NULL
    ) THEN
        RETURN TRUE;
    END IF;

    UPDATE public.device_credentials
       SET token_hash = NULL,
           revoked_at = NOW(),
           updated_at = NOW()
     WHERE device_id = p_device_id AND store_id = v_store_id;

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action,
        old_values_json, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', p_device_id, 'UPDATE',
        jsonb_build_object('credential_version', v_version, 'credential_state', 'ACTIVE'),
        jsonb_build_object('credential_version', v_version, 'credential_state', 'REVOKED')
    );
    RETURN TRUE;
END;
$revoke_device$;

REVOKE ALL ON FUNCTION public.register_sync_device(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rotate_sync_device_credential(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_sync_device(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_sync_device(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rotate_sync_device_credential(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_sync_device(UUID) TO authenticated;

-- Retire the tokenless authenticated RPC signatures. Trusted service_role jobs
-- retain their existing signatures; authenticated clients must use credential overloads.
REVOKE EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.apply_outbox_operation(UUID)
    FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_unsynced_records(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_since_cursor BIGINT,
    p_device_token TEXT
) RETURNS TABLE(
    record_uuid UUID,
    operation TEXT,
    record_json JSONB,
    sync_cursor BIGINT,
    changed_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_pull$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN QUERY
    SELECT * FROM public.get_unsynced_records(
        p_store_id, p_device_id, p_table_name, p_since_cursor
    );
END;
$authenticated_pull$;

CREATE OR REPLACE FUNCTION public.acknowledge_sync_cursor(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_cursor BIGINT,
    p_device_token TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_ack$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN public.acknowledge_sync_cursor(p_store_id, p_device_id, p_table_name, p_cursor);
END;
$authenticated_ack$;

CREATE OR REPLACE FUNCTION public.create_outbox_entry(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_operation TEXT,
    p_record_uuid UUID,
    p_idempotency_key UUID,
    p_record_json JSONB,
    p_device_token TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_outbox$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN public.create_outbox_entry(
        p_store_id, p_device_id, p_table_name, p_operation,
        p_record_uuid, p_idempotency_key, p_record_json
    );
END;
$authenticated_outbox$;

CREATE OR REPLACE FUNCTION public.apply_outbox_operation(
    p_outbox_id UUID,
    p_device_id TEXT,
    p_device_token TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_apply$
DECLARE
    v_store_id UUID;
    v_recorded_device TEXT;
BEGIN
    SELECT o.store_id, o.device_id
      INTO v_store_id, v_recorded_device
      FROM public.sync_outbox o
     WHERE o.id = p_outbox_id;

    IF NOT FOUND THEN
        IF auth.uid() IS NOT NULL THEN
            RAISE EXCEPTION 'Device authentication failed';
        END IF;
        RETURN jsonb_build_object('success', FALSE, 'error', 'Outbox entry not found');
    END IF;
    IF auth.uid() IS NOT NULL
       AND v_store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;
    IF v_recorded_device IS DISTINCT FROM p_device_id THEN
        RAISE EXCEPTION 'Outbox entry is not associated with the authenticated device';
    END IF;

    PERFORM public.assert_sync_device_credential(v_store_id, p_device_id, p_device_token);
    RETURN public.apply_outbox_operation(p_outbox_id);
END;
$authenticated_apply$;

REVOKE ALL ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.apply_outbox_operation(UUID, TEXT, TEXT)
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_outbox_operation(UUID, TEXT, TEXT)
    TO authenticated, service_role;

COMMIT;

       OR p_device_token !~ '^[0-9a-f]{64}
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    v_device_uuid := p_device_id::UUID;
    v_token_hash := encode(
        public.atack_digest(convert_to(p_device_token, 'UTF8'), 'sha256'),
        'hex'
    );

    PERFORM 1
      FROM public.devices d
      JOIN public.device_credentials dc
        ON dc.device_id = d.id
       AND dc.store_id = d.store_id
     WHERE d.id = v_device_uuid
       AND d.store_id = p_store_id
       AND dc.user_id = v_user_id
       AND dc.revoked_at IS NULL
       AND dc.token_hash = v_token_hash
     FOR SHARE OF d, dc;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;
END;
$assert_device$;

REVOKE ALL ON FUNCTION public.assert_sync_device_credential(UUID, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.register_sync_device(
    p_target_user_id UUID,
    p_device_name TEXT,
    p_device_type TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $register_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_device_id UUID := gen_random_uuid();
    v_token TEXT;
    v_hash TEXT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;

    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;
    IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Active store user not found'; END IF;

    IF p_target_user_id IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM public.users u
            WHERE u.id = p_target_user_id
              AND u.store_id = v_store_id
              AND u.is_active = TRUE
       ) THEN
        RAISE EXCEPTION 'Target device user must be active in this store';
    END IF;
    IF NULLIF(btrim(p_device_name), '') IS NULL OR length(btrim(p_device_name)) > 120 THEN
        RAISE EXCEPTION 'Device name is required and must not exceed 120 characters';
    END IF;
    IF p_device_type NOT IN ('PHONE', 'TABLET', 'DESKTOP') THEN
        RAISE EXCEPTION 'Unsupported device type';
    END IF;

    -- Two independently generated UUIDs provide a 256-hex-character? No:
    -- 64 hexadecimal characters (256 bits) of high-entropy bearer credential.
    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
    v_hash := encode(public.atack_digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');

    INSERT INTO public.devices(id, store_id, device_name, device_type, is_online)
    VALUES (v_device_id, v_store_id, btrim(p_device_name), p_device_type, FALSE);

    INSERT INTO public.device_credentials(
        device_id, store_id, user_id, registered_by, token_hash,
        credential_version, issued_at
    ) VALUES (
        v_device_id, v_store_id, p_target_user_id, v_actor_id, v_hash, 1, NOW()
    );

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', v_device_id, 'CREATE',
        jsonb_build_object(
            'device_id', v_device_id,
            'device_name', btrim(p_device_name),
            'device_type', p_device_type,
            'assigned_user_id', p_target_user_id,
            'credential_version', 1
        )
    );

    -- The raw credential is returned exactly once and is never stored or audited.
    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', v_device_id,
        'assigned_user_id', p_target_user_id,
        'device_token', v_token,
        'credential_version', 1
    );
END;
$register_device$;

CREATE OR REPLACE FUNCTION public.rotate_sync_device_credential(
    p_device_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $rotate_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_token TEXT;
    v_hash TEXT;
    v_old_version INTEGER;
    v_new_version INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_old_version
      FROM public.device_credentials dc
     WHERE dc.device_id = p_device_id
       AND dc.store_id = v_store_id
       AND dc.revoked_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active device credential not found; revoked devices cannot be reactivated';
    END IF;

    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
    v_hash := encode(public.atack_digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');
    v_new_version := v_old_version + 1;

    UPDATE public.device_credentials
       SET token_hash = v_hash,
           credential_version = v_new_version,
           issued_at = NOW(),
           updated_at = NOW()
     WHERE device_id = p_device_id AND store_id = v_store_id;

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action,
        old_values_json, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', p_device_id, 'UPDATE',
        jsonb_build_object('credential_version', v_old_version, 'credential_state', 'ACTIVE'),
        jsonb_build_object('credential_version', v_new_version, 'credential_state', 'ROTATED')
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', p_device_id,
        'device_token', v_token,
        'credential_version', v_new_version
    );
END;
$rotate_device$;

CREATE OR REPLACE FUNCTION public.revoke_sync_device(
    p_device_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $revoke_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_version INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_version
      FROM public.device_credentials dc
     WHERE dc.device_id = p_device_id AND dc.store_id = v_store_id
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Device credential not found in this store'; END IF;
    IF EXISTS (
        SELECT 1 FROM public.device_credentials dc
         WHERE dc.device_id = p_device_id AND dc.store_id = v_store_id
           AND dc.revoked_at IS NOT NULL
    ) THEN
        RETURN TRUE;
    END IF;

    UPDATE public.device_credentials
       SET token_hash = NULL,
           revoked_at = NOW(),
           updated_at = NOW()
     WHERE device_id = p_device_id AND store_id = v_store_id;

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action,
        old_values_json, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', p_device_id, 'UPDATE',
        jsonb_build_object('credential_version', v_version, 'credential_state', 'ACTIVE'),
        jsonb_build_object('credential_version', v_version, 'credential_state', 'REVOKED')
    );
    RETURN TRUE;
END;
$revoke_device$;

REVOKE ALL ON FUNCTION public.register_sync_device(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rotate_sync_device_credential(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_sync_device(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_sync_device(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rotate_sync_device_credential(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_sync_device(UUID) TO authenticated;

-- Retire the tokenless authenticated RPC signatures. Trusted service_role jobs
-- retain their existing signatures; authenticated clients must use credential overloads.
REVOKE EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.apply_outbox_operation(UUID)
    FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_unsynced_records(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_since_cursor BIGINT,
    p_device_token TEXT
) RETURNS TABLE(
    record_uuid UUID,
    operation TEXT,
    record_json JSONB,
    sync_cursor BIGINT,
    changed_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_pull$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN QUERY
    SELECT * FROM public.get_unsynced_records(
        p_store_id, p_device_id, p_table_name, p_since_cursor
    );
END;
$authenticated_pull$;

CREATE OR REPLACE FUNCTION public.acknowledge_sync_cursor(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_cursor BIGINT,
    p_device_token TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_ack$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN public.acknowledge_sync_cursor(p_store_id, p_device_id, p_table_name, p_cursor);
END;
$authenticated_ack$;

CREATE OR REPLACE FUNCTION public.create_outbox_entry(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_operation TEXT,
    p_record_uuid UUID,
    p_idempotency_key UUID,
    p_record_json JSONB,
    p_device_token TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_outbox$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN public.create_outbox_entry(
        p_store_id, p_device_id, p_table_name, p_operation,
        p_record_uuid, p_idempotency_key, p_record_json
    );
END;
$authenticated_outbox$;

CREATE OR REPLACE FUNCTION public.apply_outbox_operation(
    p_outbox_id UUID,
    p_device_id TEXT,
    p_device_token TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_apply$
DECLARE
    v_store_id UUID;
    v_recorded_device TEXT;
BEGIN
    SELECT o.store_id, o.device_id
      INTO v_store_id, v_recorded_device
      FROM public.sync_outbox o
     WHERE o.id = p_outbox_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Outbox entry not found');
    END IF;
    IF v_recorded_device IS DISTINCT FROM p_device_id THEN
        RAISE EXCEPTION 'Outbox entry is not associated with the authenticated device';
    END IF;

    PERFORM public.assert_sync_device_credential(v_store_id, p_device_id, p_device_token);
    RETURN public.apply_outbox_operation(p_outbox_id);
END;
$authenticated_apply$;

REVOKE ALL ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.apply_outbox_operation(UUID, TEXT, TEXT)
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_outbox_operation(UUID, TEXT, TEXT)
    TO authenticated, service_role;

COMMIT;

       OR p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = p_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;

    v_device_uuid := p_device_id::UUID;
    v_token_hash := encode(
        public.atack_digest(convert_to(p_device_token, 'UTF8'), 'sha256'),
        'hex'
    );

    PERFORM 1
      FROM public.devices d
      JOIN public.device_credentials dc
        ON dc.device_id = d.id
       AND dc.store_id = d.store_id
     WHERE d.id = v_device_uuid
       AND d.store_id = p_store_id
       AND dc.user_id = v_user_id
       AND dc.revoked_at IS NULL
       AND dc.token_hash = v_token_hash
     FOR SHARE OF d, dc;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device authentication failed';
    END IF;
END;
$assert_device$;

REVOKE ALL ON FUNCTION public.assert_sync_device_credential(UUID, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.register_sync_device(
    p_target_user_id UUID,
    p_device_name TEXT,
    p_device_type TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $register_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_device_id UUID := gen_random_uuid();
    v_token TEXT;
    v_hash TEXT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;

    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;
    IF v_actor_id IS NULL THEN RAISE EXCEPTION 'Active store user not found'; END IF;

    IF p_target_user_id IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM public.users u
            WHERE u.id = p_target_user_id
              AND u.store_id = v_store_id
              AND u.is_active = TRUE
       ) THEN
        RAISE EXCEPTION 'Target device user must be active in this store';
    END IF;
    IF NULLIF(btrim(p_device_name), '') IS NULL OR length(btrim(p_device_name)) > 120 THEN
        RAISE EXCEPTION 'Device name is required and must not exceed 120 characters';
    END IF;
    IF p_device_type NOT IN ('PHONE', 'TABLET', 'DESKTOP') THEN
        RAISE EXCEPTION 'Unsupported device type';
    END IF;

    -- Two independently generated UUIDs provide a 256-hex-character? No:
    -- 64 hexadecimal characters (256 bits) of high-entropy bearer credential.
    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
    v_hash := encode(public.atack_digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');

    INSERT INTO public.devices(id, store_id, device_name, device_type, is_online)
    VALUES (v_device_id, v_store_id, btrim(p_device_name), p_device_type, FALSE);

    INSERT INTO public.device_credentials(
        device_id, store_id, user_id, registered_by, token_hash,
        credential_version, issued_at
    ) VALUES (
        v_device_id, v_store_id, p_target_user_id, v_actor_id, v_hash, 1, NOW()
    );

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', v_device_id, 'CREATE',
        jsonb_build_object(
            'device_id', v_device_id,
            'device_name', btrim(p_device_name),
            'device_type', p_device_type,
            'assigned_user_id', p_target_user_id,
            'credential_version', 1
        )
    );

    -- The raw credential is returned exactly once and is never stored or audited.
    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', v_device_id,
        'assigned_user_id', p_target_user_id,
        'device_token', v_token,
        'credential_version', 1
    );
END;
$register_device$;

CREATE OR REPLACE FUNCTION public.rotate_sync_device_credential(
    p_device_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $rotate_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_token TEXT;
    v_hash TEXT;
    v_old_version INTEGER;
    v_new_version INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_old_version
      FROM public.device_credentials dc
     WHERE dc.device_id = p_device_id
       AND dc.store_id = v_store_id
       AND dc.revoked_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active device credential not found; revoked devices cannot be reactivated';
    END IF;

    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
    v_hash := encode(public.atack_digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');
    v_new_version := v_old_version + 1;

    UPDATE public.device_credentials
       SET token_hash = v_hash,
           credential_version = v_new_version,
           issued_at = NOW(),
           updated_at = NOW()
     WHERE device_id = p_device_id AND store_id = v_store_id;

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action,
        old_values_json, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', p_device_id, 'UPDATE',
        jsonb_build_object('credential_version', v_old_version, 'credential_state', 'ACTIVE'),
        jsonb_build_object('credential_version', v_new_version, 'credential_state', 'ROTATED')
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', p_device_id,
        'device_token', v_token,
        'credential_version', v_new_version
    );
END;
$rotate_device$;

CREATE OR REPLACE FUNCTION public.revoke_sync_device(
    p_device_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $revoke_device$
DECLARE
    v_store_id UUID;
    v_actor_id UUID;
    v_version INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    v_store_id := public.current_user_store_id();
    IF v_store_id IS NULL OR NOT public.has_store_permission(v_store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required';
    END IF;
    SELECT u.id INTO v_actor_id
      FROM public.users u
     WHERE u.auth_user_id = auth.uid()
       AND u.store_id = v_store_id
       AND u.is_active = TRUE
     LIMIT 1;

    SELECT dc.credential_version
      INTO v_version
      FROM public.device_credentials dc
     WHERE dc.device_id = p_device_id AND dc.store_id = v_store_id
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Device credential not found in this store'; END IF;
    IF EXISTS (
        SELECT 1 FROM public.device_credentials dc
         WHERE dc.device_id = p_device_id AND dc.store_id = v_store_id
           AND dc.revoked_at IS NOT NULL
    ) THEN
        RETURN TRUE;
    END IF;

    UPDATE public.device_credentials
       SET token_hash = NULL,
           revoked_at = NOW(),
           updated_at = NOW()
     WHERE device_id = p_device_id AND store_id = v_store_id;

    INSERT INTO public.audit_logs(
        store_id, user_id, entity_type, entity_id, action,
        old_values_json, new_values_json
    ) VALUES (
        v_store_id, v_actor_id, 'device', p_device_id, 'UPDATE',
        jsonb_build_object('credential_version', v_version, 'credential_state', 'ACTIVE'),
        jsonb_build_object('credential_version', v_version, 'credential_state', 'REVOKED')
    );
    RETURN TRUE;
END;
$revoke_device$;

REVOKE ALL ON FUNCTION public.register_sync_device(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rotate_sync_device_credential(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_sync_device(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_sync_device(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rotate_sync_device_credential(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_sync_device(UUID) TO authenticated;

-- Retire the tokenless authenticated RPC signatures. Trusted service_role jobs
-- retain their existing signatures; authenticated clients must use credential overloads.
REVOKE EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB)
    FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.apply_outbox_operation(UUID)
    FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_unsynced_records(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_since_cursor BIGINT,
    p_device_token TEXT
) RETURNS TABLE(
    record_uuid UUID,
    operation TEXT,
    record_json JSONB,
    sync_cursor BIGINT,
    changed_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_pull$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN QUERY
    SELECT * FROM public.get_unsynced_records(
        p_store_id, p_device_id, p_table_name, p_since_cursor
    );
END;
$authenticated_pull$;

CREATE OR REPLACE FUNCTION public.acknowledge_sync_cursor(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_cursor BIGINT,
    p_device_token TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_ack$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN public.acknowledge_sync_cursor(p_store_id, p_device_id, p_table_name, p_cursor);
END;
$authenticated_ack$;

CREATE OR REPLACE FUNCTION public.create_outbox_entry(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_operation TEXT,
    p_record_uuid UUID,
    p_idempotency_key UUID,
    p_record_json JSONB,
    p_device_token TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_outbox$
BEGIN
    PERFORM public.assert_sync_device_credential(p_store_id, p_device_id, p_device_token);
    RETURN public.create_outbox_entry(
        p_store_id, p_device_id, p_table_name, p_operation,
        p_record_uuid, p_idempotency_key, p_record_json
    );
END;
$authenticated_outbox$;

CREATE OR REPLACE FUNCTION public.apply_outbox_operation(
    p_outbox_id UUID,
    p_device_id TEXT,
    p_device_token TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $authenticated_apply$
DECLARE
    v_store_id UUID;
    v_recorded_device TEXT;
BEGIN
    SELECT o.store_id, o.device_id
      INTO v_store_id, v_recorded_device
      FROM public.sync_outbox o
     WHERE o.id = p_outbox_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Outbox entry not found');
    END IF;
    IF v_recorded_device IS DISTINCT FROM p_device_id THEN
        RAISE EXCEPTION 'Outbox entry is not associated with the authenticated device';
    END IF;

    PERFORM public.assert_sync_device_credential(v_store_id, p_device_id, p_device_token);
    RETURN public.apply_outbox_operation(p_outbox_id);
END;
$authenticated_apply$;

REVOKE ALL ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB, TEXT)
    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.apply_outbox_operation(UUID, TEXT, TEXT)
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB, TEXT)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_outbox_operation(UUID, TEXT, TEXT)
    TO authenticated, service_role;

COMMIT;
