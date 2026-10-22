$ErrorActionPreference = 'Stop'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter SDK is not on PATH. Install Flutter and Android SDK first.'
}
Write-Host 'Generating Android Flutter project files...' -ForegroundColor Cyan
flutter create . --platforms=android --org com.amindada021 --no-pub
if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
$activityDirectory = Join-Path $PWD 'android/app/src/main/kotlin/com/amindada021/userinfo'
New-Item -ItemType Directory -Force -Path $activityDirectory | Out-Null
Copy-Item 'platform_templates/MainActivity.kt' (Join-Path $activityDirectory 'MainActivity.kt') -Force
$fontFolder = Join-Path $PWD 'assets/fonts'
New-Item -ItemType Directory -Force -Path $fontFolder | Out-Null
Invoke-WebRequest 'https://raw.githubusercontent.com/google/fonts/main/ofl/lateef/Lateef-Regular.ttf' -OutFile (Join-Path $fontFolder 'Lateef-Regular.ttf')
Invoke-WebRequest 'https://raw.githubusercontent.com/google/fonts/main/ofl/lateef/OFL.txt' -OutFile (Join-Path $fontFolder 'OFL.txt')
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
flutter analyze
if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed' }
flutter test
if ($LASTEXITCODE -ne 0) { throw 'flutter test failed' }
flutter build apk --debug
if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
Write-Host 'APK: build/app/outputs/flutter-apk/app-debug.apk' -ForegroundColor Green
