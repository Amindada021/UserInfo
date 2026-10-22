$ErrorActionPreference = 'Stop'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter SDK is not on PATH. Install Flutter and Android SDK first.'
}
Write-Host 'Generating Android Flutter project files...' -ForegroundColor Cyan
flutter create . --platforms=android --org com.example --no-pub
if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
flutter analyze
if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed' }
flutter test
if ($LASTEXITCODE -ne 0) { throw 'flutter test failed' }
flutter build apk --debug
if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
Write-Host 'APK: build/app/outputs/flutter-apk/app-debug.apk' -ForegroundColor Green
