-- D3.2 / R5: document legacy Tombstone aggregate fields as non-authoritative.
-- Per-device progress is represented by sync_cursors and sync_delivery_pages.
BEGIN;

COMMENT ON COLUMN public.tombstones.sync_status IS
'Legacy compatibility field only. This is not an aggregate proof that all devices received the delete and must not be set to SYNCED by a single-device ACK. Per-device progress is tracked by sync_cursors and sync_delivery_pages. Retained for compatibility; do not use as authoritative sync state.';

COMMENT ON COLUMN public.tombstones.synced_at IS
'Legacy compatibility field only. This timestamp does not represent delivery to all devices and is not maintained by the delivery-bound ACK contract. Per-device acknowledgement timestamps are stored in sync_delivery_pages.';

COMMENT ON TABLE public.sync_delivery_pages IS
'Server-issued Pull pages bound to a store, device, table, cursor range and device credential version. acknowledged_at is per-page/per-device delivery progress; it does not prove client-side local commit.';

COMMIT;
