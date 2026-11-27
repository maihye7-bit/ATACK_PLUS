# Phase 1 Repair 001 — Same-Store Integrity (Part A)

**Branch:** `repair/verified-fixes`  
**Date:** 2026-11-27  
**Status:** Part A implemented and CI-verified; Stage 1 / Gate G1 remains open.

## Changes

- Hardened `public.validate_same_store_references()` with `FOR SHARE` locks for referenced parent rows.
- Enforced the stock movement reference contract:
  - `invoice` → `invoices`
  - `purchase` → `purchases`
  - `adjustment` → `stock_adjustments`
  - `return` → exactly one row across `sales_returns` and `purchase_returns`
- Rejected half-populated reference pairs (only type or only ID).
- Added parent-side store reassignment guards for products, users, invoices, purchases, sales returns, purchase returns, stock adjustments, customers and suppliers when dependent business history exists.
- Added regression fixtures for valid same-store references, cross-store references, mismatched reference types, incomplete NULL pairs, and parent ownership reassignment.
- Added two-session concurrency checks for both parent-first and child-first lock ordering.

## Verification

- SQL migration/full regression: [GitHub Actions 45990947758](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/45990947758) — **PASS**
- Auth smoke: [GitHub Actions 45990947866](https://github.com/maihye7-bit/ATACK_PLUS/actions/runs/45990947866) — **PASS**
- Verified commit: `a105040926d2637fc735adc40fcb88a8a6af0d91`
- Tests ran against isolated CI PostgreSQL and Auth compatibility fixtures. No production/staging database was changed.

## Remaining before Gate G1

This is not full Stage 1 acceptance. The remaining Phase 3 extension relationships still require a complete parent/child matrix and targeted validation, particularly receiving records, return items, inventory batches, accounting references and synchronization records. Review existing constraints and triggers before adding any duplicate protections. Confirm legacy data compatibility and pre-migration violations before final acceptance.

No production migration has been executed and no merge to `main` has been performed.
