# UserInfo Next

Permanent Android application ID: `com.amindada021.userinfo.next`.
Display name: `UserInfo Next`. First version: `0.2.0+17`.
The original `com.amindada021.userinfo` installation remains untouched.
Kotlin namespace remains unchanged; manifest component classes are fully qualified.

## Restore from v0.1.13

1. Keep the original app installed. Export its SQLite backup to a user-selected file.
2. Install the signed Next APK and select Restore in Settings.
3. Select the original SQLite backup. Restore copies it into Next's private sandbox;
   neither the original app nor the source backup is edited.
4. Wait for copy and SQLite validation. Schema 7 from v0.1.13 upgrades to schema 8
   by removing redundant indexes, without deleting records.
5. Compare record count, favorites and sample searches. If indexing was incomplete
   in the backup, resume manual indexing in Settings.

A 50 GB backup needs roughly another 50 GB of free space plus reserve to copy
into Next, in addition to the already occupied old app and backup. Restore checks
known source size before copying. The current device-scale test remains pending.

## Stable signing

Use only the permanent Next key backed up privately as
`UserInfo-Next-Signing-Key.txt`. Never commit this file, a private key, or passwords.
The file includes a base64 PKCS12 keystore, alias and passwords.
Configure the four `USERINFO_NEXT_ANDROID_*` GitHub Actions secrets from it.
Release workflow refuses main publication without all four secrets. Unsigned or
temporary-debug PR artifacts are not uploaded for distribution.
Keep both the key and this application ID fixed for all future Next updates.

`tool/configure_parallel_android.py` applies the ID after Flutter scaffolding;
both CI and local bootstrap call it. The v1.13 schema compatibility test covers
a synthetic copy and verifies that the source bytes stay unchanged. It is not a
50 GB restore benchmark or a substitute for device validation.
