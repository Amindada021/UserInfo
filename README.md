# UserInfo — Flutter Android

اپ شخصی آفلاین برای واردکردن CSV بانک‌های ملی و ملت، ذخیره در SQLite و جستجوی مشترک رکوردها. رابط کاربری فارسی و راست‌به‌چپ است.

> **مهم: دیتابیس نسخه آزمایشی فعلاً با SQLite معمولی ذخیره می‌شود و رمزگذاری SQLCipher هنوز پیاده نشده است. برای داده‌های حساس واقعی تا زمان افزودن رمزگذاری و تست امنیتی، از نسخه آزمایشی استفاده نکنید.** فایل‌های CSV نمونه هم داده واقعی شخصی دارند و نباید در Git ذخیره شوند.

## وضعیت فعلی (Prototype)

- Flutter Android + Material 3، کارت‌های Collapse، جزئیات، انتخاب و کپی افراد.
- SQLite محلی با نام `userinfo.sqlite`، ایندکس‌های نام/شناسه، جستجوی پیشوندی؛ صفحه‌بندی ۲۰/۵۰/۱۰۰.
- انتخاب چند CSV از Android Storage Access Framework، خواندن تدریجی بدون کپی اجباری کامل فایل به حافظه یا کش.
- تشخیص هدر ۱۳ ستونی ملت و ۵ ستونی ملی، نگهداری صفرهای ابتدای شناسه‌ها و حفظ مقدار اصلی نام؛ نرمال‌سازی `ي/ی`، `ك/ک`، اعراب، ارقام و فاصله‌ها برای جستجو.
- درج دسته‌ای ۲۵۰ تایی، شمارش رکوردهای ثبت‌شده، درصد بایت‌های خوانده‌شده، حذف امن فایل نیمه‌کاره در زمان لغو/خطا. ایمپورت‌های ناقص پس از راه‌اندازی بعدی پاک می‌شوند.
- فیلترهای بانک و فیلدها، موبایل خالی، محدوده تولد و فایل منبع؛ انتخاب اشخاص در چند صفحه حفظ می‌شود.
- حذف تمام داده‌های داخل اپ فقط با تأیید؛ CSV اصلی حذف نمی‌شود.
- خروجی PDF و XLSX آزمایشی برای **صفحه فعلی یا انتخاب‌شده‌ها، حداکثر ۱۰۰ رکورد**. PDF از فونت عربی موجود روی دستگاه استفاده می‌کند و روی گوشی‌های فاقد فونت سازگار پیام خطا خواهد داد.

## شروع روی ویندوز

نیازمند نصب Flutter SDK، Android SDK و JDK سازگار است.

```powershell
git clone https://github.com/Amindada021/UserInfo.git
cd UserInfo
powershell -ExecutionPolicy Bypass -File .\tool\bootstrap.ps1
```

یا به ترتیب:

```powershell
flutter create . --platforms=android --org com.example --no-pub
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

خروجی APK پس از Build در `build/app/outputs/flutter-apk/app-debug.apk` ساخته می‌شود. برای اجرا روی گوشی با USB debugging، `flutter run` را اجرا کنید.

پوشه Android موجود عمداً فقط شامل فایل‌های بومی سفارشی پروژه است؛ فایل‌های استاندارد Gradle و Wrapper با `flutter create` روی ماشین توسعه یا در CI تولید می‌شوند.

## محدودیت‌های نسخه اول

- ساخت و تست APK با دستگاه واقعی هنوز تأیید نشده. تست چندگیگابایتی نیازمند فضای کافی و Benchmark واقعی است.
- فقط UTF-8 و دو قالب هدر شناخته‌شده پشتیبانی می‌شوند؛ فایل با Encoding دیگر خطا می‌دهد.
- جستجوی نام فعلاً **prefix** با ایندکس SQL است، نه FTS5 / contains همه‌کلمات.
- شمارش نتایج و صفحه‌بندی با OFFSET روی دیتاست عظیم ممکن است کند شود؛ Keyset pagination بعداً لازم است.
- تشخیص تکراری فعلاً با نام فایل، بانک و اندازه است و Fingerprint محتوا ندارد.
- حذف بعد از قطع برنامه به‌جای Resume، داده نیمه‌کاره را پاک می‌کند.
- SQLite ذخیره‌شده رمزگذاری نشده؛ محافظت پایه شامل Android sandbox، غیرفعال‌سازی Backup و FLAG_SECURE است، و جایگزین encryption نیست.
- خروجی PDF کامل برای فضای کم فقط شش ستون منتخب را نشان می‌دهد؛ Excel همه ۱۵ فیلد را در حالت مجاز شامل می‌شود.
- خروجی «تمام نتایج فیلترشده» تا پیاده‌سازی Export جریانی فعال نشده است.
- داده واقعی، تست کارایی، قفل با بیومتریک، رمزگذاری کلید سخت‌افزاری، PDF فونت مستقل از دستگاه و تست روی گوشی باید پیش از استفاده واقعی تکمیل شوند.

## اصول امنیت داده

- هیچ CSV واقعی، تصویر یا لاگ حاوی رکورد، SQLite، PDF و XLSX را Commit یا روی GitHub آپلود نکنید.
- پیشنهاد اکید: ریپازیتوری را Private کنید.
- برنامه اینترنت/API/Analytics ندارد.
- اطلاعات موجود در Clipboard و فایل Export پس از خروج از اپ تحت حفاظت برنامه نیستند.
- تست خودکار فقط از رشته‌های ساختگی استفاده می‌کند.

## ساختار

```text
lib/
  main.dart                      Flutter RTL UI
  core/                         parser + Persian normalizer
  data/                         SAF bridge, SQLite, importer, export
android/app/src/main/           native SAF bridge + Android manifest
test/                           unit tests with synthetic strings
tool/bootstrap.ps1              Flutter bootstrap + debug APK
.github/workflows/flutter.yml   CI: analyze, test, build
```
