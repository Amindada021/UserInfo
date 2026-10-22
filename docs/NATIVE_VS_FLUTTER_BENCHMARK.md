# POCO X7 Pro — native Kotlin vs Flutter/sqflite

این تست فقط زمانی نتیجه واقعی می‌دهد که روی گوشی POCO X7 Pro اجرا شود.
هیچ عددی از سرعت Native پیش از اجرا تأیید نشده است.

**برای حفظ اطلاعات چندمیلیونی روی گوشی، تست را فقط با
`tool/compare_native_import.ps1` اجرا کن.** این اسکریپت شناسه
APK آزمایشی را موقتاً به
`com.amindada021.userinfo.benchmark` تغییر می‌دهد و در پایان
فایل تنظیمات بیلد را برمی‌گرداند. بنابراین اپ اصلی
`com.amindada021.userinfo` از نصب/حذف APK تست آسیب نمی‌بیند.
اجرای مستقیم `flutter test integration_test/...` بدون تغییر
شناسه اپ می‌تواند به امضای APK و داده‌های برنامه اصلی آسیب بزند.

مقایسه شامل خواندن همان فایل CSV ساختگی پنج‌ستونی، SHA-256، پردازش
متن و درج روی دو SQLite جداگانه با اسکیمای فعلی و FTS غیرفعال است.
اندازه Batch در هر دو مسیر یکسان است. ترتیب اجرای آزمایش:
Native، Flutter، Flutter، Native. حداکثر یک‌میلیون رکورد در هر نوبت.

نکته: Parser آزمایشی Kotlin فقط سطرهای ساده و بدون نقل‌قول را می‌خواند.
این آزمون عملکرد تمام قابلیت‌های Parser واقعی (CSV چندخطی، ردیف خراب،
Resume و لاگ) یا مسیر SAF را اثبات نمی‌کند. بخش native به هیچ وجه
جایگزین ایمپورت واقعی برنامه نشده است.

## اجرا

ابتدا با PowerShell از آخرین main کلون کرده و `tool/bootstrap.ps1` را
اجرا کن. گوشی را با USB Debugging وصل کن و شناسه آن را از
`adb devices` بگیر. سپس:

```powershell
powershell -ExecutionPolicy Bypass -File tool/compare_native_import.ps1 -DeviceId DEVICE_ID -Rows 100000 -Batch 1500
powershell -ExecutionPolicy Bypass -File tool/compare_native_import.ps1 -DeviceId DEVICE_ID -Rows 300000 -Batch 15000
```

خروجی `USERINFO_NATIVE_COMPARE_RESULT` شامل سرعت واقعی دو مسیر و
`native_vs_flutter_ratio` است؛ نسبت بالاتر از ۱ یعنی Native در این
آزمایش سریع‌تر بوده است. نتایج روی Linux یا تست شبیه‌سازی‌شده را
به گوشی تعمیم نده.

**امنیت**: دیتابیس فعلی اپ و فایل‌های واقعی هرگز باز نمی‌شوند.
محتوای تست کاملاً مصنوعی است، فقط در پوشه
`cache/userinfo_native_compare` ایجاد می‌شود و در پایان حذف می‌گردد.
اگر آزمون ناگهان قطع شود، پوشه موقت ممکن است باقی بماند.

قبل از انتقال موتور واقعی به Kotlin، تمام قوانین CSV بانکی،
Checkpoint، Migration، سلامت داده و خطاهای نامعتبر باید مجدداً آزموده شوند.
