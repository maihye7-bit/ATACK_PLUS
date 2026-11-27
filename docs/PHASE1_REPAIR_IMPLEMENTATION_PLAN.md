# ATACK PLUS — Phase 1 Repair Implementation Plan

**Status:** Proposed plan, pending review and explicit authorization  
**Baseline:** Approved `PHASE1_POST_IMPLEMENTATION_AUDIT_AND_FIX_PLAN.md`  
**Environment:** Local PostgreSQL 16.15 / Ubuntu 24.04 / WSL2 first; real Supabase staging afterward.

## 1. Authorization boundary

This document converts the approved audit findings into an ordered implementation plan. It does **not** authorize editing project files, changing the database, running migrations, or modifying Supabase. Each implementation stage requires separate explicit approval.

The current Phase 1 schema, `docs/POSTGRES_SCHEMA_PHASE1_FIXED.sql`, previously executed successfully on the local `atack_plus_test` database. The local Supabase Auth shim is not real Supabase Auth/JWT validation, and local execution is not production acceptance.

## 2. Files potentially affected

Only files actually affected by an approved stage should be changed. Before editing, inspect current contents and record hashes.

- `POSTGRES_SCHEMA_PHASE1_FIXED.sql`
- `ATACK_PLUS_PHASE2_BUSINESS_RPCS.sql`
- `ATACK_PLUS_PHASE3_RETURNS_INVENTORY_ACCOUNTING.sql`
- `SECURITY_RLS_PHASE2_UPDATED.md`
- `SECURITY_RLS_PHASE3_UPDATE.md`
- `SYNC_DESIGN_PHASE2_UPDATED.md`
- `SYNC_DESIGN_PHASE3_UPDATE.md`
- `CONFLICT_RESOLUTION_PHASE2_UPDATED.md`
- `CONFLICT_RESOLUTION_PHASE3_UPDATE.md`
- `SQLITE_SCHEMA_PHASE1_FIXED.md`
- `SQLITE_MIGRATION_PHASE3.sql`
- `TEST_PLAN_PHASE2_UPDATED.md`
- `TEST_PLAN_PHASE3_UPDATED.md`
- `PHASE2_RPC_INTEGRATION_GUIDE.md`
- `PHASE3_RPC_INTEGRATION_GUIDE.md`

## 3. Implementation principles

1. Preserve the existing Phase 1 baseline; do not rebuild from scratch.
2. Work in bounded stages, each with backup, migration, tests and acceptance gate.
3. No Last Write Wins for money or inventory (D-009).
4. Financial and inventory conflicts must be resolved through domain operations, not generic JSON overwrite.
5. Enforce store ownership and permissions server-side.
6. Make offline retries idempotent; never silently duplicate stock, debt, payments or ledger entries.
7. Use exact numeric arithmetic for money and sensitive quantities.
8. Do not silently correct or discard conflicts.
9. Local tests do not replace real Supabase staging tests.
10. Do not execute non-idempotent migrations twice without checking their state.

## 4. Stage 0 — Freeze and capture baseline

**Priority:** Mandatory; no schema changes. **Files changed:** None.

Tasks:
- Confirm project root and `docs` directory.
- Record SHA-256, size and timestamp for all files in Section 2.
- Capture tables, columns, constraints, indexes, triggers, functions, RLS policies and grants from the local database.
- Create a full PostgreSQL backup of `atack_plus_test`.
- Verify backup existence, non-zero size, readability/listing and hash.
- Preserve the original SQL files unchanged.
- Create a dedicated repair branch or dated working copy.

**Gate G0:** Do not proceed unless backup and baseline hashes are verified and original files remain unchanged.

## 5. Stage 1 — Same-store referential integrity

**Findings:** F-08 and relevant parts of F-02.  
**Likely files:** Schema SQL, security notes, test plan; RPCs only if write paths are affected.

Tasks:
- Build a full relationship matrix: referencing table/column, referenced key, store ownership source, current FK/trigger/policy, required protection and NULL behavior.
- Include products, categories, brands, units, invoice/purchase headers and items, customers, suppliers, payments, allocations, ledgers, stock, locations, movements, returns, users, roles, devices, cursors, conflicts and tombstones.
- Prefer composite `(referenced_id, store_id)` foreign keys where feasible.
- For other references, design validation triggers that cover INSERT and relevant UPDATE, handle NULLs, and use appropriate locking to avoid race conditions.
- Review existing `validate_same_store_references()` coverage; avoid duplicate/conflicting triggers.
- Add supporting indexes where required.
- Avoid introducing destructive cascades.

Tests:
- Cross-store INSERT and UPDATE attempts must fail.
- Valid same-store and optional NULL references must work.
- Test concurrent parent/child changes where ownership updates are permitted.
- Existing valid data must pass before constraints are validated.

**Gate G1:** Complete relationship matrix, passing negative/positive tests, no silent data changes or loss.

### Implementation update — 2026-11-27 (Stage 1 implementation)

**Status:** Stage 1 same-store integrity implementation is complete on `repair/verified-fixes`; code and CI acceptance checks pass. Applying the migrations to a real staging dataset and reviewing any legacy-data preflight failures remain deployment acceptance tasks.

Implemented across three ordered migrations:
- `PHASE1_REPAIR_001_SAME_STORE_INTEGRITY.sql`: hardened stock-movement references, parent-row locking, and parent ownership guards.
- `PHASE1_REPAIR_002_EXTENSION_SAME_STORE.sql`: composite same-store constraints and reference validation for purchase receiving, closures, amendments, purchase/sales returns, inventory batches, stock alerts, customer/supplier ledgers, chart of accounts and journals.
- `PHASE1_REPAIR_003_SYNC_AUDIT_SAME_STORE.sql`: device/store validation, sync cursor/outbox/log checks, conflict target identity, tombstone target validation and audit-device checks.

Regression coverage includes cross-store rejection, valid same-store operations, legacy-data preflight, return and ledger source matching, journal/general-ledger source matching, outbox/conflict identity, and two-session parent-first/child-first concurrency.

**CI evidence on commit `837f81ead33df7b936e86d011b749d4f9b78fc6d`:**
- [SQL migration and full regression workflow — run 45995177555](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/45995177555) — PASS.
- [Supabase Auth integration workflow — run 45995177653](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/45995177653) — PASS.

The purchase-amendment RPC was adjusted to persist its amendment source before writing a supplier-ledger row that references it; the transaction still rolls back both together on failure.

**Deployment boundary:** CI used an isolated PostgreSQL/Auth compatibility environment. The migrations include preflight checks that validate existing rows when applied, but those checks have not been run against the user's staging or production data. No production database was changed, no merge to `main` was performed, and frontend/UI behavior was not part of this database-only stage.

## 6. Stage 2 — Soft deletion, tombstones and product retention

**Findings:** F-03, F-04, F-09, F-10.  
**Likely files:** Schema SQL, sync/conflict design, security notes, test plan; possibly SQLite schema/migration.

Tasks:
- Define deletion semantics per entity: deactivate, soft-delete, tombstone, prohibit deletion, or exceptional hard-delete.
- Replace incomplete `soft_delete_record` behavior with a table-allowlisted or table-specific operation.
- Derive actor/store from trusted authenticated context where possible; validate record ownership and eligibility.
- Atomically update deletion state and insert tombstone; ensure idempotency and audit.
- Decide whether tombstone identity is globally unique or store-scoped; document and test the invariant.
- Review `ON DELETE CASCADE` on historical business data.
- Prevent normal application roles from physically deleting history-bearing records.
- Define whether child tables sync independently and whether parent tombstones imply local child cleanup.
- Test parent/nested cascades and actual `trg_log_change` behavior.

Tests:
- Soft-delete products with no history and with stock/purchase/invoice/return/movement history.
- Physical delete attempts through app roles must fail.
- Repeated delete is idempotent.
- Tombstone and record state commit/rollback together.
- Parent/child deletion replays deterministically on a client.

**Gate G2:** No business history is erased; record state and tombstones remain consistent; cascade sync behavior is proven.

## 7. Stage 3 — Warehouses, stock and negative inventory

**Findings:** F-01, F-02, F-08. **Decisions:** D-016, D-020, D-021.  
**Likely files:** Schema, Phase 2/3 RPCs, SQLite schema/migration, security, sync design and tests.

Tasks:
- Approve a store-owned warehouse/location model with UUID, `store_id`, lifecycle and same-store references.
- Define migration mapping from current fixed IDs (`main`, `warehouse`, `storage`).
- Define stock identity per product/warehouse and interaction of on-hand, reserved and available quantities.
- Reconcile the current non-negative `stock.quantity` CHECK with D-016.
- Define the exact negative-stock invariant and reserved-quantity behavior.
- Allow negative stock only through trusted RPC checks for `inventory.allow_negative`, requiring reason and recording user/device/time/shortage/operation ID.
- Align sale RPCs and every inventory write path with that policy.
- Preserve stock movements as inventory history.
- Align transfers with D-020: sent/in transit/received; destination stock is unavailable until receipt.
- Align inventory counts and adjustments with D-021.
- Never resolve stock conflicts through generic row overwrite.

Tests:
- Sale with sufficient stock.
- Shortage without permission rejected.
- Shortage with permission accepted only with reason and audit.
- Concurrent sales against remaining stock.
- Two offline devices sell overlapping stock; conflict is visible after sync.
- Transfer sent but not received does not increase available destination stock.
- Receipt adds stock exactly once, including duplicate retry.
- Inventory count adjustment requires permission/reason.
- Cross-store stock/location references fail.

**Gate G3:** D-016 and D-020 are enforced in DB/RPC layers and stock movements reconcile to balances.

## 8. Stage 4 — Device lifecycle and cursor integrity

**Findings:** F-06, F-07.  
**Likely files:** Schema, sync RPCs, sync design, security, SQLite sync documentation and tests.

Tasks:
- Define device states: registered, approved, active, revoked, and optional retired/replaced.
- Add explicit revocation/active state; `is_online` is not authorization.
- Define who can register, approve, revoke and reactivate devices.
- Check user/store membership, same-store device ownership, approval/revocation and required permissions in every sync entry point.
- Normalize `sync_cursors`: one canonical numeric cursor, non-negative CHECK, and a real same-store device reference.
- Define cursor behavior on revocation, replacement and reactivation.
- Prevent device removal from silently orphaning cursor rows.

Tests:
- Approved active device can sync.
- Unknown, other-store and revoked devices are rejected by pull/push/ack.
- Revocation is audited.
- Negative cursor and invalid device references fail.
- Replacement/reactivation follows documented policy.

**Gate G4:** All sync entry points enforce device lifecycle and cursor references are valid.

## 9. Stage 5 — Pull, acknowledgement and change-log contract

**Findings:** Synchronization risks in audit Sections 5.1–5.4 and F-10.  
**Likely files:** Schema, sync design, conflict design, integration guides, test plans and SQLite sync documentation.

Tasks:
- Document global per-store cursor allocation, per-table pull streams and per-device/per-table checkpoints.
- Define acknowledgement precisely. Recommended meaning: all events for the table up to that cursor have been durably applied locally.
- Specify page size, ordering, continuation, empty pages, retries and failed apply behavior.
- Client must not advance durable cursor past an unapplied event.
- Review `get_unsynced_records`: device state, membership, table allowlist, cursor bounds, ordering and paging.
- Review `acknowledge_sync_cursor`: device state, per-table semantics, monotonic advancement and validation against delivered/applied range.
- Decide whether a server-issued page token/delivery receipt is needed.
- Test atomic cursor allocation, rollback semantics, trigger coverage and tables without direct `store_id`.
- Ensure change-log entries commit atomically with business operations.

Tests:
- Concurrent cursor allocation across sessions.
- Rollback leaves no committed phantom event.
- More than 500 events page without loss/duplication.
- Failed local apply does not advance checkpoint.
- Duplicate delivery is harmless.
- Acknowledgement cannot move backward or jump beyond the documented boundary.
- Per-table cursor gaps are handled correctly.
- Every synchronized table has tested INSERT/UPDATE/DELETE behavior.

**Gate G5:** Server/client checkpoint contract is explicit and tested end-to-end.

## 10. Stage 6 — Safe conflict resolution

**Finding:** F-05. **Priority:** Critical before enabling conflict resolution.  
**Likely files:** Schema, conflict design, security, Phase 2/3 RPCs if used, tests and integration guide.

Tasks:
- Inventory supported conflict tables and operation types.
- Separate reference/master data, non-financial operations, inventory and financial/ledger data.
- Preserve protection against generic overwrites for financial/inventory tables.
- Define per-table/per-field allowlists; reject identity, store, audit, creator, deletion, derived and immutable fields unless a specific rule allows them.
- Require and validate a non-null merge payload for MERGE.
- Lock conflict and target rows in a consistent order; revalidate existence and store ownership in the same transaction.
- Include both record ID and store ID in final mutations.
- Define safe INSERT, UPDATE and DELETE conflict paths.
- Use domain RPCs for financial and inventory conflicts.
- Record actor, reason, before/after and outcome.
- Make resolution idempotent.

Tests:
- Missing permission and cross-store resolution rejected.
- Forbidden fields and invalid/missing MERGE payload rejected.
- INSERT/UPDATE/DELETE paths behave as specified.
- Financial and inventory conflicts cannot use generic overwrite.
- Concurrent resolution yields one effective result.
- Retry is idempotent and audit/change-log events are correct.

**Gate G6:** Do not enable general conflict resolution until adversarial tests prove safe mutation boundaries.

## 11. Stage 7 — RLS, grants, function hardening and audit

**Likely files:** Schema, security documents, tests and integration guides.

Tasks:
- Create role-by-role table permission matrix.
- Review permissive/restrictive RLS policy composition.
- Review table, sequence, schema and function grants.
- Remove broad test-only grants from deployment scripts.
- Review every SECURITY DEFINER function: owner, fixed search_path, qualified names, safe dynamic SQL, minimal EXECUTE grants and auth/permission checks.
- Do not trust caller-supplied actor/store IDs where authenticated context can establish them.
- Complete audit coverage for users/devices, roles, products/prices, sales/purchases, returns, payments, ledgers, stock/transfers/counts, expenses/revenues, sync/conflicts and backup/restore.
- Never log passwords, tokens, secrets or credentials.
- Prevent ordinary application roles from modifying/deleting audit records.

Tests:
- Role matrix allow/deny tests.
- Cross-store read/write tests.
- Direct table write denial where RPC-only access is intended.
- Function EXECUTE grant review.
- SECURITY DEFINER search_path review.
- Audit completeness and tamper attempts.

**Gate G7:** Least-privilege model is documented and automated security tests pass.

## 12. Stage 8 — Regression and staging acceptance

Tasks:
- Build a fresh disposable local database.
- Apply approved schema and repair migrations in documented order.
- Run schema, integrity, RLS, grants and RPC tests.
- Regression-test purchases/partial receiving, sales, returns, payments/allocations, customer/supplier ledgers, stock/transfers, and expenses/cash boxes where in scope.
- Run at least two simulated devices, offline retries, duplicate delivery and concurrency tests.
- Validate backup and restore.
- Only after local acceptance, test against real Supabase staging with real Auth/JWT behavior.
- Record logs, results, migration hashes and unresolved limitations.

**Gate G8:** Phase 1 repair is accepted only when all Critical/High findings in scope are fixed or explicitly deferred with an approved limitation, tests pass, no unexplained data loss/cross-store access occurs, backup/rollback is proven, and staging tests pass for intended release capabilities.

## 13. Migration and rollback policy

Each stage must have:
1. A uniquely named, ordered migration.
2. Pre-migration backup.
3. Preconditions that fail safely on an unexpected schema version.
4. A transaction where supported.
5. Post-migration verification.
6. A rollback plan.

Prefer additive changes, validated backfills and delayed removal of obsolete structures. If rollback after data writes is unsafe, state that explicitly and require a forward-fix plan plus verified backup. Never use `DROP ... CASCADE` as a shortcut. Do not blindly rerun non-idempotent migrations.

## 14. Proposed migration names

Names are provisional and must be reconciled with the project's existing migration convention:

- `PHASE1_REPAIR_001_SAME_STORE_INTEGRITY.sql`
- `PHASE1_REPAIR_002_SOFT_DELETE_TOMBSTONES.sql`
- `PHASE1_REPAIR_003_WAREHOUSES_STOCK_POLICY.sql`
- `PHASE1_REPAIR_004_DEVICE_LIFECYCLE_CURSORS.sql`
- `PHASE1_REPAIR_005_SYNC_CHECKPOINT_CONTRACT.sql`
- `PHASE1_REPAIR_006_SAFE_CONFLICT_RESOLUTION.sql`
- `PHASE1_REPAIR_007_SECURITY_GRANTS_AUDIT.sql`

Do not create or execute these migrations until their stage is approved.

## 15. Decisions that must remain intact

The implementation must preserve approved decisions, especially:
- D-009: no Last Write Wins for money/inventory.
- D-012/D-013: controlled sale-price override and weighted-average cost.
- D-014/D-015: independent returns with correct stock and ledger effects.
- D-016: negative stock only with dedicated permission, warning and audit.
- D-017/D-018: controlled edits/cancellations of confirmed transactions.
- D-019: role permissions, individual exceptions and server-side checks.
- D-020/D-021: multiple warehouses, transfers and auditable counts.
- D-024/D-025: backup safeguards and user/device management.
- D-026: one store in UI with database store isolation.
- D-027: safe invoice numbering.
- D-030/D-031: multiple units and controlled decimal quantities.
- D-045: comprehensive audit log.
- D-052 to D-061: partial receiving, damaged/rejected/alternative goods, direct receiving and temporary supplier rules.

If a technical repair conflicts with a business decision, stop and document the conflict. Do not reinterpret it silently.

## 16. Immediate next action

The next action is **review, not SQL execution**. Review this plan against the current files. The recommended first implementation stage is **Stage 0 — Freeze and capture the baseline**: it makes no schema or business-data changes and establishes the recovery point for later work.

*End of proposed implementation plan.*
