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
