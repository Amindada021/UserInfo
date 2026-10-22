# POCO X7 Pro — روش اجرای بنچمارک واقعی UserInfo

این تست **هنوز روی POCO X7 Pro اجرا نشده است**. نتیجه واقعی فقط زمانی
معتبر است که کد تست مستقیماً روی دستگاه اجرا شود و خروجی آن ثبت گردد.
اعداد Linux یا شبیه‌ساز را با گوشی یکسان فرض نکنید.

## محیط لازم

- گوشی POCO X7 Pro با USB debugging و مجوز اتصال ADB
- رایانه‌ای با Flutter و Android SDK؛ مخزن UserInfo نسخه `main`
- فضای خالی مناسب (برای مقیاس بزرگ ده‌ها گیگابایت)؛ بدون انتقال اطلاعات واقعی
- کابل USB پایدار، شارژ مناسب و ترجیحاً کنترل دمای دستگاه
- اجرای تست فقط با دیتابیس **موقت و کاملاً مصنوعی** در پوشهٔ اختصاصی تست
- اجرای تست ۱۰۰ میلیون رکورد تنها با تأیید ظرفیت فضای آزاد، دما و زمان

## مراحل Windows PowerShell

```powershell
git clone https://github.com/Amindada021/UserInfo.git
cd UserInfo
powershell -ExecutionPolicy Bypass -File .\tool\bootstrap.ps1
adb devices -l
flutter devices
# شناسه واقعی گوشی را جای DEVICE_ID بگذارید
flutter test integration_test/device_benchmark_test.dart -d DEVICE_ID --profile --dart-define=USERINFO_BENCHMARK_ROWS=100000 --dart-define=USERINFO_BATCH_SIZE=1500 --dart-define=USERINFO_MIN_FREE_GIB=5 --dart-define=USERINFO_MAX_TEST_HOURS=2
```

بعد از اجرای موفق ۱۰۰ هزار رکورد، همین دستور را با مقادیر
`1000000`، `5000000` و `10000000` تکرار کنید.
برای ۱۰۰ میلیون رکورد، مقدار
`USERINFO_BENCHMARK_ROWS=100000000` و متناسب با فضای آزاد
`USERINFO_MIN_FREE_GIB` و `USERINFO_MAX_TEST_HOURS` را تنظیم کنید.

**هر بار تست دیتابیس تازه و جداگانه می‌سازد و در پایان پاک می‌کند.**
اطلاعات UserInfo اصلی را بازنویسی یا حذف نمی‌کند. اگر گوشی داغ شد،
حافظه آزاد کافی نداشت یا آزمون از سقف زمان گذشت، نتیجه به‌صورت تست
ناکامل ثبت می‌شود؛ **هیچ نتیجه‌ای را موفق فرض نکنید.**

## خروجی و تفسیر

در ترمینال به دنبال `USERINFO_DEVICE_BENCHMARK` بگردید:
- `insert_rows_per_second` سرعت درج واقعی از مسیر Flutter/sqflite
- `index_elapsed_seconds` زمان تکمیل ایندکس نام
- `batch_p50_us` و `batch_p95_us` تأخیر تراکنش‌ها
- `sqlite_bytes` و `wal_bytes` حجم DB/WAL
- `queries` زمان P50 و P95 جستجوها
- `rss_bytes` و `max_rss_bytes` حافظهٔ فرآیند

محدودیت: این تست با `insertBatch` و SQLite تولید داده می‌کند؛
سرعت واقعی خواندن CSV از Storage Access Framework،
Parsing فایل چندگیگابایتی و Foreground Service را اندازه نمی‌گیرد.
برای آن باید یک CSV **ساختگی** از مسیر Import خود اپ وارد شود.

هرگز CSV واقعی بانکی، دیتابیس کاربران یا نتیجه دارای اطلاعات شخصی را
در مخزن عمومی یا لاگ قابل‌اشتراک قرار ندهید.
