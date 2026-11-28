#!/usr/bin/env bash
set -euo pipefail

: "${PGPASSWORD:?PGPASSWORD must be set}"
PSQL=(psql -h localhost -U postgres -d atack_plus_test -v ON_ERROR_STOP=1)
STORE='10000000-0000-4000-8000-000000000001'
OWNER_ID='99100000-0000-4000-8000-000000000061'
SELLER_ID='99100000-0000-4000-8000-000000000062'
OWNER_AUTH='20700000-0000-4000-8000-000000000061'
SELLER_AUTH='20700000-0000-4000-8000-000000000062'
EVENT_A='99300000-0000-4000-8000-000000000061'
EVENT_B='99300000-0000-4000-8000-000000000062'
tmp_a="$(mktemp)"
device_id=''
device_token=''

cleanup() {
  if [[ -n "${device_id}" ]]; then
    "${PSQL[@]}" >/dev/null 2>&1 <<SQL || true
DELETE FROM public.sync_delivery_pages WHERE device_id='${device_id}';
DELETE FROM public.sync_cursors WHERE device_id='${device_id}';
DELETE FROM public.device_credentials WHERE device_id='${device_id}';
DELETE FROM public.devices WHERE id='${device_id}';
DELETE FROM public.audit_logs WHERE user_id IN ('${OWNER_ID}','${SELLER_ID}');
DELETE FROM public.change_log WHERE store_id='${STORE}' AND record_uuid IN ('${EVENT_A}','${EVENT_B}');
DELETE FROM public.users WHERE id IN ('${OWNER_ID}','${SELLER_ID}');
SQL
  fi
  rm -f "${tmp_a}"
}
trap cleanup EXIT

# Provision an owner and seller-bound device; capture the one-time token.
device_result="$("${PSQL[@]}" -Atq <<SQL
BEGIN;
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('${OWNER_ID}','${OWNER_AUTH}','${STORE}','d32_r6_concurrency_owner','D3.2 R6 Owner',TRUE),
 ('${SELLER_ID}','${SELLER_AUTH}','${STORE}','d32_r6_concurrency_seller','D3.2 R6 Seller',TRUE);
INSERT INTO public.user_roles(user_id,role_id)
VALUES ('${OWNER_ID}','owner'),('${SELLER_ID}','cashier');
DO \$jwt\$
BEGIN
  PERFORM set_config('request.jwt.claim.sub','${OWNER_AUTH}',TRUE);
  PERFORM set_config('request.jwt.claim.role','authenticated',TRUE);
END
\$jwt\$;
SET LOCAL ROLE authenticated;
SELECT (r->>'device_id') || '|' || (r->>'device_token')
  FROM (SELECT public.register_sync_device('${SELLER_ID}','D3.2 R6 Concurrent Device','DESKTOP') AS r) q;
COMMIT;
SQL
)"
IFS='|' read -r device_id device_token <<< "$device_result"
if [[ -z "${device_id}" || -z "${device_token}" ]]; then
  echo "FAIL: owner device provisioning returned no device ID/token"
  exit 1
fi

# Establish a per-device checkpoint and one visible event before the first Pull.
"${PSQL[@]}" >/dev/null <<SQL
DO \$seed\$
DECLARE v_base BIGINT;
BEGIN
  SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
    FROM public.change_log WHERE store_id='${STORE}' AND table_name='products';
  INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq,cursor_value)
  VALUES('${STORE}','${device_id}','products',v_base,v_base::TEXT)
  ON CONFLICT (store_id,device_id,table_name) DO UPDATE
    SET last_pull_seq=EXCLUDED.last_pull_seq,cursor_value=EXCLUDED.cursor_value;
  PERFORM public.log_change(
    '${STORE}','products','${EVENT_A}','INSERT',NULL,
    jsonb_build_object('id','${EVENT_A}','store_id','${STORE}','name','D3.2 R6 event A')
  );
END
\$seed\$;
SQL

# Session A issues page 1 and holds its transaction open while Session B inserts
# a later Change Log event. ACK must advance only to page 1's recorded boundary.
"${PSQL[@]}" >"${tmp_a}" 2>&1 <<SQL &
BEGIN;
SET application_name='atack-d32-r6-page-session';
SELECT set_config('request.jwt.claim.sub','${SELLER_AUTH}',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO \$pull_first\$
DECLARE p JSONB;
BEGIN
  p := public.get_unsynced_records_page(
    '${STORE}','${device_id}','products','${device_token}'
  );
  IF (p->>'event_count')::INTEGER <> 1
     OR (p->>'has_more')::BOOLEAN IS NOT FALSE
     OR (p->'events'->0->>'record_uuid')::UUID IS DISTINCT FROM '${EVENT_A}'::UUID THEN
    RAISE EXCEPTION 'First concurrent page is invalid: %',p;
  END IF;
  PERFORM set_config('atack_test.d32_r6_delivery',p->>'delivery_id',TRUE);
END
\$pull_first\$;
SELECT pg_sleep(3);
DO \$ack_first\$
BEGIN
  IF NOT public.acknowledge_sync_cursor(
      '${STORE}','${device_id}','products',
      current_setting('atack_test.d32_r6_delivery')::UUID,
      '${device_token}'
  ) THEN RAISE EXCEPTION 'First concurrent page ACK failed'; END IF;
END
\$ack_first\$;
COMMIT;
SQL
session_a=$!

# Wait until Session A has issued page 1 and is sleeping inside the same transaction.
active=0
for _ in $(seq 1 60); do
  active="$("${PSQL[@]}" -Atq -c "SELECT count(*) FROM pg_stat_activity WHERE application_name='atack-d32-r6-page-session' AND state='active' AND query ILIKE '%pg_sleep%'")"
  [[ "${active}" == "1" ]] && break
  sleep 0.1
done
if [[ "${active}" != "1" ]]; then
  echo "FAIL: could not synchronize the concurrent Pull window"
  cat "${tmp_a}"
  kill "${session_a}" 2>/dev/null || true
  wait "${session_a}" 2>/dev/null || true
  exit 1
fi

# Session B commits a later event while Session A's page transaction remains open.
"${PSQL[@]}" >/dev/null <<SQL
SELECT public.log_change(
  '${STORE}','products','${EVENT_B}','INSERT',NULL,
  jsonb_build_object('id','${EVENT_B}','store_id','${STORE}','name','D3.2 R6 concurrent event B')
);
SQL
wait "${session_a}"

# A fresh Pull after page 1 ACK must see the event committed during the first
# transaction; it must not have been skipped by the earlier page boundary.
"${PSQL[@]}" <<SQL
BEGIN;
SELECT set_config('request.jwt.claim.sub','${SELLER_AUTH}',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO \$pull_second\$
DECLARE p JSONB;
BEGIN
  p := public.get_unsynced_records_page(
    '${STORE}','${device_id}','products','${device_token}'
  );
  IF (p->>'event_count')::INTEGER <> 1
     OR (p->>'has_more')::BOOLEAN IS NOT FALSE
     OR (p->'events'->0->>'record_uuid')::UUID IS DISTINCT FROM '${EVENT_B}'::UUID THEN
    RAISE EXCEPTION 'Concurrent event was lost or duplicated across page boundary: %',p;
  END IF;
  IF NOT public.acknowledge_sync_cursor(
      '${STORE}','${device_id}','products',
      (p->>'delivery_id')::UUID,
      '${device_token}'
  ) THEN RAISE EXCEPTION 'Second concurrent page ACK failed'; END IF;
  RAISE NOTICE 'PASS: concurrent Change Log insert is delivered on the next page without a gap';
END
\$pull_second\$;
COMMIT;
SQL

echo "PASS: concurrent Pull/ACK page boundary preserved; new event delivered on continuation"
