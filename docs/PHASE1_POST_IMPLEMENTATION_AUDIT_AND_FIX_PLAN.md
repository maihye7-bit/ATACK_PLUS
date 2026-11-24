# ATACK PLUS

# Phase 1 --- Post-Implementation Audit & Fix Plan

**Document status:** Draft for review and approval\
**Scope:** PostgreSQL Phase 1 schema, security/RLS, change logging,
synchronization support structures and functions\
**Environment reviewed:** Local PostgreSQL 16.15 on Ubuntu 24.04 / WSL2\
**Database:** `atack_plus_test`\
**Important limitation:** This audit was performed against the local
database and local authentication shim. It is not evidence of a
production Supabase deployment or a completed multi-device
synchronization test.

------------------------------------------------------------------------

## 1. Purpose

This document consolidates the post-implementation findings from the
Phase 1 database audit. Its purpose is to distinguish:

1.  Implemented structures that passed the checks performed.
2.  Confirmed defects or design conflicts.
3.  Risks that require a targeted test before a final conclusion.
4.  Proposed fixes and their dependencies.
5.  Acceptance tests required before Phase 1 can be considered ready for
    integration.

**No database or project-file changes are authorized by this document.**
All changes require a separate reviewed implementation plan and explicit
approval.

## 2. Environment and execution status

### 2.1 Confirmed environment

-   Windows 10 Enterprise LTSC 2021 with Ubuntu 24.04 LTS under WSL2.
-   PostgreSQL 16.15 installed and running locally.
-   Database `atack_plus_test`, UTF-8.
-   Local Supabase Auth shim roles/functions are present. This is not
    real Supabase Auth and does not prove JWT verification or production
    authorization behavior.

### 2.2 Phase 1 schema execution

The file `POSTGRES_SCHEMA_PHASE1_FIXED.sql` was executed against the
local database using a single transaction and `ON_ERROR_STOP=1`.

-   Execution exit code: `0`.
-   The previously identified missing uniqueness on `permissions.code`
    was corrected by adding `UNIQUE`.
-   Earlier audit counts: 39 tables, 1 sequence, 69 functions, 50
    triggers and 251 policies.
-   RLS was enabled on all 39 tables.
-   No unvalidated constraints or duplicate permission codes were found
    in the checks recorded.

This confirms successful local schema execution. It does **not**
establish that every business requirement is implemented, that every
policy is correct, or that the schema is production-ready.

## 3. Executive summary

### 3.1 Overall assessment

Phase 1 is implemented and executes locally, but the post-implementation
audit identified issues requiring a controlled repair phase. The most
important areas are:

-   Inventory policy conflict: negative stock is allowed by business
    decision D-016 only with a dedicated permission, while the current
    `stock.quantity` constraint rejects negative quantities.
-   Multi-warehouse model: the current `locations` table is a fixed
    shared lookup (`main`, `warehouse`, `storage`) and does not
    represent arbitrary store-owned warehouses required by D-020.
-   Soft deletion: the existing `soft_delete_record` function only
    inserts a tombstone and does not perform a complete, validated
    soft-delete operation.
-   Synchronization: cursor allocation is atomic in structure, but
    device revocation, cursor advancement rules, acknowledgement
    semantics and conflict resolution need hardening.
-   Conflict resolution: the generic row update in
    `resolve_sync_conflict` has an insufficient field allowlist and does
    not include `store_id` in the final UPDATE predicate.
-   Referential integrity: several relationships are not protected by
    composite same-store foreign keys or equivalent complete validation.
-   Testing: concurrency, cross-store, cascade-delete, synchronization
    replay and real client behavior have not yet been demonstrated.

### 3.2 Severity categories

-   **Critical:** Must be fixed before the affected capability is
    enabled.
-   **High:** Must be fixed before Phase 1 is accepted for integration.
-   **Medium:** Must be resolved or explicitly deferred with a
    documented limitation.
-   **Verification:** The code suggests a risk, but a targeted test is
    required before classifying it as a defect.

## 4. Confirmed findings

### F-01 --- Negative inventory policy conflicts with the schema

**Severity:** High\
**Evidence:** `stock.quantity` has a `CHECK (quantity >= 0)` constraint.
Business decision D-016 permits negative inventory only when the user
has the separate `inventory.allow_negative` permission, with warning and
audit details. The Phase 2 sale RPC was also observed to reject
shortages.

**Impact:** The approved negative-stock exception cannot work while the
database constraint rejects negative values. A permission check in an
RPC cannot override a table CHECK constraint.

**Proposed resolution:** 1. Decide the exact representation of negative
available quantity and reserved quantity. 2. Reconcile the `stock`
constraints with D-016. 3. Ensure only a trusted RPC can create an
allowed negative balance. 4. Record user, device, reason, requested
quantity and shortage. 5. Preserve conflict detection during offline
synchronization; never silently overwrite stock.

**Dependencies:** Inventory RPCs, stock movement model, conflict
resolution and offline synchronization design.

### F-02 --- Locations model does not meet the multi-warehouse decision

**Severity:** High\
**Evidence:** `locations` contains only `id`, `name` and `is_default`,
with a CHECK restricting IDs to `main`, `warehouse` and `storage`. It
has no `store_id`. `stock` has no `store_id` and is isolated through its
product relationship.

**Impact:** This represents a small fixed global set, not arbitrary
store-owned warehouses. It cannot fully support D-020's multiple
independently managed warehouses and their lifecycle.

**Proposed resolution:** 1. Define a store-owned warehouse/location
entity with UUID and `store_id`. 2. Add same-store integrity for stock
and movement references. 3. Define whether the existing `locations`
table remains a static lookup or is replaced. 4. Preserve transfer
states and the rule that destination stock becomes available only on
receipt. 5. Plan a safe data migration from fixed IDs.

**Dependencies:** Stock, stock movements, transfers, inventory counts,
RLS, sync and reporting.

### F-03 --- Soft-delete function is incomplete and inaccessible to application roles

**Severity:** High\
**Evidence:**
`soft_delete_record(p_table_name, p_record_uuid, p_store_id, p_deleted_by)`
only inserts a row into `tombstones`. It does not update the target
record's `deleted_at` or `is_active`, and it does not validate the table
name, target record/store or deleter membership. It is not
`SECURITY DEFINER`, has no fixed `search_path`, and its recorded ACL
grants EXECUTE only to `postgres`.

**Impact:** It is not a complete soft-delete API. The application roles
cannot call it, and tombstone creation alone can leave the original
record active.

**Proposed resolution:** 1. Replace the generic unvalidated operation
with a controlled, table-allowlisted implementation or table-specific
functions. 2. Derive the store and actor from trusted authenticated
context wherever possible; do not trust caller-supplied identity fields.
3. Validate record ownership and deletion eligibility. 4. Atomically
update the record's deletion state and insert the tombstone. 5. Ensure
idempotency and audit logging. 6. Prevent physical deletion of business
records except through explicitly authorized retention/maintenance
procedures.

**Dependencies:** RLS, sync tombstones, product/customer/supplier
lifecycle, foreign keys and audit logging.

### F-04 --- Product deletion behavior is not a safe deletion policy

**Severity:** High\
**Evidence:** Product references include `ON DELETE CASCADE` for
`product_units`, `purchase_items` and `stock`, while other references
may block deletion through NO ACTION. `products` has `is_active` and
`deleted_at`, but the existing generic soft-delete function does not
update them. Product DELETE RLS policy exists and is permission-based.

**Impact:** Physical deletion may cascade into historical or operational
records in some circumstances. Relying on unrelated NO ACTION references
to block deletion is not a reliable policy.

**Proposed resolution:** 1. Make normal application deletion a
soft-delete/deactivation operation. 2. Remove or revise destructive
cascades from historical business data where they are not explicitly
required. 3. Define retention and exceptional hard-delete rules. 4. Test
deletion for products with stock, purchase history, invoice history,
returns and movements.

### F-05 --- Generic conflict resolution has an unsafe update boundary

**Severity:** Critical for the conflict-resolution capability\
**Evidence:** `resolve_sync_conflict` validates conflict-store
membership and checks `sync.manage`, but constructs a generic update
from JSON fields, excluding only `id`, `created_at`, `store_id` and
generated fields. Its final UPDATE predicate is `WHERE t.id=$2`, without
a `store_id` predicate. `MERGE` falls back to the local JSON when
`p_merged_json` is null. The function updates an existing row and does
not provide a general INSERT/DELETE resolution path.

**Impact:** - Fields not intended for conflict editing may be
modified. - The final update is not explicitly constrained by store. - A
concurrent ownership/target change is not guarded by a target-row lock
in the shown function. - MERGE can silently mean "accept local" when no
merged payload is supplied. - The function's behavior does not cover all
possible conflict operation types.

**Proposed resolution:** 1. Replace the broad implicit field selection
with per-table and per-field allowlists. 2. Reject immutable, identity,
ownership, audit, deletion and derived fields unless a table-specific
rule explicitly permits them. 3. Lock and validate the target row within
the same transaction. 4. Include both record ID and store ID in the
final update predicate. 5. Require a non-null, validated merge payload
for MERGE. 6. Define separate safe behavior for UPDATE, INSERT and
DELETE conflicts. 7. Keep financial and inventory records event-derived;
resolve them through business operations, not generic row overwrite. 8.
Record old/new values, actor, reason and resolution result in the audit
trail. 9. Ensure resolution is idempotent and cannot be applied twice.

### F-06 --- Device records have no explicit revocation/active state

**Severity:** High\
**Evidence:** `devices` has `id`, `store_id`, `device_name`,
`device_type`, `last_seen`, `is_online`, `app_version`, `created_at`; no
`is_active`, `revoked_at` or equivalent field. `get_unsynced_records`
and `acknowledge_sync_cursor` verify only that a matching device row
exists in the store.

**Impact:** The inspected synchronization functions do not distinguish
an approved device from a revoked device. `is_online` is not an
authorization/revocation flag.

**Proposed resolution:** 1. Add an explicit device lifecycle state or
revocation timestamp. 2. Define who can register, approve, revoke and
reactivate devices. 3. Check device state in every pull, acknowledgement
and push/sync entry point. 4. Define behavior for locally cached
sessions after revocation. 5. Audit device lifecycle changes.

### F-07 --- Sync cursor table has weak data-integrity constraints

**Severity:** Medium\
**Evidence:** `sync_cursors` has a unique key
`(store_id, device_id, table_name)`, but `device_id` is TEXT and is not
a foreign key to `devices.id`. `last_pull_seq` has no observed
non-negative CHECK constraint. `cursor_value` is TEXT while
`last_pull_seq` is BIGINT.

**Impact:** Invalid negative cursor values are not prevented at the
table level; device references can become stale or mismatched; duplicate
representations can diverge.

**Proposed resolution:** 1. Choose one canonical numeric cursor field.
2. Remove the redundant text representation or define and enforce a
strict compatibility rule. 3. Add `CHECK (last_pull_seq >= 0)`. 4.
Prefer a UUID device reference and a composite same-store foreign key to
`devices(id, store_id)`, if compatible with the final device identity
design. 5. Define cursor initialization, reset and device-replacement
behavior.

### F-08 --- Static locations and stock ownership need a unified same-store integrity strategy

**Severity:** High\
**Evidence:** `stock` has no `store_id`; it is scoped through
`products.store_id`. Several foreign keys in operational tables are
ordinary single-column references. A validation trigger covers selected
relationships but does not cover all relevant stock/location references.

**Impact:** Same-store correctness depends on a partial collection of
triggers and indirect relationships. Some cross-store or inconsistent
references may not be prevented at the database constraint level.

**Proposed resolution:** 1. Build a complete relationship matrix for
every table containing a business foreign key. 2. Prefer composite
`(referenced_id, store_id)` foreign keys where feasible. 3. Where
composite constraints are impossible, use carefully designed validation
triggers with concurrency-safe locking. 4. Include stock, locations,
stock movements, payment allocations, ledgers and device/sync
references. 5. Test cross-store insert and update attempts for every
relationship.

### F-09 --- Tombstone uniqueness is global rather than store-scoped

**Severity:** Verification\
**Evidence:** `tombstones` has `UNIQUE(table_name, record_uuid)`, not
`(store_id, table_name, record_uuid)`.

**Impact:** This is safe only if record UUIDs are guaranteed globally
unique and a record can never legitimately be represented under more
than one store. The current schema uses UUIDs, but the intended identity
invariant should be explicit.

**Proposed resolution:** Confirm and document global UUID identity.
Otherwise change uniqueness to include `store_id`, and update all sync
queries and indexes consistently.

### F-10 --- Change-log cascade deletion may omit child DELETE events

**Severity:** Verification\
**Evidence:** `trg_log_change` returns OLD without logging when it
cannot resolve a store for a DELETE. Its comment assumes this is a
cascaded child delete after its parent has disappeared and that the
parent DELETE is logged.

**Impact:** If a client synchronizes child tables independently,
omitting child deletion events may leave orphaned local records unless
parent deletion and local cascade behavior are guaranteed consistently.

**Proposed resolution:** 1. Define whether child tables are
independently synchronized. 2. Test actual trigger order for parent
deletion and cascaded child deletion. 3. Ensure the parent deletion
contains enough information for deterministic local cascade behavior. 4.
If child events are required, resolve the store before the parent
disappears or capture it through a safe mechanism. 5. Test nested
cascades and offline replay.

## 5. Synchronization function review

### 5.1 `get_next_change_cursor`

**Observed behavior:** Inserts a counter row if absent, then increments
`last_cursor` using UPDATE ... RETURNING.

**Assessment:** The row update is atomic and serializes increments for
the same store. The function is SECURITY DEFINER, owned by postgres,
uses a fixed search_path, and EXECUTE is restricted to postgres in the
inspected ACL.

**Remaining verification:** Confirm all callers are trusted and validate
store ownership before calling. Test concurrent transactions and
rollback behavior. A cursor allocated in a rolled-back transaction
should not appear as a committed change-log event.

### 5.2 `log_change` and `trg_log_change`

**Observed behavior:** Trigger function derives store ownership from the
row or parent relation and records INSERT/UPDATE/DELETE events.

**Assessment:** The trigger function is SECURITY DEFINER with fixed
search_path. The helper `log_change` is not SECURITY DEFINER and has
EXECUTE restricted to postgres in the inspected ACL; the trigger runs as
its owner and can invoke it.

**Remaining verification:** - Verify every trigger-bearing table can
resolve a store correctly. - Verify DELETE behavior for cascades. -
Verify table coverage against the actual synchronization table list. -
Verify change-log entries are committed atomically with the originating
business operation.

### 5.3 `get_unsynced_records`

**Observed behavior:** Validates non-negative `p_since_cursor`, store
membership and device existence; returns up to 500 rows for one table
with cursor greater than the supplied cursor, ascending by cursor.

**Risks:** - Device active/revoked status is not checked. - No
upper-bound validation of the supplied cursor is visible. - No
table-specific permission check is visible beyond store membership. -
The caller must persist only the last contiguous, successfully applied
cursor. - The client must handle paging without skipping events.

**Proposed resolution:** Define a server-enforced pull contract and
client checkpoint contract. Do not advance the durable cursor past an
event until all earlier events in the relevant stream have been applied
locally.

### 5.4 `acknowledge_sync_cursor`

**Observed behavior:** Validates non-negative cursor, store membership
and device existence; checks cursor against the maximum cursor for the
table; requires a positive cursor to identify an actual change for that
table; updates the per-device/per-table cursor using GREATEST.

**Risks:** - Device active/revoked state is not checked. - The server
verifies that the acknowledged cursor exists, but cannot prove that the
client applied every earlier event. - Because the global cursor is
allocated per store while acknowledgement is per table, gaps between
table-specific cursor values are expected. The client protocol must not
mistake gaps for missing events. - The stored `cursor_value` text
duplicates `last_pull_seq`.

**Proposed resolution:** Document whether acknowledgement means
"received", "applied locally", or "fully committed locally"; use one
precise meaning. Prefer "all events up to this cursor for this table
have been durably applied". Enforce monotonic advancement and validate
against the stream's actual delivered range.

### 5.5 `resolve_sync_conflict`

**Assessment:** The function has useful checks for store membership,
`sync.manage`, actor identity and financial/inventory exclusions.
However, its generic update logic is too permissive and needs the
corrections listed in F-05.

**Additional verification:** Confirm how conflict records are created,
which conflict types map to which table operations, whether local/remote
JSON snapshots are trustworthy, and whether conflict resolution itself
produces the correct change-log and audit events.

## 6. Other audit findings to retain in the Phase 1 repair plan

### 6.1 Same-store references

Composite unique constraints and composite foreign keys were added for
several key entities, including categories, brands, customers,
suppliers, invoices and users. A `validate_same_store_references()`
trigger function covers selected references.

However, many ordinary foreign keys remain single-column references. The
trigger coverage is partial. The repair plan must produce a full
table-by-table relationship matrix rather than assuming the existing
trigger covers every relationship.

### 6.2 RLS and grants

-   RLS was enabled on all 39 tables in the recorded audit.
-   `stock` denies direct authenticated INSERT/UPDATE/DELETE and is
    expected to be modified through privileged business RPCs.
-   `locations` is globally readable as a fixed lookup and is not
    store-owned.
-   `change_log` denies direct authenticated writes and allows
    store-scoped reads.
-   `store_sync_counters` denies direct authenticated writes and uses
    store isolation policies.
-   The local audit included a manual temporary SELECT grant on all 39
    tables for testing. This was local-only and is not a recommended
    production grant policy.
-   A complete least-privilege table, sequence and function EXECUTE
    grant review is still required before deployment.

### 6.3 Audit log

The current Phase 1 security documentation records that a complete
unified audit log is not yet finished. The repair plan must ensure
sensitive operations record actor, device, timestamp, action, entity,
before/after values, reason and outcome, without recording secrets or
passwords.

## 7. Repair workstreams and recommended order

The following order minimizes rework.

### Workstream A --- Data ownership and deletion foundations

1.  Create the complete same-store relationship matrix.
2.  Decide the final store-owned location/warehouse model.
3.  Define soft-delete and tombstone lifecycle.
4.  Review destructive foreign-key cascades.
5.  Confirm tombstone identity uniqueness.

**Why first:** Inventory, sync and conflict resolution depend on stable
ownership and deletion semantics.

### Workstream B --- Inventory and warehouse consistency

1.  Reconcile D-016 with stock constraints and sale RPC behavior.
2.  Implement the approved negative-stock permission path safely.
3.  Complete stock/location/movement same-store integrity.
4.  Align warehouse transfers, receipts, reservations and counts with
    D-020 and D-021.

**Why second:** Inventory is financially sensitive and must not be
generically overwritten during sync.

### Workstream C --- Device lifecycle and synchronization contract

1.  Add explicit device approval/revocation state.
2.  Bind sync cursor records to real devices and stores.
3.  Normalize cursor data types and constraints.
4.  Define pull paging and checkpoint rules.
5.  Define acknowledgement semantics and server validation.
6.  Verify all sync entry points check device state and store
    membership.
7.  Verify every synchronized table has a deterministic delete strategy.

**Why third:** The client cannot implement reliable synchronization
until the server contract is stable.

### Workstream D --- Conflict resolution

1.  Replace generic field updates with per-table allowlists.
2.  Lock and revalidate target rows.
3.  Include store scope in final mutations.
4.  Require explicit MERGE payloads.
5.  Define INSERT/UPDATE/DELETE conflict handling.
6.  Keep financial and stock resolution event-based.
7.  Add complete audit and idempotency behavior.

**Why fourth:** Conflict resolution depends on stable ownership,
deletion, inventory and sync semantics.

### Workstream E --- Security, grants and audit

1.  Review all RLS policies for permissive/restrictive composition.
2.  Review table, sequence and function grants.
3.  Review SECURITY DEFINER functions for fixed search_path and safe
    ownership.
4.  Ensure untrusted input cannot select arbitrary table/column
    identifiers.
5.  Complete audit coverage for sensitive operations.
6.  Verify device revocation and role changes take effect as designed.

### Workstream F --- Integration and acceptance testing

1.  Rebuild an empty test database from the reviewed SQL.
2.  Execute all migrations in a single controlled sequence.
3.  Test tenant isolation using at least two stores.
4.  Test role/permission denial and approval.
5.  Test two or more devices pulling and acknowledging changes.
6.  Test concurrent writes and cursor allocation.
7.  Test offline replay, duplicate delivery and idempotency.
8.  Test deletion and tombstone propagation.
9.  Test conflict resolution for INSERT, UPDATE and DELETE.
10. Test stock shortages, negative stock permission and cross-device
    inventory conflicts.
11. Run regression tests for purchases, sales, returns, payments and
    ledgers.
12. Repeat the suite against a real Supabase staging project with real
    Auth/JWT behavior before production deployment.

## 8. Acceptance criteria

Phase 1 should not be marked fully accepted until all applicable
criteria below pass:

  ---------------------------------------------------------------------------
  ID                      Acceptance criterion    Evidence required
  ----------------------- ----------------------- ---------------------------
  AC-01                   Schema builds cleanly   Complete migration log and
                          from an empty database  exit code 0

  AC-02                   All intended tables     RLS inventory and policy
                          have correct RLS        tests

  AC-03                   Cross-store references  Automated negative tests
                          are rejected            

  AC-04                   Unauthorized direct     Role-based SQL tests
                          writes are rejected     

  AC-05                   Device revocation       Pull/push/acknowledgement
                          blocks further sync     tests

  AC-06                   Concurrent cursor       Multi-session concurrency
                          allocation has no       test
                          duplicate committed     
                          cursor                  

  AC-07                   Pull paging does not    Multi-page replay test
                          skip or reorder         
                          committed events        

  AC-08                   Acknowledgement cannot  Client/server integration
                          advance beyond applied  test
                          events under the        
                          documented contract     

  AC-09                   Deletes propagate       Parent/child and tombstone
                          deterministically       tests

  AC-10                   Conflict resolution     Adversarial tests
                          cannot modify forbidden 
                          fields or another       
                          store's data            

  AC-11                   Financial and inventory Domain-specific tests
                          conflicts use business  
                          operations              

  AC-12                   Offline retries are     Duplicate replay tests
                          idempotent              

  AC-13                   Audit records are       Audit permission and
                          complete and            coverage tests
                          tamper-resistant to     
                          application roles       

  AC-14                   Real Supabase Auth and  Staging integration tests
                          RLS behavior matches    
                          local expectations      
  ---------------------------------------------------------------------------

## 9. Explicit non-claims and limitations

The following have **not** been proven by the checks summarized here:

-   Real Supabase deployment correctness.
-   Real JWT validation and `auth.uid()` behavior.
-   Successful synchronization between actual Android/Windows clients.
-   Correct behavior under all transaction interleavings.
-   Complete trigger coverage for every synchronized table.
-   Complete least-privilege production grants.
-   Full Phase 1 business acceptance against every D-001 to D-061
    decision.
-   Production backup/restore, printer, barcode or Flutter UI behavior.

These must remain open until supported by test evidence.

## 10. Approval boundary

This document is a review and planning artifact only.

**It does not authorize:** - Editing SQL files. - Running ALTER TABLE or
CREATE OR REPLACE FUNCTION. - Dropping or recreating constraints,
policies or tables. - Changing existing business data. - Applying
migrations to the local database or Supabase.

The next controlled step is to review this document, resolve any
disputed findings, and then prepare a separate implementation plan with
exact file names, SQL changes, migration order, rollback strategy and
tests. Implementation begins only after explicit approval.

------------------------------------------------------------------------

## Appendix A --- Relevant project decisions

This plan must remain aligned with the approved project decisions,
especially:

-   D-009: No Last Write Wins for money or inventory.
-   D-016: Negative inventory only with a dedicated permission, warning
    and audit.
-   D-017 / D-018: Controlled edits and cancellations of confirmed
    transactions.
-   D-020: Multiple warehouses within one store.
-   D-021: Inventory counts and auditable adjustments.
-   D-024: Backup and restore safeguards.
-   D-025: Individual user accounts and approved device management.
-   D-026: One store in the user interface, while retaining `store_id`
    for isolation.
-   D-045: Comprehensive audit log.
-   D-060 / D-061: Direct receiving and temporary supplier handling.

## Appendix B --- Key files referenced during the audit

-   `POSTGRES_SCHEMA_PHASE1_FIXED.sql`
-   `ATACK_PLUS_PHASE2_BUSINESS_RPCS.sql`
-   `ATACK_PLUS_PHASE3_RETURNS_INVENTORY_ACCOUNTING.sql`
-   `SECURITY_RLS_PHASE2_UPDATED.md`
-   `SECURITY_RLS_PHASE3_UPDATE.md`
-   `SYNC_DESIGN_PHASE2_UPDATED.md`
-   `SYNC_DESIGN_PHASE3_UPDATE.md`
-   `CONFLICT_RESOLUTION_PHASE2_UPDATED.md`
-   `CONFLICT_RESOLUTION_PHASE3_UPDATE.md`
-   `TEST_PLAN_PHASE2_UPDATED.md`
-   `TEST_PLAN_PHASE3_UPDATED.md`

*End of draft.*
