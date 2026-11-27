#!/usr/bin/env bash
set -euo pipefail

: "${PGPASSWORD:?PGPASSWORD must be set}"
PSQL=(psql -h localhost -U postgres -d atack_plus_test -v ON_ERROR_STOP=1)
STORE='10000000-0000-4000-8000-000000000001'
AUTH='20000000-0000-4000-8000-000000000001'
CATEGORY='93000000-0000-4000-8000-000000000004'
FIRST_APP='atack-soft-delete-concurrency-first'
SECOND_APP='atack-soft-delete-concurrency-second'

tmpdir="$(mktemp -d)"
cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL' || true
DROP TRIGGER IF EXISTS trg_test_soft_delete_concurrency_delay ON public.audit_logs;
DROP FUNCTION IF EXISTS public.test_delay_soft_delete_concurrency_audit();
SQL
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Use an isolated category and delay the first transaction at its final audit
# insert. The second independent session must wait on the same category row.
"${PSQL[@]}" <<SQL
INSERT INTO public.categories(id,store_id,name,is_active)
VALUES ('$CATEGORY','$STORE','Soft-delete concurrency fixture',TRUE);

CREATE OR REPLACE FUNCTION public.test_delay_soft_delete_concurrency_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS \$test_delay\$
BEGIN
  IF NEW.entity_type='categories'
     AND NEW.entity_id='$CATEGORY'::UUID
     AND NEW.action='DELETE' THEN
    PERFORM pg_sleep(3);
  END IF;
  RETURN NEW;
END;
\$test_delay\$;

DROP TRIGGER IF EXISTS trg_test_soft_delete_concurrency_delay ON public.audit_logs;
CREATE TRIGGER trg_test_soft_delete_concurrency_delay
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.test_delay_soft_delete_concurrency_audit();
SQL

baseline_category_changes="$("${PSQL[@]}" -Atc "SELECT count(*) FROM public.change_log WHERE store_id='$STORE' AND table_name='categories' AND record_uuid='$CATEGORY'")"
baseline_tombstone_changes="$("${PSQL[@]}" -Atc "SELECT count(*) FROM public.change_log WHERE store_id='$STORE' AND table_name='tombstones' AND record_uuid IN (SELECT id FROM public.tombstones WHERE store_id='$STORE' AND table_name='categories' AND record_uuid='$CATEGORY')")"

PGAPPNAME="$FIRST_APP" "${PSQL[@]}" >"$tmpdir/first.log" 2>&1 <<SQL &
SELECT set_config('request.jwt.claim.sub','$AUTH',false);
SELECT public.soft_delete_record('categories','$CATEGORY','$STORE','30000000-0000-4000-8000-000000000001');
SQL
first_pid=$!

# Do not start the second call until the first is demonstrably sleeping inside
# the audit trigger while still holding the category row lock.
sleeping=''
for _ in $(seq 1 80); do
  sleeping="$("${PSQL[@]}" -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name='$FIRST_APP' AND state='active' AND wait_event='PgSleep'")"
  [[ "$sleeping" == "1" ]] && break
  sleep 0.1
done
if [[ "$sleeping" != "1" ]]; then
  echo "FAIL: first soft-delete transaction did not reach the controlled audit delay."
  cat "$tmpdir/first.log"
  exit 1
fi

PGAPPNAME="$SECOND_APP" "${PSQL[@]}" >"$tmpdir/second.log" 2>&1 <<SQL &
SELECT set_config('request.jwt.claim.sub','$AUTH',false);
SELECT public.soft_delete_record('categories','$CATEGORY','$STORE','30000000-0000-4000-8000-000000000001');
SQL
second_pid=$!

wait "$first_pid"
wait "$second_pid"

"${PSQL[@]}" <<SQL
DO \$concurrent_soft_delete_check\$
DECLARE
  v_tombstones INTEGER;
  v_delete_audits INTEGER;
  v_category_changes INTEGER;
  v_tombstone_changes INTEGER;
  v_active BOOLEAN;
BEGIN
  SELECT is_active INTO v_active FROM public.categories
   WHERE id='$CATEGORY' AND store_id='$STORE';
  SELECT count(*) INTO v_tombstones FROM public.tombstones
   WHERE store_id='$STORE' AND table_name='categories' AND record_uuid='$CATEGORY';
  SELECT count(*) INTO v_delete_audits FROM public.audit_logs
   WHERE store_id='$STORE' AND entity_type='categories'
     AND entity_id='$CATEGORY' AND action='DELETE';
  SELECT count(*) INTO v_category_changes FROM public.change_log
   WHERE store_id='$STORE' AND table_name='categories' AND record_uuid='$CATEGORY';
  SELECT count(*) INTO v_tombstone_changes FROM public.change_log
   WHERE store_id='$STORE' AND table_name='tombstones'
     AND record_uuid IN (SELECT id FROM public.tombstones
       WHERE store_id='$STORE' AND table_name='categories' AND record_uuid='$CATEGORY');

  IF v_active IS DISTINCT FROM FALSE OR v_tombstones<>1 OR v_delete_audits<>1
     OR v_category_changes<>('$baseline_category_changes')::INTEGER + 1
     OR v_tombstone_changes<>('$baseline_tombstone_changes')::INTEGER + 1 THEN
    RAISE EXCEPTION 'Concurrent soft delete invariant failed: active %, tombstones %, DELETE audits %, category changes %, tombstone changes % (baselines %, %)',
      v_active,v_tombstones,v_delete_audits,v_category_changes,v_tombstone_changes,
      '$baseline_category_changes','$baseline_tombstone_changes';
  END IF;
  RAISE NOTICE 'PASS: concurrent soft deletes serialize; one tombstone, one DELETE audit and one change event per affected record';
END;
\$concurrent_soft_delete_check\$;
SQL

echo "PASS: two concurrent soft-delete calls on one record are idempotent and serialized"
