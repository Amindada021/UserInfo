"""Apply the permanent side-by-side identity after flutter create."""
from pathlib import Path

gradle = Path('android/app/build.gradle.kts')
text = gradle.read_text()
old = 'applicationId = "com.amindada021.userinfo"'
new = 'applicationId = "com.amindada021.userinfo.next"'
if old not in text and new not in text:
    raise SystemExit('Unexpected application ID: refusing to build')
gradle.write_text(text.replace(old, new))
