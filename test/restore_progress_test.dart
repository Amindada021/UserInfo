import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/data/restore_progress.dart';

void main() {
  test('native progress reports copied bytes, percentage, speed, ETA', () {
    final p = RestoreProgress.fromNative({
      'copied': 500000000, 'total': 2000000000, 'elapsedMs': 5000
    });
    expect(p.stage, RestoreStage.copying);
    expect(p.copyFraction, 0.25);
    expect(p.bytesPerSecond, 100000000.0);
    expect(p.estimatedCopyRemaining, const Duration(seconds: 15));
  });

  test('unknown document size has no invented percentage or ETA', () {
    final p = RestoreProgress.fromNative({
      'copied': 500000000, 'total': null, 'elapsedMs': 5000
    });
    expect(p.copyFraction, isNull);
    expect(p.estimatedCopyRemaining, isNull);
  });

  test('SQLite integrity check never shows guessed progress', () {
    const p = RestoreProgress(stage: RestoreStage.checking,
        copiedBytes: 5000000000, totalBytes: 5000000000);
    expect(p.copyFraction, isNull);
    expect(p.estimatedCopyRemaining, isNull);
  });

  test('overreported byte counts clamp to 100%', () {
    final p = RestoreProgress.fromNative({
      'copied': 105, 'total': 100, 'elapsedMs': 1000
    });
    expect(p.copyFraction, 1);
    expect(p.estimatedCopyRemaining, Duration.zero);
  });
}
