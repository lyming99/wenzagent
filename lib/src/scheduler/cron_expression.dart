/// 轻量级 Cron 表达式解析器
///
/// 支持标准 5 段格式:
/// ```
/// ┌───────── 分钟 (0-59)
/// │ ┌────────── 小时 (0-23)
/// │ │ ┌─────────── 日 (1-31)
/// │ │ │ ┌──────────── 月 (1-12)
/// │ │ │ │ ┌─────────── 星期 (0-6, 0=周日)
/// │ │ │ │ │
/// * * * * *
/// ```
///
/// 支持的语法: `*`, `,`, `-`, `/` 及其组合
class CronExpression {
  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> daysOfMonth;
  final Set<int> months;
  final Set<int> daysOfWeek;

  CronExpression._({
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
  });

  /// 从字符串解析
  ///
  /// [expression] 5 段 cron 表达式，如 "0 9 * * 1-5"
  /// 抛出 [FormatException] 如果格式非法
  factory CronExpression.parse(String expression) {
    final parts = expression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) {
      throw FormatException(
          'Cron 表达式必须为 5 段，当前 ${parts.length} 段: $expression');
    }

    return CronExpression._(
      minutes: _parseField(parts[0], 0, 59, '分钟'),
      hours: _parseField(parts[1], 0, 23, '小时'),
      daysOfMonth: _parseField(parts[2], 1, 31, '日'),
      months: _parseField(parts[3], 1, 12, '月'),
      daysOfWeek: _parseField(parts[4], 0, 6, '星期'),
    );
  }

  /// 验证表达式是否合法
  static bool isValid(String expression) {
    try {
      CronExpression.parse(expression);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 计算从 [after] 开始的下一个执行时间
  ///
  /// 如果 [after] 本身就匹配，则返回从下一分钟开始计算的下一个时间点
  DateTime? next(DateTime after) {
    // 从 after 的下一分钟开始搜索
    var candidate = DateTime(
      after.year,
      after.month,
      after.day,
      after.hour,
      after.minute + 1,
    );

    // 最多搜索 4 年（覆盖闰年）
    final maxYear = after.year + 4;

    while (candidate.year <= maxYear) {
      if (_matches(candidate)) return candidate;

      // 逐分钟递增
      candidate = candidate.add(const Duration(minutes: 1));
    }

    return null; // 未找到匹配时间
  }

  /// 检查给定时间是否匹配此 cron 表达式
  bool _matches(DateTime dt) {
    // 月份不匹配
    if (!months.contains(dt.month)) return false;
    // 星期不匹配
    if (!daysOfWeek.contains(dt.weekday % 7)) return false;
    // 日不匹配
    if (!daysOfMonth.contains(dt.day)) return false;
    // 小时不匹配
    if (!hours.contains(dt.hour)) return false;
    // 分钟不匹配
    if (!minutes.contains(dt.minute)) return false;
    return true;
  }

  /// 解析单个字段为 `Set<int>`
  ///
  /// 支持: `*`, `5`, `1,3,5`, `1-5`, `*/15`, `1-5/2`, `1,3-5/2`
  static Set<int> _parseField(String field, int min, int max, String name) {
    final result = <int>{};

    // 按逗号分割各子表达式
    final segments = field.split(',');

    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) {
        throw FormatException('Cron $name 字段存在空段: $field');
      }

      // 解析步长（如有）
      final parts = trimmed.split('/');
      if (parts.length > 2) {
        throw FormatException('Cron $name 字段格式错误: $trimmed');
      }

      final range = parts[0];
      final step = parts.length == 2 ? int.tryParse(parts[1]) ?? 1 : 1;

      if (step < 1) {
        throw FormatException('Cron $name 步长必须 >= 1: $trimmed');
      }

      // 解析范围
      if (range == '*') {
        // 通配符: min 到 max
        for (var i = min; i <= max; i += step) {
          result.add(i);
        }
      } else {
        // 可能包含连字符的范围
        final dashParts = range.split('-');
        if (dashParts.length > 2) {
          throw FormatException('Cron $name 字段格式错误: $range');
        }

        int rangeMin, rangeMax;

        if (dashParts.length == 1) {
          // 单个值
          final value = int.tryParse(dashParts[0]);
          if (value == null || value < min || value > max) {
            throw FormatException(
                'Cron $name 值超出范围 [$min-$max]: ${dashParts[0]}');
          }
          result.add(value);
        } else {
          // 范围
          rangeMin = int.tryParse(dashParts[0]) ?? min;
          rangeMax = int.tryParse(dashParts[1]) ?? max;

          if (rangeMin < min || rangeMax > max || rangeMin > rangeMax) {
            throw FormatException(
                'Cron $name 范围无效 [$rangeMin-$rangeMax]: $range');
          }

          for (var i = rangeMin; i <= rangeMax; i += step) {
            result.add(i);
          }
        }
      }
    }

    if (result.isEmpty) {
      throw FormatException('Cron $name 字段解析结果为空: $field');
    }

    return result;
  }

  @override
  String toString() {
    String format(Set<int> s) {
      if (s.length > 10) return '{${s.length} values}';
      final sorted = s.toList()..sort();
      return sorted.toString();
    }

    return 'Cron(minutes=${format(minutes)}, hours=${format(hours)}, '
        'daysOfMonth=${format(daysOfMonth)}, months=${format(months)}, '
        'daysOfWeek=${format(daysOfWeek)})';
  }
}

/// ISO 8601 Duration 解析器
///
/// 支持的格式:
/// - PT30M  (30 分钟)
/// - PT1H    (1 小时)
/// - PT1H30M (1 小时 30 分钟)
/// - P1D     (1 天)
/// - P1W     (1 周)
class IsoDuration {
  final int totalMinutes;

  IsoDuration._(this.totalMinutes);

  /// 从字符串解析
  ///
  /// 抛出 [FormatException] 如果格式非法
  factory IsoDuration.parse(String duration) {
    final regex =
        RegExp(r'^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$');
    final match = regex.firstMatch(duration.trim());

    if (match == null) {
      throw FormatException('无效的 ISO 8601 Duration: $duration');
    }

    final weeks = int.tryParse(match.group(1) ?? '') ?? 0;
    final days = int.tryParse(match.group(2) ?? '') ?? 0;
    final hours = int.tryParse(match.group(3) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(4) ?? '') ?? 0;

    final totalMinutes =
        weeks * 7 * 24 * 60 + days * 24 * 60 + hours * 60 + minutes;

    if (totalMinutes <= 0) {
      throw FormatException('Duration 必须大于 0: $duration');
    }

    // 最小间隔限制：1 分钟
    if (totalMinutes < 1) {
      throw FormatException('最小间隔为 1 分钟: $duration');
    }

    return IsoDuration._(totalMinutes);
  }

  /// 验证格式是否合法
  static bool isValid(String duration) {
    try {
      IsoDuration.parse(duration);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 计算从 [after] 开始的下一个执行时间
  DateTime next(DateTime after) {
    return after.add(Duration(minutes: totalMinutes));
  }

  /// 转为可读字符串
  @override
  String toString() {
    if (totalMinutes >= 7 * 24 * 60 && totalMinutes % (7 * 24 * 60) == 0) {
      return '${totalMinutes ~/ (7 * 24 * 60)} 周';
    }
    if (totalMinutes >= 24 * 60 && totalMinutes % (24 * 60) == 0) {
      return '${totalMinutes ~/ (24 * 60)} 天';
    }
    if (totalMinutes >= 60 && totalMinutes % 60 == 0) {
      return '${totalMinutes ~/ 60} 小时';
    }
    return '$totalMinutes 分钟';
  }
}
