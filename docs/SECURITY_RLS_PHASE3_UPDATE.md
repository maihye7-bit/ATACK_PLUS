# ATACK PLUS — Security and RLS (Phase 3, verified role model)

## 1. Identity and store boundary

- Supabase Auth is the source of identity. PostgreSQL resolves the application user through `users.auth_user_id = auth.uid()`.
- `current_user_store_id()` resolves the active user's store. A client-supplied `store_id` is never proof of membership.
- Store isolation is enforced by RLS; sensitive RPCs additionally validate membership and the permission required for the operation.
- The business model is one store owner/Super Admin plus individual sellers. The database role key `cashier` is the technical role currently assigned to a seller; it does not introduce a separate cashier job into the business model.

## 2. Effective seeded role permissions

The following reflects the executable Phase 1 seed plus the Phase 3 permission migrations, not a proposed future matrix.

| Database role | Effective permissions and boundaries |
|---|---|
| `owner` | All catalogued permissions, including `users.manage`, `settings.write`, `audit.read`, `purchases.return`, `inventory.adjust`, and `inventory.allow_negative`. Store-wide visibility over sellers' sales and financial records. |
| `admin` | All Phase 1 permissions except `settings.write`; receives the Phase 3 privileged purchase and inventory permissions. Does **not** receive `audit.read`. Cannot grant a role containing permissions the admin does not hold, including the full `owner` role. |
| `accountant` | `reports.financial`, `reports.inventory`, `customers.read`, `suppliers.read`, `customers.payments`, `suppliers.payments`, `sales.read`, `purchases.read`. No sales/purchase creation, purchase returns, inventory adjustment, user management, or audit access. |
| `cashier` (seller) | `products.read`, `inventory.read`, `sales.read`, `sales.write`, `sales.void`, `customers.read`, `customers.write`, `customers.payments`, `reports.inventory`. Sales invoices, returns, customer payment activity and allocations are restricted to the authenticated seller's own activity; the owner can see all sellers' activity. No purchase, supplier-payment, inventory-write/adjustment, financial-report, user-management, or audit privileges. |
| `stock_keeper` | `products.read`, `products.write`, `inventory.read`, `inventory.write`, `purchases.read`, `purchases.write`, `purchases.receive`, `suppliers.read`, `reports.inventory`. Does not receive the separately privileged `inventory.adjust`, `purchases.return`, `users.manage`, or `audit.read` permissions by default. |

### Important distinctions

- `inventory.write` is not interchangeable with `inventory.adjust`. The stock-adjustment RPC requires `inventory.adjust`, granted by the current migration to `owner` and `admin`.
- `purchases.return` and the special purchase lifecycle permissions (`purchases.close_remaining`, `purchases.receive_excess`, `purchases.receive_substitute`, `purchases.edit_after_receipt`) are granted to `owner` and `admin`.
- `audit.read` is reserved for `owner`.
- Sellers can read the stock/product information and inventory reports explicitly granted to the `cashier` role for sales work, but cannot write or adjust stock. Their sales and customer-payment visibility remains seller-scoped.
- `reports.view`, `accounting.view`, and `accounting.create` are not the permission codes used by the current SQL implementation. Do not add them to application checks or documentation as if they were active permissions. The current codes are `reports.inventory`, `reports.financial`, and the specific business-operation permissions above.

## 3. RPC authorization contract

| Operation | Required permission | Current role boundary |
|---|---|---|
| Create sale / process sale return | `sales.write` | Owner, admin, seller (`cashier`) |
| Create purchase / receive purchase | `purchases.write` / `purchases.receive` | Owner, admin, stock keeper (according to each permission) |
| Purchase return | `purchases.return` | Owner, admin |
| Customer payment | `customers.payments` | Owner, admin, accountant, seller; seller allocations are limited to the seller's own invoices |
| Supplier payment | `suppliers.payments` | Owner, admin, accountant |
| Stock adjustment | `inventory.adjust` | Owner, admin |
| Negative inventory exception | `inventory.allow_negative` | Owner, admin; must pass the RPC's reason and audit requirements |
| Inventory expiry / low-stock reports | `reports.inventory` | Roles granted that permission; seller report access is read-only |
| Financial reports and accounting reads | `reports.financial` | Owner, admin, accountant |
| User/profile/role management | `users.manage` | Owner, admin, with role-permission coverage enforced by the management RPC |
| Audit trail read | `audit.read` | Owner only |
| Sync administration | `sync.manage` | Owner, admin |

All exposed business RPCs must derive the actor from `auth.uid()`, verify active membership in the requested store, check the exact permission, and preserve transaction/idempotency invariants. Direct authenticated writes to financial, inventory-derived, identity, audit and sync-state tables remain denied where the operation is RPC-only. `service_role` is server-side only and must never be embedded in a client application.

## 4. Seller-specific data visibility

- The seller may read only invoices created by that seller, their invoice lines, returns attached to those invoices, and their own customer payment/ledger/allocation records.
- A seller cannot allocate a customer payment to another seller's invoice.
- The owner can read all sellers' invoices, related returns, customer payment records, allocations, users, inventory and accounting data within the owner's store.
- A user from another store cannot read or mutate this store's records.
- The seller cannot view the device inventory or user-role assignments without the corresponding management permission.

## 5. Role and account administration

- Direct writes to `users` and `user_roles` are revoked from authenticated clients. Use the controlled profile and role-management RPCs.
- A caller may grant/revoke only roles whose complete permission set is contained in the caller's own effective permissions. This prevents an admin from granting the owner role.
- A user cannot be left without a role through the role-management RPC. Cross-store and inactive targets are rejected.
- User provisioning requires an existing Supabase Auth identity; passwords and credentials remain in Supabase Auth, not the application `users` table.
- Deactivation and role changes are audited; the last active owner cannot be deactivated.

## 6. RLS, grants, function hardening and audit

- RLS must be enabled on every public business/operational table.
- Read policies combine store isolation with the role permission matrix; seller-owned sales and customer payment data add creator-level filtering.
- Direct writes to protected/derived tables are denied to authenticated clients and performed through controlled RPCs.
- SECURITY DEFINER functions use a fixed `search_path`; implicit PUBLIC/anon execution is revoked. Explicit authenticated/service-role grants must be limited to intended entry points.
- Audit logs are append-only and visible only to users with `audit.read`. Business/admin mutations are recorded without authentication secrets or tokens.
- Audit coverage is supplemented by explicit domain events for operations whose complete business context cannot be represented by a generic row trigger.

## 7. Automated verification

The current CI suite includes:
- Real Supabase Auth owner/seller JWT tests for store isolation, seller-owned invoice/payment boundaries, privileged RPC denials, owner role management, and direct financial-write denial.
- Catalog-level RLS and SECURITY DEFINER privilege checks.
- Role-management, user-account and device-visibility regressions.
- Role-based SELECT visibility tests for business, financial, inventory and synchronization tables.
- Audit append-only, attribution and event-coverage regressions.

The role-matrix regression additionally verifies the effective permissions for owner, admin, accountant, seller (`cashier`) and stock keeper, and verifies that an admin cannot grant the full owner role.

These CI checks run against isolated PostgreSQL/Supabase test environments. They are not evidence of production deployment or staging acceptance.
