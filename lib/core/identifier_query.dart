import 'text_normalizer.dart';

/// Query-only normalization: original records and existing indexes are retained.
class IdentifierQuery {
  IdentifierQuery(String input, {required this.mobile}) {
    final normalized = TextNormalizer.normalize(input);
    if (!RegExp(r'^\+?[0-9]+$').hasMatch(normalized)) {
      throw ArgumentError('شماره را فقط با رقم و در صورت نیاز پیش‌شماره +98 وارد کنید');
    }
    var value = normalized;
    if (mobile) {
      if (value.startsWith('+98')) {
        value = '0${value.substring(3)}';
      } else if (value.startsWith('0098')) {
        value = '0${value.substring(4)}';
      } else if (value.startsWith('98')) {
        value = '0${value.substring(2)}';
      } else if (value.startsWith('9')) {
        value = '0$value';
      }
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
      throw ArgumentError('شماره نامعتبر است');
    }
    exact = value.length == (mobile ? 11 : 10);
    if (value.length > (mobile ? 11 : 10) || (!exact && value.length < 7)) {
      throw ArgumentError('برای جستجوی ابتدای شماره حداقل ۷ رقم وارد کنید');
    }
    values = mobile && value.startsWith('09')
        ? [value, '98${value.substring(1)}', '+98${value.substring(1)}',
            '0098${value.substring(1)}', value.substring(1)]
        : [value];
  }

  final bool mobile;
  late final bool exact;
  late final List<String> values;

  (String, List<Object?>) predicate(String column) {
    if (exact) {
      return ('$column IN (${List.filled(values.length, '?').join(',')})',
          [...values]);
    }
    return ('(${List.filled(values.length, '($column >= ? AND $column < ?)').join(' OR ')})',
        [for (final value in values) ...[value, '$value\u{10ffff}']]);
  }
}
