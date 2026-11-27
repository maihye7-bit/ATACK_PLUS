-- ATACK PLUS — Stage 2 / Part 3-D1
-- Read-only FK catalog, orphan-reference and cross-store drift preflight.
-- Run with psql against an isolated local test database or disposable CI database, after explicit approval.
-- This script does not alter persistent data or schema. It emits catalog rows and
-- NOTICE diagnostics; it must never be pointed at staging/production without separate approval.

BEGIN TRANSACTION READ ONLY;

-- 1) Complete declared FK inventory, including ordered column mapping and enforcement state.
SELECT
    ns.nspname AS source_schema,
    src.relname AS source_table,
    con.conname AS constraint_name,
    string_agg(src_att.attname, ', ' ORDER BY src_key.ordinality) AS source_columns,
    ref_ns.nspname AS referenced_schema,
    ref.relname AS referenced_table,
    string_agg(ref_att.attname, ', ' ORDER BY src_key.ordinality) AS referenced_columns,
    CASE con.confdeltype
      WHEN 'a' THEN 'NO ACTION'
      WHEN 'r' THEN 'RESTRICT'
      WHEN 'c' THEN 'CASCADE'
      WHEN 'n' THEN 'SET NULL'
      WHEN 'd' THEN 'SET DEFAULT'
      ELSE 'UNKNOWN'
    END AS on_delete,
    CASE con.confupdtype
      WHEN 'a' THEN 'NO ACTION'
      WHEN 'r' THEN 'RESTRICT'
      WHEN 'c' THEN 'CASCADE'
      WHEN 'n' THEN 'SET NULL'
      WHEN 'd' THEN 'SET DEFAULT'
      ELSE 'UNKNOWN'
    END AS on_update,
    con.condeferrable AS is_deferrable,
    con.condeferred AS initially_deferred,
    con.convalidated AS is_validated,
    con.conislocal AS is_local,
    con.coninhcount AS inheritance_count,
    pg_get_constraintdef(con.oid, true) AS constraint_definition
FROM pg_constraint con
JOIN pg_class src ON src.oid = con.conrelid
JOIN pg_namespace ns ON ns.oid = src.relnamespace
JOIN pg_class ref ON ref.oid = con.confrelid
JOIN pg_namespace ref_ns ON ref_ns.oid = ref.relnamespace
JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS src_key(attnum, ordinality) ON TRUE
JOIN LATERAL unnest(con.confkey) WITH ORDINALITY AS ref_key(attnum, ordinality)
  ON ref_key.ordinality = src_key.ordinality
JOIN pg_attribute src_att
  ON src_att.attrelid = src.oid AND src_att.attnum = src_key.attnum
JOIN pg_attribute ref_att
  ON ref_att.attrelid = ref.oid AND ref_att.attnum = ref_key.attnum
WHERE con.contype = 'f'
  AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
GROUP BY con.oid, ns.nspname, src.relname, con.conname,
         ref_ns.nspname, ref.relname, con.confdeltype, con.confupdtype,
         con.condeferrable, con.condeferred, con.convalidated,
         con.conislocal, con.coninhcount
ORDER BY ns.nspname, src.relname, con.conname;

-- 2) For each declared FK, count rows that violate its reference.
-- 3) Where both tables carry store_id, also count FK-linked rows whose store differs.
-- The DO block only reads catalog/data and reports counts with NOTICE; it creates no objects.
DO $fk_preflight$
DECLARE
    fk RECORD;
    v_join_predicate TEXT;
    v_nonnull_predicate TEXT;
    v_orphan_count BIGINT;
    v_cross_store_count BIGINT;
    v_has_source_store BOOLEAN;
    v_has_target_store BOOLEAN;
    v_maps_store_id BOOLEAN;
    v_sql TEXT;
BEGIN
    FOR fk IN
        SELECT
            con.oid,
            con.conname,
            con.conkey,
            con.confkey,
            src_ns.nspname AS source_schema,
            src.relname AS source_table,
            ref_ns.nspname AS target_schema,
            ref.relname AS target_table,
            src.oid AS source_oid,
            ref.oid AS target_oid
        FROM pg_constraint con
        JOIN pg_class src ON src.oid = con.conrelid
        JOIN pg_namespace src_ns ON src_ns.oid = src.relnamespace
        JOIN pg_class ref ON ref.oid = con.confrelid
        JOIN pg_namespace ref_ns ON ref_ns.oid = ref.relnamespace
        WHERE con.contype = 'f'
          AND src_ns.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY src_ns.nspname, src.relname, con.conname
    LOOP
        SELECT
            string_agg(format('c.%I = p.%I', ca.attname, pa.attname),
                       ' AND ' ORDER BY k.ordinality),
            string_agg(format('c.%I IS NOT NULL', ca.attname),
                       ' AND ' ORDER BY k.ordinality),
            bool_or(ca.attname = 'store_id' AND pa.attname = 'store_id')
        INTO v_join_predicate, v_nonnull_predicate, v_maps_store_id
        FROM unnest(fk.conkey) WITH ORDINALITY AS k(attnum, ordinality)
        JOIN unnest(fk.confkey) WITH ORDINALITY AS r(attnum, ordinality)
          ON r.ordinality = k.ordinality
        JOIN pg_attribute ca
          ON ca.attrelid = fk.source_oid AND ca.attnum = k.attnum
        JOIN pg_attribute pa
          ON pa.attrelid = fk.target_oid AND pa.attnum = r.attnum;

        v_sql := format(
            'SELECT count(*) FROM %I.%I c WHERE (%s) AND NOT EXISTS ' ||
            '(SELECT 1 FROM %I.%I p WHERE %s)',
            fk.source_schema, fk.source_table, v_nonnull_predicate,
            fk.target_schema, fk.target_table, v_join_predicate
        );
        EXECUTE v_sql INTO v_orphan_count;

        RAISE NOTICE 'FK % %.% -> %.%: orphan_reference_rows=%',
            fk.conname, fk.source_schema, fk.source_table,
            fk.target_schema, fk.target_table, v_orphan_count;

        SELECT EXISTS (
            SELECT 1 FROM pg_attribute
            WHERE attrelid = fk.source_oid AND attname = 'store_id'
              AND attnum > 0 AND NOT attisdropped
        ) INTO v_has_source_store;

        SELECT EXISTS (
            SELECT 1 FROM pg_attribute
            WHERE attrelid = fk.target_oid AND attname = 'store_id'
              AND attnum > 0 AND NOT attisdropped
        ) INTO v_has_target_store;

        IF v_has_source_store AND v_has_target_store AND NOT COALESCE(v_maps_store_id, FALSE) THEN
            v_sql := format(
                'SELECT count(*) FROM %I.%I c JOIN %I.%I p ON %s ' ||
                'WHERE (%s) AND c.store_id IS DISTINCT FROM p.store_id',
                fk.source_schema, fk.source_table,
                fk.target_schema, fk.target_table,
                v_join_predicate, v_nonnull_predicate
            );
            EXECUTE v_sql INTO v_cross_store_count;

            RAISE NOTICE 'FK % %.% -> %.%: cross_store_reference_rows=%',
                fk.conname, fk.source_schema, fk.source_table,
                fk.target_schema, fk.target_table, v_cross_store_count;
        END IF;
    END LOOP;
END;
$fk_preflight$;

ROLLBACK;
