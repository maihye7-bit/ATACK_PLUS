# ATACK PLUS — Phase 2 RPC Integration Guide

## Apply order

1. Create a disposable PostgreSQL 15+ / Supabase staging project.
2. Apply `POSTGRES_SCHEMA_PHASE1_FIXED.sql` to an empty database.
3. Apply `ATACK_PLUS_PHASE2_BUSINESS_RPCS.sql`.
4. Run the Phase 2 test matrix in `TEST_PLAN_PHASE2_UPDATED.md` before connecting Flutter.

Do not apply this migration to production before a full backup and staging validation.

## Supabase RPC calls

All UUIDs must be generated once and persisted in the local SQLite outbox. Reuse the same `operation_id`, entity `id`, and exact payload for every retry. Do not generate new UUIDs on retry.

### 1. Sale

RPC: `process_sale_invoice`

Arguments:
- `p_store_id`: store UUID associated with the authenticated user.
- `p_operation_id`: stable UUID for this business operation.
- `p_payload`: example:

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "invoice_number": "INV-000001",
  "customer_id": "22222222-2222-4222-8222-222222222222",
  "invoice_date": "2026-11-22T10:00:00Z",
  "location_id": "main",
  "paid_amount": 100.0000,
  "payment_method": "CASH",
  "items": [
    {
      "id": "33333333-3333-4333-8333-333333333333",
      "product_id": "44444444-4444-4444-8444-444444444444",
      "quantity": 2,
      "unit_id": "carton",
      "unit_price": 75.0000,
      "discount_amount": 0,
      "tax_rate": 0
    }
  ]
}
```

A credit balance requires `customer_id`. A sale without a customer must be fully paid in this RPC version. Quantity is converted to the product's primary unit on the server. If available stock is insufficient, the entire transaction rolls back.

### 2. Purchase

RPC: `process_purchase`

Payload fields: `id`, `purchase_number`, `supplier_id`, optional `purchase_date`, `location_id`, `paid_amount`, `payment_method`, `notes`, and non-empty `items[]`. Each item requires `product_id`, `quantity`, `unit_id`, and `unit_price`; `cost_per_unit`, `tax_rate`, batch and expiry are optional.

The server calculates totals, receives the quantities into stock, writes movements and supplier ledger entries, and records an optional supplier payment atomically.

### 3. Customer payment

RPC: `process_customer_payment`

Payload fields: `id`, `customer_id`, `amount`, `payment_method`, optional `reference_no`, `notes`, and optional `allocations[]` (`invoice_id`, `amount`). Explicit allocations are applied first; any remainder is allocated FIFO to the customer's oldest outstanding sale invoices. If the whole payment cannot be allocated, the transaction is rejected. Payments larger than current debt are rejected in this version.

### 4. Supplier payment

RPC: `process_supplier_payment`

Payload fields: `id`, `supplier_id`, `amount`, `payment_method`, optional `reference_no`, and `notes`. The payment must not exceed current supplier debt.

## Idempotency response

- First successful execution returns `success=true` and `replayed=false`.
- Exact retry returns `success=true` and `replayed=true` without duplicating business rows or movements.
- Reusing an operation UUID with a different payload or a different RPC name is rejected.

## Important constraints

- The RPCs require a Supabase-authenticated user with membership in the supplied store and the matching RBAC permission.
- Never put the Supabase `service_role` key in Android, Windows, or any client application.
- Do not call direct INSERT/UPDATE on invoices, purchases, payments, ledgers, stock or stock movements from Flutter.
- This release does not yet implement sales returns, purchase returns, expenses/revenues, stock transfers, partial GRN receiving, or offline stock reservation between devices.
- Audit logging for all business RPCs remains a production-readiness task.
- PostgreSQL execution and concurrency tests are still required; static review is not runtime validation.
