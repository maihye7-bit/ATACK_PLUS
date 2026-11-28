#!/usr/bin/env bash
set -euo pipefail

: "${PGPASSWORD:?PGPASSWORD must be set}"
PSQL=(psql -h localhost -U postgres -d atack_plus_test -v ON_ERROR_STOP=1)
STORE='10000000-0000-4000-8000-000000000001'
OWNER_ID='99100000-0000-4000-8000-000000000061'
SELLER_ID='99100000-0000-4000-8000-000000000062'
OWNER_AUTH='20700000-0000-4000-8000-000000000061'
SELLER_AUTH='20700000-0000-4000-8000-000000000062'
DEVICE_ID='99400000-0000-4000-8000-000000000061'
DEVICE_TOKEN='a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0'
EVENT_A='99300000-0000-4000-8000-000000000061'
EVENT_B='99300000-0000-4000-8000-000000000062'
tmp_a="$(mktemp)"

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<SQL || true
DELETE FROM public.sync_delivery_pages WHERE device_id='${DEVICE_ID}';
DELETE FROM public.sync_cursors WHERE device_id='${DEVICE_ID}';
DELETE FROM public.device_credentials WHERE device_id='${DEVICE_ID}';
DELETE FROM public.devices WHERE id='${DEVICE_ID}';
DELETE FROM public.change_log WHERE store_id='${STORE}' AND record_uuid IN ('${EVENT_A}','${EVENT_B}');
DELETE FROM public.users WHERE id IN ('${OWNER_ID}','${SELLER_ID}');
SQL
  rm -f "${tmp_a}"
}
trap cleanup EXIT

# This concurrency test provisions a private credential fixture directly as
# the database owner. The R2 lifecycle RPCs and their audit trail are tested
# separately; avoiding an audit-log write here keeps this fixture removable.
"${PSQL[@]}" >/dev/null <<SQL
DELETE FROM public.sync_delivery_pages WHERE device_id='${DEVICE_ID}';
DELETE FROM public.sync_cursors WHERE device_id='${DEVICE_ID}';
DELETE FROM public.device_credentials WHERE device_id='${DEVICE_ID}';
DELETE FROM public.devices WHERE id='${DEVICE_ID}';
DELETE FROM public.change_log WHERE store_id='${STORE}' AND record_uuid IN ('${EVENT_A}','${EVENT_B}');
DELETE FROM public.users WHERE id IN ('${OWNER_ID}','${SELLER_ID}');

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('${OWNER_ID}','${OWNER_AUTH}','${STORE}','d32_r6_concurrency_owner','D3.2 R6 Owner',TRUE),
 ('${SELLER_ID}','${SELLER_AUTH}','${STORE}','d32_r6_concurrency_seller','D3.2 R6 Seller',TRUE);
INSERT INTO public.user_roles(user_id,role_id)
VALUES ('${OWNER_ID}','owner'),('${SELLER_ID}','cashier');
INSERT INTO public.devices(id,store_id,device_name,device_type)
VALUES ('${DEVICE_ID}','${STORE}','D3.2 R6 Concurrent Device','DESKTOP');
INSERT INTO public.device_credentials(
  device_id,store_id,user_id,registered_by,token_hash,credential_version
) VALUES (
  '${DEVICE_ID}','${STORE}','${SELLER_ID}','${OWNER_ID}',
  encode(public.atack_digest(convert_to('${DEVICE_TOKEN}','UTF8'),'sha256'),'hex'),1
);
SQL

# Establish a per-device checkpoint and one visible event before the first Pull.
"${PSQL[@]}" >/dev/null <<SQL
DO \$seed\$
DECLARE v_base BIGINT;
BEGIN
  SELECT COALESCE(MAX(sync_cursor),0) INTO v_base
    FROM public.change_log WHERE store_id='${STORE}' AND table_name='products';
  INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq,cursor_value)
  VALUES('${STORE}','${DEVICE_ID}','products',v_base,v_base::TEXT)
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
    '${STORE}','${DEVICE_ID}','products','${DEVICE_TOKEN}'
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
      '${STORE}','${DEVICE_ID}','products',
      current_setting('atack_test.d32_r6_delivery')::UUID,
      '${DEVICE_TOKEN}'
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
    '${STORE}','${DEVICE_ID}','products','${DEVICE_TOKEN}'
  );
  IF (p->>'event_count')::INTEGER <> 1
     OR (p->>'has_more')::BOOLEAN IS NOT FALSE
     OR (p->'events'->0->>'record_uuid')::UUID IS DISTINCT FROM '${EVENT_B}'::UUID THEN
    RAISE EXCEPTION 'Concurrent event was lost or duplicated across page boundary: %',p;
  END IF;
  IF NOT public.acknowledge_sync_cursor(
      '${STORE}','${DEVICE_ID}','products',
      (p->>'delivery_id')::UUID,
      '${DEVICE_TOKEN}'
  ) THEN RAISE EXCEPTION 'Second concurrent page ACK failed'; END IF;
  RAISE NOTICE 'PASS: concurrent Change Log insert is delivered on the next page without a gap';
END
\$pull_second\$;
COMMIT;
SQL

echo "PASS: concurrent Pull/ACK page boundary preserved; new event delivered on continuation"
