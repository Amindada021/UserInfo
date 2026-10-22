import 'dart:math' as math;

/// Reports observed progress, never guesses a percentage for SQLite checks.
enum RestoreStage { selecting, copying, checking, replacing, complete }

class RestoreProgress {
  const RestoreProgress({
    required this.stage,
    this.copiedBytes = 0,
    this.totalBytes,
    this.copyElapsedMs = 0,
  });

  final RestoreStage stage;
  final int copiedBytes;
  final int? totalBytes;
  final int copyElapsedMs;

  factory RestoreProgress.fromNative(Map<dynamic, dynamic> values) {
    return RestoreProgress(
      stage: RestoreStage.copying,
      copiedBytes: math.max(0, (values['copied'] as num?)?.toInt() ?? 0),
      totalBytes: (values['total'] as num?)?.toInt(),
      copyElapsedMs: math.max(0, (values['elapsedMs'] as num?)?.toInt() ?? 0),
    );
  }

  double? get copyFraction =>
      stage == RestoreStage.copying && totalBytes != null && totalBytes! > 0
          ? (copiedBytes / totalBytes!).clamp(0.0, 1.0).toDouble()
          : null;

  double? get bytesPerSecond =>
      copyElapsedMs >= 500 && copiedBytes > 0
          ? copiedBytes * 1000.0 / copyElapsedMs
          : null;

  Duration? get estimatedCopyRemaining {
    final speed = bytesPerSecond;
    final total = totalBytes;
    if (stage != RestoreStage.copying || speed == null ||
        speed <= 0 || total == null || total <= 0) {
      return null;
    }
    final seconds = math.max(0, (total - copiedBytes) / speed);
    return Duration(seconds: seconds.ceil());
  }
}
