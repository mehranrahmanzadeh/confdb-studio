String _two(int n) => n.toString().padLeft(2, '0');

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// `10:41` today, `Yesterday`, otherwise `12 Oct`.
String shortTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = _day(n).difference(_day(t)).inDays;
  if (days == 0) return hm(t);
  if (days == 1) return 'Yesterday';
  return '${t.day} ${_months[t.month - 1]}';
}

/// `today 10:41`, `yesterday 17:20`, `12 Oct 09:03`.
String dayAndTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = _day(n).difference(_day(t)).inDays;
  if (days == 0) return 'today ${hm(t)}';
  if (days == 1) return 'yesterday ${hm(t)}';
  return '${t.day} ${_months[t.month - 1]} ${hm(t)}';
}

/// Group label for activity lists: `Today`, `Yesterday`, `Mon 12 Oct`.
String dayGroup(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = _day(n).difference(_day(t)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
}

String hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String hms(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// `1 view`, `2 views`.
String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';
