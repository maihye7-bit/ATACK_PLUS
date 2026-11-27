# Phase 1 — Same-Store Referential Integrity Repair

**Branch:** `repair/verified-fixes`  
**Implementation date:** 2026-11-27  
**Status:** Implementation and CI verification complete; staging-data acceptance remains pending.

## Implemented migrations

1. `docs/PHASE1_REPAIR_001_SAME_STORE_INTEGRITY.sql`
   - Locks referenced parent rows while validating same-store relationships.
   - Validates stock-movement source references for invoices, purchases, adjustments, sales returns and purchase returns.
   - Requires reference type and reference ID to be either both NULL or both populated.
   - Prevents parent store reassignment when dependent stock/business history exists.

2. `docs/PHASE1_REPAIR_002_EXTENSION_SAME_STORE.sql`
   - Adds composite same-store foreign keys for purchase receipts/items, purchase closures/items, purchase amendments, purchase returns, stock adjustments, inventory batches, stock alerts, chart of accounts, journal entries and general ledger.
   - Validates indirect purchase-item, receipt-item, closure-item and return-item relationships.
   - Validates customer/supplier ledger sources and journal/general-ledger source identity.
   - Adds legacy-data preflight checks before the migration commits.

3. `docs/PHASE1_REPAIR_003_SYNC_AUDIT_SAME_STORE.sql`
   - Ensures sync cursors, outbox rows, sync logs and audit events use a device registered to the same store.
   - Validates outbox payload record/store identity.
   - Validates sync-conflict target and snapshot identity.
   - Validates tombstone target store and keeps user-role conflicts stored but excluded from generic conflict resolution.
   - Prevents device store reassignment after sync/audit history exists.

## Tests added or updated

- `tests/phase1-same-store-integrity-regression.sql`
- `tests/phase1-same-store-concurrency.sh`
- `tests/phase1-extension-same-store-regression.sql`
- `tests/phase1-sync-audit-same-store-regression.sql`
- Updated `tests/phase3-accounting-regression.sql` to use a valid adjustment source when testing deferred journal-balance rejection.
- Updated `.github/workflows/sql-migrations-smoke.yml` to run all new migrations and tests.

The purchase-amendment RPC now inserts the amendment source before its supplier-ledger adjustment reference, within the same transaction.

## Final CI evidence

Verified commit: `837f81ead33df7b936e86d011b749d4f9b78fc6d`

- [SQL migration and full regression workflow — 45995177555](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/45995177555) — **PASS**
- [Supabase Auth integration workflow — 45995177653](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/45995177653) — **PASS**

The full SQL workflow also ran the existing Phase 2 business, authenticated RPC, concurrency, Phase 3 security, accounting, sync, audit, device and owner/seller role regressions successfully.

## Acceptance boundary

- Tests ran on isolated CI PostgreSQL and Auth compatibility fixtures.
- Legacy-data preflight logic is present in the migrations, but has not yet been executed against the user's staging or production dataset.
- No production/staging database was changed.
- No merge to `main` was performed.
- Frontend/UI behavior was not included in this database-only stage.
