# ATACK PLUS --- خطة الاختبار

## 1. فئات الاختبارات

| الفئة | عدد الاختبارات | الهدف |
|--------|----------------|-------|
| وحدة (Unit) | 40+ | اختبار الدوال والـ Models |
| تكامل (Integration) | 25+ | اختبار SQLite + Sync |
| تامانة (E2E) | 15+ | سيناريوهات المستخدم النهائي |
| أمان (Security) | 10+ | اختبار RLS وAuthentication |
| مزامنة (Sync) | 20+ | سيناريوهات Device-to-Device |

---

## 2. اختبارات idempotency

### Test Case 1: إرسال الفاتلة نفسها ثلاث مرات

```
Precondition:
- Device A متصل بالإنترنت
- Product "Detergent" موجود بخزان 100 قطعة

Steps:
1. إنشاء فاتلة INV-001 للبيع 5 قطع
2. Save to SQLite
3. Outbox: INSERT INTO invoices
4. Sync to Supabase → SUCCESS
5. Sync again same invoice → EXPECTED: DUPLICATE
6. Sync third time → EXPECTED: DUPLICATE

Expected Result:
- الفاتلة محفوسة مرة واحدة فقط
- outbox تحتوي على حالة SYNCED
- processed_operations تحتوي على idempotency_key

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case 2: Idempotency مع محتوى مختلف

```
Precondition:
- operation_id = "abc-123" موجود في processed_operations

Steps:
1. إرسال operation_id = "abc-123" مع payload جديد
2. فحص processed_operations
3. مقارنة payload_hash

Expected Result:
- RETURN CONFLICT_DETECTED
- outbox.status = 'CONFLICT'
- error_message = "Payload mismatch for idempotency key"

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

---

## 3. اختبارات انقطاع الاتصال

### Test Case 3: انقطاع الاتصال بعد تنفيذ العملية على الخادم

```
Precondition:
- Device A قيد المزامنة
- تم إرسال 3 عمليات إلى Supabase
- Network cut occurs بعد op #2 وقبل ack #3

Steps:
1. Device A يبدأ Push لـ 3 عمليات
2. Op #1 SYNCED → Supabase ACK
3. Op #2 SYNCED → Supabase ACK  
4. Network cut → Op #3 لا يصل إلى Supabase
5. Device A يغلق التطبيق
6. Device A يعيد التشغيل
7. Device A يبدأ Sync تلقائي
8. فحص: Op #3 هل تم رفعها؟

Expected Result:
- Op #3 تم رفعها عند إعادة التوصيل
- لا تفقد أي عملية
- Sync cursor محدث

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case 4: إغلاق التطبيق أثناء Push أو Pull

```
Precondition:
- Device B قيد Pull 50 سسجل من 100
- تم استهلاك 30 سجل

Steps:
1. Device B يبدأ Pull
2. After 30 records processed
3. Device B يغلق التطبيق
4. Device B يعيد التشغيل
5. Device B يبدأ Pull من sync_cursor = 30

Expected Result:
- لا يُعاد قراءة السجلات 1-30
- يتابع من السجل 31
- لا تكرار العمليات

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

---

## 4. اختبارات التزامن المتعدد الأجهزة

### Test Case 5: تسديد دين العميل من جهازين

```
Precondition:
- Customer: Ali, Debt = 1000 DZD
- Device A وDevice B متصلان بالإنترنت

Steps:
1. Device A: Pay 300 DZD → Expected balance: 700
2. Device B: Pay 200 DZD → Expected balance: 800  
3. انقطاع الاتصال
4. Device B: Pay 250 DZD (offline)
5. عاود الاتصال Device A
6. عاود الاتصال Device B
7. Device A يزامن أولاً
8. Device B يزامن ثانيةً

Expected Result:
- Conflict detected on Payment allocation
- Customer ledger shows: 300 + 200 + 250 = 750
- Balance = 250 DZD
- Both payments recorded in customer_payments
- No payment lost/duplicated

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case 6: بيع آخر كمية من جهازين بدون اتصال

```
Precondition:
- Product: Cleanser, Stock = 10 units
- Device A و Device B غير متصلان بالإنترنت

Steps:
1. Device A: Sell 4 units → Local stock = 6
2. Device B: Sell 5 units → Local stock = 5
3. كلا الجهازين يعملان مستقلناً
4. كلا الجهازين يتصلون بالإنترنت
5. Device A يزامن أولاً: stock = 6
6. Device B يزامن ثانيةً

Expected Result:
- CONFLICT detected: expected 6, got 5
- sync_conflicts يُنشأ
- إشعار للمدير
- Inventory = 1 (theoretical minimum after both sales)
- جميع الفواتير محفوسة

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

---

## 5. اختبارات تعديل المنتج

### Test Case 7: تعديل المنتج نفسه من جهازين

```
Precondition:
- Product: Detergent, name = "Detergent A"

Steps:
1. Device A: Change name to "Detergent B"
2. Device B: Change name to "Detergent C"
3. Device A يزامن أولاً
4. Device B يزامن ثانيةً

Expected Result:
- CONFLICT detected on product name
- MERGE policy: Accept latest with warning
- أو: Manual review required by manager

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

---

## 6. اختبارات الحذف

### Test Case 8: حذف مندوب ثم عودة جهاز قديم

```
Precondition:
- 30 يوم منذ آخر مزامنة Device C
- Device C غير متصل

Steps:
1. Product X محذوف من Device A
2. Device A يزامن → tombstone يُنشأ
3. Device C يعيد التوصل بعد 45 يوم
4. Device C طلب Full Sync
5. System يرسل qائمة BY_ID

Expected Result:
- Product X محذوف من Device C
- جميع الفواتير المرتبطة تُحفظ
- tombstone تُحذف من PostgreSQL (30 يوم)
- Device C لا يفقد البيانات

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

---

## 7. اختبارات تكرار العملية

### Test Case 9: تكرار العملية بمعرف واحد ومحتوى مختلف

```
Precondition:
- Device D متصل بالإنترنت

Steps:
1. أرسل invoice INV-001 بمبلغ 1000 DZD
2. انتظر حتى SYNCED
3. أعد إرسال نفس invoice مع 1500 DZD
4. فحص processed_operations
5. فحص الفاتلة النهائية

Expected Result:
- الطلب الثاني يُرفض كـ DUPLICATE
- الفاتلة تبقى بـ 1000 DZD
- خطأ: "Operation already processed"

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

---

## 8. اختبارات SQL

### Test Case 10: صحة Foreign Keys و Unique Constraints

```sql
-- اختبار UNIQUE constraint على invoice_number
INSERT INTO invoices (invoice_number, ...) VALUES ('INV-001', ...);
INSERT INTO invoices (invoice_number, ...) VALUES ('INV-001', ...);
-- Expected: ERROR - duplicate key value violates unique constraint

-- اختبار FOREIGN KEY على customer_id
INSERT INTO invoices (customer_id, ...) VALUES ('invalid-uuid', ...);
-- Expected: ERROR - new row for relation "invoices" violates foreign key constraint
```

---

## 9. اختبارات الأداء

| الاختبار | المتوقع | الحد الأقصى |
|----------|----------|-------------|
| Sync 100 سجل | 5 ثانية | 10 ثانية |
| SQLite Read 1000 سجل | 100 ms | 200 ms |
| Pull after 30 يوم | 30 ثانية | 60 ثانية |
| Conflict detection | فوري | 1 ثانية |

---

## 10. إعداد البيئة للاختبار

### 10.1 Flutter Test Configuration

```yaml
# test/test_config.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  setUpAll(() async {
    // Initialize test database
    // Set up mock Supabase client
    // Set up test data
  });

  tearDownAll(() async {
    // Clean up test database
  });
}
```

### 10.2 اختبارات الوحدة المطلوبة

- `test/unit/sync/idempotency_test.dart`
- `test/unit/sync/outbox_test.dart`
- `test/unit/sync/conflict_test.dart`
- `test/unit/database/stock_test.dart`
- `test/unit/database/invoice_test.dart`
- `test/unit/database/customer_test.dart`
- `test/unit/database/unit_conversion_test.dart`

### 10.3 اختبارات التكامل

- `test/integration/sync_device_test.dart`
- `test/integration/offline_sync_test.dart`
- `test/integration/conflict_resolution_test.dart`

---

## 11. معايير القبول

| المعيار | الحد الأدنى |
|----------|-------------|
| نسبة نجاح الاختبارات | 95% |
| الوقت المستغرق لاختبار كامل | 5 دقائق |
| عدد الفشل المتكرر | 0 |
| تغطية الكود | 80%+ |
| اختبارات الأمان | 100% نجاح |
| اختبارات المزامنة | 100% نجاح |