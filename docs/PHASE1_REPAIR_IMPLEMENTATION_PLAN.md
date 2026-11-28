# ATACK PLUS — Phase 1 Repair Implementation Plan

**Status:** Living implementation tracker — work is in progress; stage gates and deployment approvals remain mandatory  
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

**Current lifecycle safety rule (2026-11-27; Stage 2 remains open):**
- A record with a tombstone is considered soft-deleted and remains inactive.
- Generic Outbox updates and generic conflict resolution must not reactivate a tombstoned record.
- There is no Restore RPC in the current contract. Restoration is not supported until a separate, explicitly approved workflow defines its permissions, audit event, tombstone/change-log semantics, and client synchronization behavior.
- This is a safety restriction, not a claim that all entity-specific deletion/retention and cascade requirements in Stage 2 are complete.
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


## 17. Verified implementation progress register — 2026-11-27

This register records the implementation and test evidence present on
`repair/verified-fixes` at branch head
`8da00f89269833213662f3bb10fcb115a7eaf494`. It does not authorize
deployment or change the acceptance gates above.

**Status meanings**
- **Implemented / CI verified:** the relevant code and named automated
  regression have been run successfully in the stated CI environment.
- **Partial:** some implementation or tests exist, but the stage gate is
  not fully demonstrated.
- **Open:** no sufficient evidence currently closes the stage.
- A successful workflow is evidence only for the steps it actually runs;
  it is not proof of staging, production, or client acceptance.

### 17.1 Stage-by-stage status

| Stage | Current status | Verified work and evidence | Remaining acceptance work |
|---|---|---|---|
| Stage 0 — Freeze and capture baseline | **Open / not evidenced as complete** | A repair branch exists. | The plan's complete baseline hashes, database inventory, verified backup and restore/readability evidence are not recorded as a completed G0 package. |
| Stage 1 — Same-store referential integrity | **Implemented; automated SQL regression passed; G1 not fully closed** | Three migrations: `PHASE1_REPAIR_001_SAME_STORE_INTEGRITY.sql`, `PHASE1_REPAIR_002_EXTENSION_SAME_STORE.sql`, and `PHASE1_REPAIR_003_SYNC_AUDIT_SAME_STORE.sql`; regression scripts cover same-store references, extension references, sync/audit references and two-session parent/child concurrency. SQL migration workflow run `45995177555` completed successfully on commit `837f81e...`. | Complete relationship-matrix sign-off, review of legacy-data preflight against the intended staging dataset, and explicit staging acceptance remain open. The current Supabase Auth workflow does not apply these three repair migrations; therefore its successful run is not counted as Supabase Auth coverage for the Stage 1 repair migrations. |
| Stage 2 — Soft deletion, tombstones and product retention | **Partial; Part 2 hardening CI-verified, G2 open** | Authenticated/store-scoped `soft_delete_record`; entity allowlist and permission checks; target-row locking; tombstone/deactivation/audit/change-log transaction; repeated-delete idempotency; rollback regression; two-session concurrency regression; master-table direct-DML privilege assertions; real JWT/PostgREST denial checks for direct category PATCH/DELETE and successful soft-delete RPC. SQL workflow `46057837513` and Supabase Auth workflow `46057837615` both completed PASS on branch HEAD `71c0eb0e6df1ac0c8850ec69b4068e70fc48ad05`. | Entity retention policy documentation; full physical-delete denial matrix for history-bearing entities; per-FK cascade classification and remediation; cascade child change-log/pull/offline replay proof; tombstone identity invariant; SQLite parity; and complete G2 acceptance. No managed staging/production SQL was applied. |
| Stage 3 — Warehouses, stock and negative inventory | **Open / not closed** | Stock adjustment, receiving, returns and concurrent stock-operation code/tests exist in the Phase 2/3 business work. | These tests do not establish the Stage 3 requirements: store-owned multi-warehouse model and migration, D-016 permission-controlled negative stock, transfer lifecycle and reconciliation across all inventory write paths. |
| Stage 4 — Device lifecycle and cursor integrity | **Partial** | Device/user security migrations and regression files exist, including `ATACK_PLUS_PHASE3_USER_ROLE_DEVICE_SECURITY.sql`, `ATACK_PLUS_PHASE3_USER_ACCOUNT_SECURITY.sql`, and their regression scripts. | Verify every pull, push and acknowledgement entry point against active/revoked device state; prove cursor FK/type/non-negative constraints and lifecycle behavior; close the complete G4 matrix. |
| Stage 5 — Pull, acknowledgement and change-log contract | **Partial** | Sync hardening, Push/Outbox, cursor and sync regression files exist; the CI workflows execute multiple sync regression suites. | End-to-end proof of paging beyond 500 records, contiguous local apply/checkpoint behavior, failed-apply retry, acknowledgement meaning/bounds, and deterministic delete behavior for every independently synchronized table. |
| Stage 6 — Safe conflict resolution | **Partial** | The sync Push hardening file contains constrained conflict-resolution logic and excludes generic handling for sensitive financial/inventory records. | Complete per-table/per-field allowlist review, target-row locking and store-scoped mutation proof, explicit MERGE payload rules, INSERT/UPDATE/DELETE behavior, adversarial cross-store tests, concurrency and idempotency acceptance. |
| Stage 7 — RLS, grants, function hardening and audit | **Partial; selected suites passed** | Security catalog, audit, RBAC read, user/device, user-account and owner/seller migrations and regressions are present. The approved business model is one `owner` Super Admin and individual sellers; `cashier` remains the technical seller key displayed as **بائع**; legacy `admin`, `accountant`, and `stock_keeper` keys are disabled, not deleted or silently reassigned. SQL run `45971206966` and Supabase Auth/PostgREST run `45971206869` completed successfully on commit `f8a93b0...`. | These are selected automated security/RBAC checks, not a complete least-privilege review or full Stage 7 acceptance. Verify every table/sequence/function grant, every SECURITY DEFINER boundary, all audit coverage and real staging behavior. |
| Stage 8 — Regression and staging acceptance | **Partial; CI regression evidence exists, staging gate open** | Phase 2 business workflow run `45582736861` passed its listed business cases; SQL concurrency run `45903805852` passed its listed concurrency cases; Stage 1 SQL run `45995177555` passed; owner/seller SQL and Auth runs `45971206966` and `45971206869` passed. Seller invoice expectation correction runs `45693753617` (SQL) and `45693753776` (Supabase Auth) both completed successfully on commit `91341c0...`. | The Phase 3 test-plan template still contains NOT RUN cases. Managed Supabase staging, actual Android/Windows/Flutter clients, full offline multi-device replay, backup/restore acceptance and production readiness are not demonstrated by these CI runs. |

### 17.2 Important interpretation of the evidence

1. Stage 1 is not being restarted. Its three repair migrations and SQL
   regression evidence remain recorded as completed implementation work.
   The remaining items are acceptance and deployment checks, not a reason
   to repeat the same code changes.
2. The seller invoice test correction at commit
   `91341c050e1bdf88b1534ef9beb845261e2c1761` corrected the assertion to
   expect both invoices created by the seller and to exclude the owner's
   invoice. The SQL and Supabase Auth workflow runs listed above passed.
   This is a test-expectation correction, not a new business-role change.
3. The owner/seller consolidation is the approved business model. The
   technical key `cashier` must not be interpreted as a separate cashier
   job, and the inactive legacy role keys must not be reintroduced as
   business roles.
4. A local Supabase stack with real Auth/PostgREST integration is stronger
   than a PostgreSQL-only shim, but it is still not the user's managed
   Supabase staging or production environment.
5. The Phase 2/3 business and concurrency test results are valuable
   regression evidence. They do not automatically close the similarly
   numbered Stage 2/3 gates in this Phase 1 repair plan.

### 17.3 Current next step

Continue Stage 2 in order. Part 2 soft-delete idempotency, rollback,
concurrency and selected direct-DML security checks are now recorded as
CI-verified on branch HEAD
`71c0eb0e6df1ac0c8850ec69b4068e70fc48ad05`. Part 3-A defines the
entity-retention policy; Part 3-B must classify the actual foreign-key
delete actions and their effects before any cascade migration is designed.
Do not repeat Stage 1 implementation, do not skip ahead to Stage 3, and
do not apply migrations to managed staging or production without separate
approval.

*End of proposed implementation plan.*


## 18. Stage 2 — Part 3-A: approved entity-retention policy (2026-11-27)

**Status:** Policy approved by the project owner; documentation update only.
This section defines normal application behavior. It does not authorize
schema changes, physical deletion, migration execution, or staging/
production deployment.

### 18.1 Core principles

1. Business and financial history must not be erased by ordinary
   application actions.
2. Deactivation, cancellation/voiding, soft deletion and exceptional
   physical purge are distinct operations and must not be conflated.
3. A tombstoned entity remains inactive. Generic Outbox updates and
   generic conflict resolution must not reactivate it.
4. No Restore RPC is currently approved. Any future restoration flow
   requires its own permissions, audit event, tombstone/change-log
   semantics and client synchronization contract.
5. Physical purge, if ever required, must be a separately approved
   retention/maintenance workflow with dependency checks, verified
   backup/restore capability, audit evidence and an explicit legal/
   business retention basis.
6. A foreign-key CASCADE is not, by itself, authorization to erase
   business history. Every FK action must be assessed against this
   policy and the ownership/lifecycle of the child record.

### 18.2 Entity policy

| Entity | Normal application behavior | Retention requirement |
|---|---|---|
| Products | Deactivate/soft-delete through the approved RPC; do not physically delete | Preserve purchase/sales references, returns, stock history, movements and traceability |
| Product units | Do not remove while referenced by operational history | Preserve unit identity/conversion context needed to interpret historical lines |
| Categories and brands | Deactivate/soft-delete | Preserve historical product classification references where present |
| Customers | Deactivate/soft-delete | Preserve invoices, payments, allocations, returns, ledger and debt history |
| Suppliers | Deactivate/soft-delete | Preserve purchases, receipts, returns, supplier payments, allocations and ledger history |
| Sales invoices | Use controlled status transition, cancellation/voiding or correction workflow | Preserve invoice header, lines, payment relationships, returns and accounting effects |
| Purchases | Use controlled status transition, closure or cancellation workflow | Preserve purchase header, lines, receipts, amendments, returns and supplier-accounting effects |
| Invoice and purchase lines | No standalone destructive deletion after becoming part of a committed transaction | Preserve quantities, units, prices, costs, taxes and source relationships |
| Sales and purchase returns | Use controlled correction/reversal workflow; no ordinary physical deletion | Preserve return header/lines and resulting stock, ledger and journal effects |
| Customer and supplier payments | Correct/reverse through a documented financial operation; no ordinary physical deletion | Preserve payment identity, allocations and ledger effects |
| Payment allocations | Modify only through validated payment-application/reversal operations | Preserve the relationship between payment and invoice and its audit trail |
| Customer/supplier ledgers and journals | Correct through compensating/reversal entries, not destructive deletion | Preserve immutable financial history and source traceability |
| Stock balances and stock movements | Change balances only through authorized inventory business operations | Preserve movement/adjustment/transfer history and the ability to reconcile balances |
| Devices and sync metadata | Revoke/retire devices through lifecycle controls | Retain the audit and sync evidence required by the approved retention period |
| Audit log and change log | No ordinary application deletion or mutation | Preserve evidence needed for traceability, security review and synchronization |

### 18.3 Required distinctions

- **Deactivate:** prevent future ordinary use while retaining the entity and
  its references.
- **Soft-delete:** mark an eligible master record inactive and create its
  tombstone/audit/change-log evidence atomically.
- **Cancel/void/reverse:** record a business-state transition and, where
  necessary, compensating stock and financial entries; do not erase the
  original transaction.
- **Physical purge:** exceptional maintenance action only, never a
  generic user-facing delete operation.

### 18.4 CASCADE classification rule for Part 3-B

Part 3-B must inspect each actual FK definition and classify it as one
of:

1. **History-protecting:** change to RESTRICT/NO ACTION where cascading
   would erase a history-bearing or independently synchronized record.
2. **Parent-owned detail:** CASCADE may remain only if the child is
   exclusively owned by the parent, has no independent retention or
   synchronization requirement, and purge is explicitly permitted.
3. **Derived/ephemeral:** define whether the child is safely rebuildable
   or may be purged, and prove that through tests before retaining
   CASCADE.
4. **Store/system lifecycle:** assess separately; do not change store
   deletion or system-owned cascades as a side effect of business-record
   hardening.

No FK action is to be changed solely from its table name or from the
summary section of the schema. The actual CREATE TABLE/constraint
definition and dependent RPC, trigger, RLS, sync and test behavior are
the source of truth.

### 18.5 Acceptance conditions for Part 3-A

- This policy is documented in the implementation plan.
- The Stage 2 progress row and next-step note reflect the latest
  verified Part 2 CI evidence without claiming G2 closure.
- No SQL migration, live database change, frontend change or deployment
  is part of Part 3-A.

**Next:** Part 3-B — build the exact FK-by-FK CASCADE classification and
remediation matrix, including child change-log and independent sync
requirements.

## 19. Stage 2 — Part 3-C: FK cascade remediation plan (2026-11-27)

**Status:** Detailed remediation plan prepared after the Part 3-B static audit.
This is a planning/documentation step only. It does not authorize SQL edits,
migration execution, live database changes, CI claims, or deployment. The
owner must approve the proposed implementation scope separately.

### 19.1 Scope and source-of-truth rules

1. Protect business, financial, inventory, return, audit and synchronization
   history in accordance with the approved Part 3-A retention policy.
2. Inspect the base schema, Phase 1 same-store migrations, Phase 3 table
   creation files, later constraint alterations, triggers, RPCs, RLS/grants,
   Change Log/Pull contracts and tests together.
3. Treat the actual deployed PostgreSQL catalog as authoritative for a
   deployment decision. SQL files are intended-state evidence only; they do
   not prove that all migrations were applied in a given environment.
4. Before implementation, capture every FK's schema, table, constraint name,
   ordered source columns, referenced table/columns, delete action, update
   action, deferrability, validation state and supporting indexes from
   pg_constraint/pg_class/pg_attribute. Compare that catalog with the
   repository's intended schema and report drift.
5. Do not change store-level/system lifecycle relationships as a side effect
   of business-history hardening.

### 19.2 Confirmed CASCADE inventory and proposed treatment

The following inventory is based on the repository SQL reviewed for Part 3-B.
Constraint names must be resolved from the target catalog before migration;
do not assume generated names or silently drop similarly named constraints.

| Parent -> child | Current declared CASCADE | Proposed treatment | Rationale |
|---|---|---|---|
| stores -> devices | store_id | Separate store/system lifecycle review; retain only under an explicitly approved store purge workflow | Device retirement and sync evidence must not be casually erased |
| stores -> users | store_id | Separate store/system lifecycle review; no change in this business FK pass | User identity and attribution history |
| stores -> categories | store_id | Separate store/system lifecycle review | Master data belongs to store, but store purge is exceptional |
| stores -> brands | store_id | Separate store/system lifecycle review | Master data belongs to store, but store purge is exceptional |
| stores -> products | store_id | Separate store/system lifecycle review | Product and stock history retention |
| stores -> customers | store_id | Separate store/system lifecycle review | Customer and financial history |
| stores -> suppliers | store_id | Separate store/system lifecycle review | Supplier and financial history |
| users -> user_roles | user_id | Review separately; preserve role/audit attribution or retire user instead of deleting | User lifecycle and auditability |
| products -> product_units | product_id | Replace destructive parent deletion with restrictive behavior for ordinary lifecycle; retain only if a separately approved purge proves no history dependency | Unit identity/conversion context |
| products -> stock | product_id | Replace with restrictive protection or explicitly designed inventory archival/purge handling | Current stock must not disappear as a side effect |
| products -> purchase_items | product_id | Protect with RESTRICT/NO ACTION | Historical purchase line must remain interpretable |
| products -> purchase_return_items | product_id | Protect with RESTRICT/NO ACTION | Historical purchase return must remain interpretable |
| purchases -> purchase_items | purchase_id | Protect with RESTRICT/NO ACTION for committed purchases; any draft cleanup must be a distinct controlled workflow | Purchase line is business history |
| suppliers -> supplier_ledger | supplier_id | Protect with RESTRICT/NO ACTION | Supplier ledger is financial history |
| suppliers -> supplier_payments | supplier_id | Protect with RESTRICT/NO ACTION | Supplier payment is financial history |
| invoices -> invoice_items | invoice_id | Protect with RESTRICT/NO ACTION for committed invoices | Sales line and price/quantity history |
| invoices -> payment_allocations | invoice_id | Protect with RESTRICT/NO ACTION | Invoice-payment relationship is financial history |
| customer_payments -> payment_allocations | payment_id | Protect with RESTRICT/NO ACTION | Payment allocation is financial history |
| sales_returns -> return_items | return_id | Protect with RESTRICT/NO ACTION for committed returns | Return lines and stock effects |
| purchase_returns -> purchase_return_items | return_id | Protect with RESTRICT/NO ACTION for committed returns | Return lines and supplier-credit/stock effects |
| products -> purchase_return_items | product_id | Protect with RESTRICT/NO ACTION | Historical product reference in return |
| purchase_receipts -> purchase_receipt_items | receipt_id (including same-store composite FK) | Parent-owned detail classification, but retain only inside an approved purge of an uncommitted/invalid receipt; otherwise restrict | Receipt item is dependent detail, yet receiving history can affect stock and purchase settlement |
| purchase_closures -> purchase_closure_items | closure_id (including same-store composite FK) | Parent-owned detail classification, but retain only inside an approved purge of an uncommitted/invalid closure; otherwise restrict | Closure details explain purchase completion/remaining quantities |
| stores -> store_sync_counters | store_id | Derived/system lifecycle; retain only for separately approved full-store purge | Counter is technical state, but store purge needs coordinated sync retirement |

The source definitions also contain relationships that are not CASCADE and
must remain protective unless a separately justified design is approved:
for example purchases -> suppliers, customers -> customer_ledgers and
customer_payments, products -> stock_movements, products -> invoice_items,
products -> return_items, products -> stock_adjustments, products ->
inventory_batches and products -> stock_alerts. The exact deployed actions
must be confirmed from the catalog.

### 19.3 Corrections to the preliminary Part 3-B interpretation

1. The base CREATE TABLE definitions for customer_ledgers.customer_id and
   customer_payments.customer_id do not declare CASCADE.
2. purchases.supplier_id does not declare CASCADE.
3. products.stock_movements, invoice_items and return_items references do
   not declare CASCADE in the reviewed definitions.
4. purchase_return_items has two distinct cascades: return_id -> 
   purchase_returns and product_id -> products.
5. purchase_receipt_items and purchase_closure_items receive CASCADE through
   composite same-store FKs in Phase 1 Repair 002; these must be included
   alongside their base single-column relationships.
6. The schema's historical Foreign Keys Summary is not authoritative where
   it differs from executable CREATE TABLE/ALTER TABLE statements.

### 19.4 Change Log and audit remediation design

The current trg_log_change() resolves store ownership for some child rows by
querying their parent. During a parent-driven cascade, that lookup may no
longer resolve the parent. The current function returns OLD without writing
a DELETE change_log entry when v_store_id is NULL. This is a proven static
code path, but actual trigger ordering and effects must be demonstrated in
a PostgreSQL regression test before selecting the final implementation.

Implementation design requirements:

1. Make store ownership available without depending on a parent row that is
   being deleted. Prefer a stable store_id on history-bearing child rows
   where the data model supports it; otherwise use a carefully reviewed
   OLD-row ownership resolver or a controlled parent-before-child deletion
   workflow.
2. Do not infer a store from an untrusted client payload. Ownership must be
   validated against persisted rows and same-store constraints.
3. For a child DELETE, the Change Log event must be atomic with the delete
   and must carry the original child identity and sufficient old-state
   information for the receiving client to remove/update its local record.
4. Confirm whether tombstones are required for each independently synced
   entity. Do not create duplicate or contradictory tombstone semantics
   for cascade-generated child events.
5. Review audit_business_row_change() separately: it is attached to selected
   top-level entities, not every child table. Ensure parent-level audit
   captures the business operation and child-level Change Log remains
   complete without producing uncontrolled duplicate audit entries.
6. Preserve transaction rollback: if required audit/change-log persistence
   fails, the destructive operation must fail atomically.

### 19.5 Proposed implementation sequence

**Part 3-D1 — Catalog and drift preflight**
- Add a read-only SQL diagnostic query for all FK metadata and delete actions.
- Run it only against an isolated local test database after the owner approves
  test execution; never against staging/production without separate approval.
- Compare the output with the FK inventory above and resolve every mismatch.
- Check existing rows for orphaned references and cross-store mismatches
  before any constraint replacement.

**Part 3-D2 — FK migration design**
- Prepare a dedicated, ordered migration that changes only approved FK
  delete actions.
- Use exact catalog-resolved constraint names and verify source/target
  columns before DROP/ADD.
- Preserve composite same-store FKs, validation state, indexes and
  deferrability. Do not accidentally remove the single-column integrity
  constraints or same-store protections.
- Use RESTRICT/NO ACTION for history-bearing dependencies. Distinguish
  committed business records from any explicitly approved draft cleanup.
- Keep store/system lifecycle and user-role lifecycle out of this migration
  unless separately approved.
- Include preflight assertions and fail-fast checks; do not silently skip
  missing or differently defined constraints.

**Part 3-D3 — Change Log implementation**
- Implement the approved ownership-resolution strategy.
- Ensure parent/child deletion events are deterministic and ordered for
  incremental sync.
- Confirm Pull pagination/500-row behavior and cursor acknowledgement do
  not skip or reorder cascade-generated events.
- Confirm a client can process parent and child events idempotently even
  when it has already received one of them.

**Part 3-D4 — Regression and security tests**
- Parent delete is rejected when protected history exists.
- Soft deletion/deactivation continues to work and does not delete children.
- Explicitly approved draft/ephemeral cleanup affects only its intended
  dependent rows.
- Child Change Log DELETE event is emitted with correct store_id and record
  UUID for every supported cascade path.
- Pull returns the child event; ACK advances only after the expected event
  has been delivered.
- Failed audit/change-log insertion rolls back the entire operation.
- Two concurrent delete attempts cannot produce partial or duplicate state.
- Cross-store references remain rejected.
- Authenticated users cannot bypass the approved RPC/security model with
  direct DML.
- Existing purchase, sales, return, stock, ledger and accounting regression
  suites remain green.

**Part 3-D5 — CI and acceptance**
- Run SQL migration smoke and Supabase Auth integration workflows on the
  repair branch.
- Inspect workflow jobs and logs, not only the top-level run status.
- Record exact commit SHA, workflow run IDs, test names and results.
- Restore-test a backup in an isolated clean database before any managed
  environment rollout.
- Staging and production application remain separate decisions requiring
  explicit approval.

### 19.6 Acceptance gates for the implementation

Part 3-D cannot be considered complete until all of the following are
evidenced:

- Actual FK catalog matches the approved migration preconditions.
- Every history-bearing CASCADE has been removed or proven safe under a
  separately approved purge-only workflow.
- Store/system lifecycle relationships have not been changed accidentally.
- Child delete Change Log behavior is proven by executable PostgreSQL tests.
- Pull/ACK behavior is proven with multi-table and multi-device regression.
- Rollback, concurrency, same-store integrity, RLS/grants and business
  regressions pass.
- CI passes on the exact repair-branch HEAD.
- No staging/production migration is implied by branch CI success.

**Next decision:** owner approval of this plan and its implementation scope.
Only after approval may Part 3-D1/D2 code and test changes begin. SQL
execution against a database remains a separate approval.


### 19.7 Part 3-D1 preparation and execution results — 2026-11-27

**Status:** Read-only preflight executed successfully against the disposable PostgreSQL 16 database in GitHub Actions. This is CI-schema evidence only, not a catalog or data audit of the user's local, staging or production database.

Added `tests/phase2-fk-catalog-preflight.sql` and a dedicated step to `.github/workflows/sql-migrations-smoke.yml` on `repair/verified-fixes`. The script reports:
- Every declared FK's source/target schema, table and ordered columns.
- ON DELETE / ON UPDATE actions, deferrability, initial deferral and validation state.
- Per-FK orphan-reference row counts.
- Cross-store reference counts when both related tables expose `store_id` and the FK does not bind those store columns together.

**Execution evidence**
- Workflow: SQL migration smoke test, run `46068143484`.
- Commit SHA: `7682b5ad6141c49ff1cff5941f517ea64232d3f6`.
- Result: completed / success; all preceding schema, migration and regression steps also completed successfully.
- The catalog query returned **143 FK constraints**. All 143 were marked validated; all were non-deferrable and not initially deferred in this ephemeral schema.
- **25 FK constraints** reported `ON DELETE CASCADE`. This count is by constraint, not by distinct parent-child table pair.
- The catalog confirms that receipt-item and closure-item tables each have both a single-column parent FK and a composite same-store parent FK. Both constraints must be handled deliberately in any migration; neither may be accidentally dropped while changing delete actions.
- The diagnostic emitted **zero orphan-reference rows** and **zero cross-store-reference rows** for all checks it performed in this CI database.
- The read-only transaction ended with `ROLLBACK`; the diagnostic made no persistent database changes.

**Interpretation and limitations**
- The successful CI run validates that the diagnostic SQL parses and executes against the repository's fully applied PostgreSQL 16 test schema, and that the tested schema/data snapshot has no detected orphan or cross-store rows.
- CI's disposable database is not the user's actual database. Its zero counts do not prove that local, staging or production data are clean.
- The 143-row catalog is the actual catalog for this CI-applied schema. Before rollout, the same catalog comparison must be run against the intended target database under a separate explicit approval.
- The 25 CASCADE constraints include business-history dependencies as well as store/system lifecycle and parent-owned detail relationships. Do not treat all 25 as one blanket replacement set; apply the classifications and exclusions in Sections 19.3 and 19.5.
- This result completes the **CI execution portion of Part 3-D1 only**. It does not close the real-database drift/data preflight, approve an FK migration, or authorize staging/production changes.

The CI step is present in the SQL migration workflow and must remain read-only. No SQL migration was applied to a persistent environment, and no merge to `main` occurred.


### 19.8 Part 3-D2 — detailed FK migration specification (2026-11-27)

**Status at the time this section was written:** Design specification only; migration SQL had not yet been authored. The owner subsequently approved the matrix and fail-fast contract, and implementation/CI evidence is recorded in Section 19.9. Section 19.9 supersedes the implementation-status statements below; this section remains the historical design specification.

#### A. Evidence baseline and limits

The specification is based on the PostgreSQL 16 catalog output from SQL migration smoke workflow run `46068143484`, commit `7682b5ad6141c49ff1cff5941f517ea64232d3f6`, and the repository schema/extension definitions reviewed on `repair/verified-fixes`.

The CI catalog reported 25 CASCADE constraints, all validated, non-deferrable and not initially deferred. This is the intended repository-applied schema in an ephemeral CI database, not proof of the user's local/staging/production catalog. The target catalog must be re-read and compared under a separate approval before any rollout.

The executable CREATE TABLE/ALTER TABLE definitions and catalog output take precedence over the stale `Foreign Keys Summary` block at the end of `POSTGRES_SCHEMA_PHASE1_FIXED.sql`. In particular, that summary incorrectly describes some product/stock-movement and business references. The CI catalog confirms `stock_product_id_fkey` is CASCADE, while the reviewed `stock_movements` product reference is not among the 25 CASCADE constraints.

#### B. Proposed action matrix

The following 16 constraints are proposed to change from CASCADE to RESTRICT in the dedicated business-history FK migration. RESTRICT is selected as an immediate parent-delete guard. No child rows are to be deleted by this migration.

| Child table | Exact CI constraint | Parent | Proposed delete action | Reason |
|---|---|---|---|---|
| invoice_items | invoice_items_invoice_id_fkey | invoices | RESTRICT | Preserve committed invoice lines |
| payment_allocations | payment_allocations_invoice_id_fkey | invoices | RESTRICT | Preserve invoice-payment allocation history |
| payment_allocations | payment_allocations_payment_id_fkey | customer_payments | RESTRICT | Preserve payment allocation history |
| product_units | product_units_product_id_fkey | products | RESTRICT | Prevent silent loss of product unit/conversion configuration |
| stock | stock_product_id_fkey | products | RESTRICT | Prevent silent removal of current stock balance |
| purchase_items | purchase_items_product_id_fkey | products | RESTRICT | Preserve purchase line/product relationship |
| purchase_items | purchase_items_purchase_id_fkey | purchases | RESTRICT | Preserve purchase lines and receiving basis |
| purchase_return_items | purchase_return_items_product_id_fkey | products | RESTRICT | Preserve returned-product identity |
| purchase_return_items | purchase_return_items_return_id_fkey | purchase_returns | RESTRICT | Preserve purchase-return details |
| return_items | return_items_return_id_fkey | sales_returns | RESTRICT | Preserve sales-return details |
| supplier_ledger | supplier_ledger_supplier_id_fkey | suppliers | RESTRICT | Preserve supplier financial ledger |
| supplier_payments | supplier_payments_supplier_id_fkey | suppliers | RESTRICT | Preserve supplier payment history |
| purchase_receipt_items | purchase_receipt_items_receipt_id_fkey | purchase_receipts | RESTRICT | Preserve receipt detail by default |
| purchase_receipt_items | fk_purchase_receipt_items_receipt_store | purchase_receipts (id, store_id) | RESTRICT | Preserve composite same-store relationship |
| purchase_closure_items | purchase_closure_items_closure_id_fkey | purchase_closures | RESTRICT | Preserve closure detail by default |
| purchase_closure_items | fk_purchase_closure_items_closure_store | purchase_closures (id, store_id) | RESTRICT | Preserve composite same-store relationship |

The four receipt/closure constraints are deliberately retained as four separate constraints, with both single-column and composite same-store forms. They must not be collapsed into one constraint or replaced by a weaker single-column relationship.

A future privileged cleanup of a genuinely uncommitted draft may explicitly remove eligible child rows before deleting the parent, but only through a separately reviewed workflow that verifies status, absence of stock/accounting effects, audit/change-log behavior, and authorization. A global FK CASCADE cannot enforce such status-dependent rules; therefore the default FK action remains RESTRICT.

#### C. Explicit exclusions — nine constraints remain outside this migration

| Exact CI constraint | Relationship | Treatment |
|---|---|---|
| brands_store_id_fkey | brands -> stores | Exclude; separate store lifecycle policy |
| categories_store_id_fkey | categories -> stores | Exclude; separate store lifecycle policy |
| customers_store_id_fkey | customers -> stores | Exclude; separate store lifecycle policy |
| devices_store_id_fkey | devices -> stores | Exclude; separate device/store lifecycle policy |
| products_store_id_fkey | products -> stores | Exclude; separate store lifecycle policy |
| suppliers_store_id_fkey | suppliers -> stores | Exclude; separate store lifecycle policy |
| users_store_id_fkey | users -> stores | Exclude; separate store/user lifecycle policy |
| user_roles_user_id_fkey | user_roles -> users | Exclude; separate user deactivation/identity/audit policy |
| store_sync_counters_store_id_fkey | store_sync_counters -> stores | Exclude; separate sync/store lifecycle policy |

Exclusion is not approval for physical deletion. It means these relationships must not be modified by this business-history migration. Store shutdown/purge and user lifecycle require their own explicit policy and tests.

#### D. Migration preconditions and fail-fast contract

Before a future migration may run, it must:

1. Verify the exact source and referenced schemas/tables, ordered source and referenced columns, constraint name, current delete action, update action, deferrability, initial deferral and validation state for every one of the 16 constraints.
2. Abort the entire transaction if a constraint is missing, duplicated, has a different definition, references unexpected columns, is not validated, or has a different delete action from the approved baseline. No `IF EXISTS` / `IF NOT EXISTS` behavior may silently hide drift.
3. Verify all 16 target constraints are present and validated before changing any of them.
4. Verify the four receipt/closure constraints retain both the single-column and composite same-store forms; preserve their exact ordered column pairs.
5. Run orphan-reference and cross-store preflight checks for relevant relationships. Any nonzero result is a stop condition requiring investigation, not automatic cleanup.
6. Verify the intended target database identity/environment and record the catalog snapshot and migration target SHA before execution. Target execution requires separate explicit owner approval.

#### E. Ordered migration behavior (design only)

The eventual migration must be a single, transactionally applied migration:

1. Begin transaction and acquire an explicit migration lock to prevent concurrent application of the same migration.
2. Execute all fail-fast catalog and data preconditions before DDL.
3. Replace only the 16 approved constraints, preserving exact names and column mappings while changing only `ON DELETE` from CASCADE to RESTRICT.
4. Do not modify `ON UPDATE`, indexes, primary/unique keys, column nullability, deferrability, validation state, triggers, RLS, grants, or unrelated constraints.
5. Re-query the catalog inside the transaction and assert all 16 are present, validated, non-deferrable, and RESTRICT; assert the nine excluded constraints remain CASCADE and unchanged.
6. Commit only if every assertion passes; otherwise roll back the complete migration.

This sequence is a behavioral specification, not executable SQL and not authorization to run it.

#### F. Required regression matrix before acceptance

- Attempt physical deletion of an invoice with invoice_items and payment allocations: parent deletion must fail and all rows remain unchanged.
- Attempt deletion of a customer payment with allocations: deletion must fail and allocations remain.
- Attempt deletion of a product with product_units, stock, purchase lines, or purchase-return lines: deletion must fail; soft deletion remains available and must not delete children.
- Attempt deletion of a purchase with purchase_items, receipts, closures, or returns: deletion must fail; verify no receiving/stock/accounting side effects.
- Attempt deletion of a sales return or purchase return with details: deletion must fail.
- Attempt deletion of a supplier with ledger/payment history: deletion must fail.
- Verify both single-column and composite same-store receipt/closure constraints remain validated and reject cross-store associations.
- Verify allowed draft cleanup only through its separately authorized path, with explicit child handling, audit and Change Log coverage; no implicit cascade.
- Verify rollback on any failed precondition/DDL assertion, concurrent migration attempts, direct-DML denial, and existing business regression suites.
- Verify soft-delete idempotency and tombstone behavior are unchanged.
- After the later Change Log work, verify parent/child sync semantics and Pull/ACK ordering; FK migration acceptance alone does not close Part 3-D3/D4.

#### G. Outstanding evidence and scope boundary

- The target database catalog/drift/data preflight from Part 3-D1 remains outstanding.
- The static review of current repository SQL delete paths was subsequently performed and is recorded in Section 19.9. It does not prove behavior of arbitrary manual SQL or unknown external integrations.
- The actual PostgreSQL trigger behavior for cascade-generated child DELETE events remains a Part 3-D3/D4 test requirement.
- The historical statement that no migration/test code had been authored applies only to the design snapshot in this section. The implementation and CI results are recorded in Section 19.9.
- No persistent local, staging or production database operation, merge to `main`, or frontend work is included in Part 3-D2.

The 16-constraint matrix and fail-fast contract were approved and implemented as recorded in Section 19.9. The next step, Part 3-D3, requires its own approval before code changes; database execution remains separately approved.


### 19.9 Part 3-D2 — migration and regression implementation (2026-11-27)

**Status:** Migration authoring and isolated CI validation are complete on `repair/verified-fixes`. The approved migration has not been applied to any persistent local, staging or production database.

#### A. Final application-path review

Before authoring the migration, the current SQL implementation files were reviewed for physical DELETE statements and relevant trigger behavior, including the Phase 2 business RPCs, returns/inventory/accounting, purchase receiving/amendments/returns, stock adjustments, sync Push, security/RBAC, audit and user/device security files.

Findings:
- No physical DELETE statement was found in the reviewed business sales, purchase, receiving, return, stock-adjustment, accounting or sync business RPC implementations.
- The explicit application-level deletes found in the reviewed current files are limited to user-role revocation (`user_roles`) and cleanup of legacy permission grants (`role_permissions`). These are not any of the 16 business-history relationships changed by this migration.
- The base schema contains a legacy dynamic Outbox DELETE branch, but the later/current `apply_outbox_operation` definition in `ATACK_PLUS_PHASE3_SYNC_PUSH_HARDENING.sql` supersedes it: generic Push accepts INSERT/UPDATE only and routes eligible master-record deletion through `soft_delete_record`.
- The accounting validation trigger runs after DELETE on `general_ledger` to revalidate journal balance; it is not itself a business deletion path. Audit logs have explicit immutable UPDATE/DELETE/TRUNCATE protection.
- This was a static review of the current repository SQL files and definitions, not proof about arbitrary SQL run manually by a database owner or unknown external integrations.

#### B. Implemented migration

Added `docs/PHASE2_REPAIR_004_FK_HISTORY_RESTRICT.sql`.

The migration:
1. Runs in one transaction and takes a transaction-scoped advisory lock.
2. Creates a transaction-local, explicit 16-constraint allowlist with exact child/parent tables and ordered column mappings.
3. Locks the affected child tables in a stable order.
4. Fails before DDL if any of the 16 constraints is missing or differs from the approved schema, column mapping, CASCADE delete action, NO ACTION update action, validation state or non-deferrable state.
5. Verifies the nine lifecycle exclusions remain present and CASCADE, and that the initial public CASCADE inventory is exactly 25.
6. Replaces only the 16 named constraints, preserving their names and column mappings, changing only ON DELETE to RESTRICT.
7. Re-reads the catalog and asserts all 16 are validated RESTRICT constraints and exactly nine public CASCADE constraints remain.
8. Rolls back the entire transaction on any failed precondition or postcondition.

Both the single-column and composite same-store constraints for purchase receipt items and purchase closure items are retained as separate RESTRICT constraints. No FK was collapsed or weakened.

#### C. Regression and CI

Added `tests/phase2-fk-cascade-remediation-regression.sql` and appended the migration/test steps to `.github/workflows/sql-migrations-smoke.yml`. The workflow runs the migration only against its disposable PostgreSQL 16 service, after the read-only Part 3-D1 catalog preflight.

The regression verifies:
- Exact names, source/target tables, ordered column mappings, ON DELETE RESTRICT, ON UPDATE NO ACTION, validation and non-deferrable state for all 16 constraints.
- Exactly nine lifecycle-exclusion CASCADE constraints remain.
- Real parent DELETE attempts are blocked for all 16 relationships when dependent rows exist. A minimal product-unit dependent fixture is created inside the test transaction so this relationship is exercised too; the test ends with ROLLBACK and leaves no fixture data behind.

**Final CI evidence**
- SQL migration smoke test: [run 46070761211](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/46070761211).
- Tested commit: `a543c29ba9011ba22cecff4b0352df02c48b2f18`.
- Job: `140746879372`.
- Result: completed / success.
- Migration application step: success.
- FK remediation regression step: success.
- Regression log: **16 RESTRICT contracts verified; real dependent-row DELETE checks executed for all 16 constraints**.
- The first regression attempt exposed an aliasing defect in the test's dynamic parent-row selection. The migration itself applied successfully; the test was corrected, then the complete SQL workflow was rerun and passed. The failed first run is not counted as acceptance evidence.

#### D. Completion and remaining boundaries

Part 3-D2 migration code and its disposable-CI regression are complete. This does **not** close Stage 2 or authorize deployment:
- The actual target database catalog/drift/orphan/cross-store preflight remains outstanding and must be performed under separate explicit approval.
- No persistent local, staging or production database was touched.
- No merge to `main` was performed.
- No Change Log child-delete event, Pull/ACK ordering or client reconciliation behavior is implemented or proven by this FK migration. Those remain in the later Part 3-D3/D4 scope.
- The nine lifecycle exclusions remain a separate store/user/device/sync lifecycle decision; their presence is not permission to physically purge those entities.

The next planned work is Part 3-D3 (Change Log child-delete event semantics and sync contract), which requires its own approval before code changes.


### 19.10 Part 3-D3.1 — Change Log ownership and child DELETE hardening

**Status:** Implemented on `repair/verified-fixes`; isolated PostgreSQL CI validation is pending the workflow run for this commit. No persistent database has been modified.

#### A. Function definitions and migration order

Both definitions of `public.trg_log_change()` were updated: the base schema definition and the later override in `ATACK_PLUS_PHASE3_RETURNS_INVENTORY_ACCOUNTING.sql`. This keeps the base definition fail-closed if used independently and preserves the intended final implementation after the repository SQL application order.

- An unresolved `store_id` now raises an exception for INSERT, UPDATE and DELETE. The silent DELETE return was removed; an unresolved ownership identity or failed Change Log write aborts the source statement atomically.
- The base definition resolves `return_items` directly from `sales_returns.store_id`.
- The final override resolves `return_items` directly from `sales_returns.store_id` and `purchase_return_items` directly from `purchase_returns.store_id`; the unnecessary joins to invoices/purchases were removed.
- The transactional `log_change()` / `get_next_change_cursor()` path was not changed. D2's 16 RESTRICT constraints and nine lifecycle exclusions were not changed.

#### B. Regression coverage

Added `tests/phase2-change-log-child-delete-regression.sql` and a CI step after the D2 FK regression. The disposable PostgreSQL 16 test exercises DELETE events for all 11 parent-derived child tables, direct deletion of a store-owned category, fail-closed rollback of a store DELETE whose lifecycle cascade cannot retain the per-store cursor row, atomic rollback when Change Log insertion fails, and catalog coverage for all 34 synchronized tables with enabled AFTER ROW INSERT/UPDATE/DELETE triggers bound to the effective function.

#### C. Boundaries

CI exposed that deleting a store can cascade-delete its store_sync_counters row before a cascaded category trigger allocates its DELETE cursor. D3.1 therefore verifies that this operation fails closed and rolls back parent and child, rather than claiming the cascade is sync-safe. An explicit store lifecycle/deletion policy and durable cursor strategy are deferred to the appropriate later D3 design; no store cascade policy or FK was changed here. Pull/ACK semantics, pagination, client reconciliation, and generic Outbox behavior remain unchanged. CI results will be appended after the workflow run. No persistent local/staging/production database execution and no merge to `main` are included.


### 19.11 D3.2 / R1 — Pull owner/seller read isolation

**Status:** Implemented on `repair/verified-fixes`; disposable PostgreSQL CI validation is pending. No persistent database has been modified.

#### A. Finding and implementation

The existing `get_unsynced_records()` function is `SECURITY DEFINER` and queried `change_log` using only store, table and cursor predicates. Direct-table RLS policies therefore did not enforce the owner/seller visibility contract for Pull.

Added `docs/PHASE3_REPAIR_005_SYNC_PULL_RBAC.sql`:
- Adds a private, fixed-search-path `can_read_sync_change()` visibility resolver, with direct execution revoked from application roles.
- Applies the existing permission catalog to every Pull allowlisted table.
- Preserves store-wide shared product/customer/inventory visibility according to the user's permissions.
- Restricts invoices to their seller; invoice items inherit invoice ownership.
- Restricts sales returns and return items through the original invoice.
- Restricts customer payments and customer ledgers by their authenticated creator.
- Restricts payment allocations to the same seller's payment and invoice, and verifies the customer relationship.
- Validates store ownership for child records through their authoritative parent, including product units, stock, purchase children, receipt children, closure children, supplier payments and supplier ledger rows.
- Filters tombstones by the permission required to read the target entity, rather than requiring the seller to hold the administrative `sync.manage` permission.
- Retains the trusted service-role path and the existing per-table Pull response shape/page limit. The duplicate `tombstones` entry in the allowlist is removed.

The implementation preserves the technical `cashier` role key and does not rename roles or change business permissions.

#### B. Regression and CI

Added `tests/phase3-sync-pull-rbac-regression.sql` with two sellers and one owner in the same store. It checks seller-specific invoice headers, invoice items, returns, return items, customer payments, customer ledgers and payment allocations; shared product visibility; denial of purchase and supplier-payment events; target-scoped product/supplier tombstones; and owner-wide visibility.

The SQL migration and regression were added to `.github/workflows/sql-migrations-smoke.yml` after owner/seller role consolidation. The workflow uses only its disposable PostgreSQL 16 service.

**CI evidence**
- SQL migration smoke test: [run 46129696479](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/46129696479) — completed / success on commit `c1fde108a302cfc38c9e69768dbfe75ffbb4e002`.
- Job `140931928555`: migration step and R1 regression step both completed / success.
- Regression notices: `PASS: seller Pull is restricted to own sales chain, shared products and authorized tombstones`; `PASS: owner Pull retains store-wide visibility`.
- The workflow also completed the existing SQL migration, RBAC, role-matrix, FK and Change Log regression steps successfully.
- This is isolated PostgreSQL 16 CI evidence, not staging/production acceptance.

#### C. Boundaries and remaining D3.2 work

- No local, staging or production database was touched.
- No merge to `main` was performed.
- R1 does not authenticate the physical device; that remains R2.
- R1 does not add delivery proof to ACK; that remains R3.
- Tombstone event identity, lifecycle, pagination and client reconciliation remain in R4–R7.
- Staging acceptance and client-side local-transaction tests remain open.


### 19.12 D3.2 / R2 — authenticated device credential binding

**Status:** Implemented on `repair/verified-fixes`; disposable PostgreSQL CI validation is pending. No persistent database has been modified.

#### A. Audited current state

The existing `devices` row held only a UUID, store, device name/type and online metadata. Pull, ACK and generic Push accepted a caller-supplied `device_id` after checking only that the row existed in the requested store. There was no user assignment, credential, revocation state or controlled device registration/rotation RPC. The legacy `process_outbox_entry` function was already revoked from application roles and remains unavailable.

The existing device RLS/write policy required `sync.manage`, which is an owner-controlled capability in the consolidated owner/seller role model. R2 preserves that boundary: the owner provisions devices for active store users; sellers cannot register or manage devices.

#### B. Implementation

Added `docs/PHASE3_REPAIR_006_DEVICE_CREDENTIAL_BINDING.sql`:
- Adds a private `device_credentials` table binding device, store and assigned application user.
- Stores only a SHA-256 digest of a 64-hex-character bearer credential generated from two UUID-v4 values (244 bits of entropy). The raw token is returned once by provisioning/rotation RPCs and is never stored in the table or audit log.
- Adds owner-controlled `register_sync_device`, `rotate_sync_device_credential` and `revoke_sync_device` RPCs, requiring `sync.manage`.
- Audits registration, credential rotation and revocation without recording the raw token.
- Revokes direct authenticated INSERT/UPDATE/DELETE on `devices`; device management must use the audited lifecycle RPCs.
- Adds a private credential assertion helper that binds the presented device ID and token to the authenticated application user and store, and locks the device/credential rows during validation.
- Adds credential-bearing overloads for Pull, ACK, Outbox enqueue and Outbox apply.
- Revokes the tokenless Pull/ACK/Push/apply signatures from authenticated clients while retaining the existing trusted service-role signatures.
- Revoked devices cannot sync. Revoked devices are not reactivated by rotation; replacement uses a newly registered device ID, avoiding accidental reuse of an old device checkpoint.

The existing `is_online` field remains presence metadata, not an authorization signal. The technical `cashier` role key is unchanged.

#### C. Compatibility and acceptance boundary

Authenticated clients must migrate to the credential-bearing RPC overloads and securely retain the device token. Existing device rows without a credential cannot authenticate through the new authenticated RPC signatures; they require owner-controlled re-registration. No Flutter client exists in this repository, so secure local token storage and client request wiring remain future client acceptance work. This compatibility impact must be considered before any staging rollout.

#### D. Regression and CI

Added `tests/phase3-device-credential-regression.sql` and CI steps after R1. The test covers owner provisioning, one-way hash storage, seller/device binding, wrong-token rejection, cross-user impersonation rejection, Pull/ACK/Push/apply using a valid token, tokenless RPC denial, token rotation, and revocation/idempotent revocation.

**CI evidence**
- SQL migration smoke test: [run 46130691547](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/46130691547) — completed / success on commit `9fc237c8b93a3f7f268d3cf7f20b42d7f1b98fe8`.
- Job `140934952743`: D3.2 device credential migration and regression both completed / success.
- Regression notices confirm owner provisioning, one-way hash storage, assigned seller Pull/ACK/Push/apply, cross-seller impersonation denial, credential rotation, previous-token rejection, idempotent revocation and revoked-device Pull denial.
- Existing R1 Pull RBAC regression also passed in the same run.
- This is isolated PostgreSQL 16 CI evidence, not staging/production acceptance.

No local, staging or production database was touched; no merge to `main` was performed.


### 19.13 D3.2 / R3 — server-issued delivery pages and delivery-bound ACK

**Status:** Implemented on `repair/verified-fixes`; disposable PostgreSQL CI validation is pending. No persistent database has been modified.

#### A. Delivery contract

The R2 credential-bearing Pull/ACK overloads still allowed an authenticated device to ACK a cursor that existed in Change Log without proving that the server had issued that page to that device. R3 replaces those authenticated paths with a page ledger.

Added `docs/PHASE3_REPAIR_007_SYNC_DELIVERY_ACK.sql`:
- Adds private `sync_delivery_pages`, binding a page to store, device, table, cursor range, event count, has-more state, page hash and device credential version.
- Adds `get_unsynced_records_page(store_id, device_id, table_name, device_token)`, returning a server-issued `delivery_id`, authorized events, visible event count and `has_more`.
- Adds delivery-bound `acknowledge_sync_cursor(store_id, device_id, table_name, delivery_id, device_token)`. The client no longer supplies an arbitrary cursor.
- Requires pages to be acknowledged in order; duplicate ACK of the same page is idempotent.
- A page retry before ACK returns the same delivery identity when its contents and metadata have not changed.
- Rejects delivery IDs belonging to another device, store or table, and rejects delivery pages issued under a previous credential version.
- Revokes authenticated access to the older cursor-only and credential-only Pull/ACK signatures; trusted service-role paths remain available.
- Computes `has_more` only over events visible to the caller. If a table has no visible events, the server advances the device's checkpoint across the invisible range internally and returns an empty response without exposing hidden event counts, identities, cursor values or a delivery ID.

The page contract deliberately does not expose internal cursor numbers to the client. The server stores and advances the per-device/table cursor after a valid delivery ACK.

#### B. Client-side boundary

A Delivery ID proves that the server issued a particular page to the registered device; it does not prove that the client committed the page to local storage. The future client must apply the page atomically, persist the Delivery ID with the local transaction, and ACK only after successful commit. This remains a client acceptance requirement because no Flutter source is present in the repository.

#### C. Regression and CI

Added `tests/phase3-sync-delivery-ack-regression.sql` and appended R3 migration/test steps to `.github/workflows/sql-migrations-smoke.yml`. Coverage includes:
- ACK with a fabricated/undelivered page ID is rejected.
- A different device cannot ACK another device's page.
- Retry of an unacknowledged page returns the same delivery ID and page hash.
- Duplicate ACK is idempotent.
- 1,201 visible events are delivered in sequential 500/500/201 pages without gaps or duplicates.
- Hidden purchase events are not returned and do not leak `has_more`, counts, cursor values or delivery IDs; the invisible range is checkpointed safely.
- Direct access to the private delivery ledger is denied.

**CI evidence**
- SQL migration smoke test: [run 46131913921](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/46131913921) — completed / success on commit `e4e70d86372b12bbc5cf451334b341c59cc578a3`.
- Job `140938739380`: R1 Pull RBAC, R2 device credential binding and R3 delivery-bound ACK migration/regression steps all completed / success.
- R3 regression notices confirm replay-stable page issuance, fabricated and cross-device ACK rejection, idempotent ACK, 1,201 events delivered across sequential pages without gaps/duplicates, and hidden-only stream checkpointing without metadata disclosure.
- Existing SQL migration, FK, Change Log, RBAC and security regression steps also completed successfully.
- This is isolated PostgreSQL 16 CI evidence, not staging/production acceptance.

No local, staging or production database was touched; no merge to `main` was performed.


### 19.14 D3.2 / R4 — canonical Tombstone DELETE event contract

**Status:** Implemented on `repair/verified-fixes`; disposable PostgreSQL CI validation is pending. No persistent database has been modified.

#### A. Identity and uniqueness decision

The five soft-delete targets (`categories`, `brands`, `products`, `customers`, `suppliers`) use a globally unique UUID `id` primary key and a non-null UUID `store_id`. Therefore the approved logical identity remains `store_id + table_name + record_uuid`, while the existing database constraint `UNIQUE(table_name, record_uuid)` is a stronger duplicate guard. It is intentionally retained; adding `store_id` to that constraint would weaken protection without adding a valid identity case under the current global-PK schema. A constraint comment records the reason and the condition that would require revisiting it.

The polymorphic Tombstone row ID remains distinct from the original record UUID. The original target is validated by `soft_delete_record` against both ID and store before a Tombstone is created.

#### B. Canonical Pull envelope

Added `docs/PHASE3_REPAIR_008_TOMBSTONE_EVENT_CONTRACT.sql`, replacing the R3 page serializer while preserving its delivery ledger and ACK behavior:
- A Tombstone INSERT is exposed as logical `event_type = DELETE` and `operation = DELETE`.
- The event's `table_name` and `record_uuid` identify the original target entity.
- `tombstone_id` separately identifies the Tombstone row.
- The envelope carries `store_id`, `deleted_at` and `deleted_by`.
- The transport page remains the `tombstones` stream.
- Tombstone UPDATE and physical DELETE metadata events are excluded from the client delete stream; the canonical signal is the original Tombstone INSERT.
- The existing operation order is preserved: Tombstone INSERT is logged before the original target's inactive-state UPDATE. Client reconciliation must treat the Tombstone as authoritative and ignore stale updates that would otherwise reintroduce an active record.

#### C. Regression and CI

Added `tests/phase3-tombstone-event-contract-regression.sql` and CI steps after R3. It checks:
- All five soft-delete targets retain UUID primary keys and non-null store ownership.
- The exact global `unique_tombstone` guard remains present.
- The Tombstone Change Log trigger is enabled and points to `trg_log_change()`.
- A real owner soft-delete creates one Tombstone, emits the Tombstone event before the target UPDATE, and remains idempotent on replay.
- A user from another store cannot tombstone the target.
- Seller Pull receives the canonical DELETE envelope with original record identity and distinct Tombstone ID, then ACKs its delivery.
- A duplicate global Tombstone identity is rejected.

**CI evidence**
- SQL migration smoke test: [run 46132378503](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/46132378503) — completed / success on commit `c2afdde5e9de1f0ad096a51437fa6be30512771e`.
- Job `140940153112`: R1, R2, R3 and R4 migrations and regression steps all completed / success.
- R4 regression confirms target UUID primary keys, Tombstone uniqueness and trigger catalog coverage; idempotent soft delete; Tombstone-before-target-UPDATE order; cross-store rejection; canonical DELETE envelope; and retained global uniqueness guard.
- This is isolated PostgreSQL 16 CI evidence, not staging/production acceptance.

No physical purge, restore, local/staging/production SQL or merge to `main` is included.


### 19.15 D3.2 / R5 — Tombstone status is not global device progress

**Status:** Implemented on `repair/verified-fixes`; disposable PostgreSQL CI validation is pending. No persistent database has been modified.

#### A. Repository-wide reference audit

Reviewed the base schema, sync Pull/Push hardening, RBAC, user/device security, business RPCs, conflict design, sync design, and relevant sync/soft-delete regression tests for `tombstones.sync_status` and `tombstones.synced_at`.

Findings:
- The base Tombstone schema defines `sync_status DEFAULT 'PENDING'` and nullable `synced_at`.
- `soft_delete_record` relies on the default pending state when creating a Tombstone.
- Existing regression coverage asserts a new Tombstone is PENDING.
- No authenticated Pull/ACK implementation updates these Tombstone fields. The `synced_at` updates found in sync Push apply to `sync_outbox`, not Tombstones.
- The only active meaning that can safely be retained is legacy compatibility metadata; it is not proof that all devices received a delete.

#### B. Implementation

Added `docs/PHASE3_REPAIR_009_TOMBSTONE_SYNC_STATE_SEMANTICS.sql`. It intentionally makes no destructive schema change:
- Documents `tombstones.sync_status` as legacy/non-authoritative and prohibits interpreting a single-device ACK as global SYNCED state.
- Documents `tombstones.synced_at` as legacy and not maintained by the delivery-bound ACK contract.
- Documents `sync_delivery_pages.acknowledged_at` as per-page/per-device delivery progress, not proof of local client commit.
- Retains both Tombstone columns and their existing defaults/constraints for compatibility.

Authoritative progress remains per device and table in `sync_cursors`, with page-level ACK evidence in `sync_delivery_pages`.

#### C. Regression and CI

Added `tests/phase3-tombstone-device-progress-regression.sql` and CI steps after R4. It creates two devices for one seller, issues one Tombstone, ACKs it from device A, verifies device B remains behind and the global Tombstone fields remain PENDING/NULL, then ACKs from device B and verifies both independent checkpoints and page ACK records while the legacy fields remain unchanged.

**CI evidence:** pending the workflow run for the implementation commit. No test is reported as passed until the workflow completes successfully and its logs are inspected.

No status fields were removed or rewritten, no persistent DB was touched, and no merge to `main` was performed.


### 19.16 D3.2 / R6 — pagination boundaries, ordering and concurrent writes

**Status:** Implemented/test coverage added on `repair/verified-fixes`; final disposable PostgreSQL CI validation is pending.

#### A. Pagination contract

R3 introduced fixed 500-visible-event pages, a server-managed per-device/table cursor, `has_more`, delivery IDs and sequential ACK. R6 preserves per-table Pull; it does not introduce a Global Stream. The client requests the next page only after the previous page has been applied locally and ACKed. Internal cursor numbers are not client-controlled or returned.

The R3 page function serializes each device/table stream using a row lock on `sync_cursors`. Pull and ACK use the same lock order (device credential, sync cursor, delivery page) to avoid out-of-order advancement and lock inversion. A page is computed from one statement snapshot; writes committed after that snapshot remain beyond the acknowledged page boundary and are returned on a subsequent Pull.

#### B. Visibility and ordering

- `has_more` counts only events visible to the caller.
- If no events are visible, the server advances the checkpoint across the invisible range internally and returns an empty response with no delivery ID or hidden-event metadata.
- If the page contains up to 500 visible events, the server may checkpoint trailing invisible events after the last visible event because every visible event in that snapshot is included.
- If a 501st visible event exists, the page boundary stops at the 500th visible event; the next page starts after its ACK.
- Per-table streams remain independent. Tombstone is the canonical delete signal, so a client must reconcile it against stale UPDATEs arriving from another table stream rather than depending on cross-table cursor order.

#### C. Regression and CI

Added:
- `tests/phase3-sync-pagination-boundary-regression.sql` for exact 499, 500 and 501 visible-event boundaries.
- `tests/phase3-sync-page-concurrency.sh` for two independent database sessions: one issues and holds page 1, another commits a later Change Log event, the first ACKs, and the next Pull must return the concurrent event without a gap.

The existing R3 1,201-event regression continues to cover 500/500/201 pagination, replay, idempotent ACK and no duplicates.

**CI evidence:** pending the workflow run containing the R5/R6 tests. No test is reported as passed until the workflow completes successfully and its logs are inspected.

No Global Stream migration, client implementation, persistent DB execution or `main` merge is included.
