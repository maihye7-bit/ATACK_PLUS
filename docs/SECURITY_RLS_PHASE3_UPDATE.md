# ATACK PLUS — Security and RLS (Phase 3, owner/seller model)

## 1. Identity and store boundary

- Supabase Auth is the identity source. PostgreSQL resolves the application user through `users.auth_user_id = auth.uid()`.
- `current_user_store_id()` resolves the active user's store. A client-supplied `store_id` is never proof of membership.
- Store isolation is enforced by RLS; sensitive RPCs additionally validate membership and the permission required for the operation.
- The business model has one store owner/Super Admin and individual sellers. There are no separate cashier, accountant, stock-keeper or delegated-admin business jobs.

## 2. Active database roles

| Business identity | Database key | State and boundary |
|---|---|---|
| Owner / Super Admin | `owner` | Active. Full authority within the store, including seller/user management, catalog, purchases, inventory, finance, settings, audit and synchronization. |
| Seller | `cashier` | Active technical compatibility key only; the role is displayed/described as **بائع**. Can perform sales, customer collection and permitted sales-return operations, read the product/stock data needed for selling, and access only their own invoices and related activity. |

Older Phase 1 revisions seeded `admin`, `accountant` and `stock_keeper`; the corrected canonical PostgreSQL and SQLite bootstrap schemas now seed only `owner` and `cashier`. Those older keys are legacy implementation roles, not approved business roles. The forward migration `ATACK_PLUS_PHASE3_OWNER_SELLER_ROLE_CONSOLIDATION.sql` retains their role rows to preserve foreign-key/history safety, marks them inactive, removes their permission grants and updates `has_store_permission` to ignore inactive roles.

The PostgreSQL migration deliberately stops if any **active** user still has one of those legacy role assignments. Such accounts require explicit review and remapping before the migration is retried. It does not silently promote anyone to owner or seller. Inactive historical user-role rows may remain for traceability; the legacy role rows are not assignable through the controlled role/profile RPCs. The SQLite bootstrap schema is aligned to the same two active keys, and `SQLITE_MIGRATION_OWNER_SELLER_ROLES.sql` provides a guarded offline-database upgrade that retains historical assignments for inactive users.

## 3. Effective permission boundaries

- **Owner:** all permissions in the catalog, including `users.manage`, `settings.write`, `audit.read`, `purchases.write`, `purchases.return`, `inventory.adjust`, `inventory.allow_negative`, `reports.financial` and `sync.manage`.
- **Seller (`cashier` key):** `products.read`, `inventory.read`, `sales.read`, `sales.write`, `sales.void`, `customers.read`, `customers.write`, `customers.payments` and `reports.inventory`. The seller cannot manage users/roles, purchases, suppliers, stock writes/adjustments, financial reports, audit records or sync administration.
- `inventory.write` is distinct from `inventory.adjust`; neither is granted to sellers.
- Purchase lifecycle privileges, supplier payments, financial reporting, audit reads and store administration are owner-only under the approved two-role model.

## 4. RPC authorization and seller ownership

- Sales and sales returns require `sales.write`. A seller may act only on invoices attributed to that seller; the owner may act across the store.
- Customer payments require `customers.payments`. Seller payment allocation is restricted to that seller's own invoices; the owner can manage store-wide customer payment activity.
- Purchase creation/receiving/returns, supplier payments, stock adjustment, negative-stock exceptions, financial reports, user/profile/role management, audit reads and sync administration are owner-only.
- All exposed business RPCs must derive the actor from `auth.uid()`, verify active membership in the requested store, check the exact permission, and preserve transaction/idempotency invariants.
- Direct authenticated writes to financial, inventory-derived, identity, audit and sync-state tables remain denied where the operation is RPC-only. `service_role` is server-side only and must never be embedded in a client application.

## 5. Data visibility

- A seller may read only invoices created by that seller, their invoice lines, returns attached to those invoices, and their own customer payment/ledger/allocation records.
- A seller cannot allocate a customer payment to another seller's invoice.
- The owner can read and manage all sellers' invoices, related returns, customer payment records, allocations, users, inventory, purchases and accounting data within the owner's store.
- A user from another store cannot read or mutate this store's records.
- Seller product and stock visibility is read-only and limited to information required for sales.

## 6. Role and account administration

- Direct writes to `users` and `user_roles` are revoked from authenticated clients. Use the controlled profile and role-management RPCs.
- Only the owner has `users.manage`; sellers cannot create users, assign roles, alter their own permissions or escalate to owner.
- The role-management RPC rejects inactive legacy role keys and prevents cross-store assignments.
- User provisioning requires an existing Supabase Auth identity; passwords and credentials remain in Supabase Auth, not the application `users` table.
- Deactivation and role changes are audited; the last active owner cannot be deactivated.
- Existing legacy-role accounts are not automatically reassigned. The consolidation migration preflights active assignments and requires explicit remediation.

## 7. RLS, grants, function hardening and audit

- RLS must be enabled on every public business/operational table.
- Read policies combine store isolation with the owner/seller permission model; seller-owned sales and customer payment data add creator-level filtering.
- Direct writes to protected/derived tables are denied to authenticated clients and performed through controlled RPCs.
- SECURITY DEFINER functions use a fixed `search_path`; implicit PUBLIC/anon execution is revoked. Explicit authenticated/service-role grants must be limited to intended entry points.
- Audit logs are append-only and visible only to users with `audit.read`, which is owner-only. Business/admin mutations are recorded without authentication secrets or tokens.

## 8. Automated verification

The CI suite covers:
- Real Supabase Auth owner/seller JWT tests for store isolation, seller-owned invoice/payment boundaries, privileged RPC denials, owner role management and direct financial-write denial.
- Catalog-level RLS and SECURITY DEFINER privilege checks.
- Role-management, user-account and device-visibility regressions.
- Role-based SELECT visibility tests for business, financial, inventory and synchronization tables.
- Owner/seller role consolidation, seller permission boundaries and rejection of inactive legacy role assignment.
- Audit append-only, attribution and event-coverage regressions.

These checks run against isolated PostgreSQL/Supabase test environments. They are not evidence of production deployment or staging acceptance.
