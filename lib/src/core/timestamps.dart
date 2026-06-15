/// Formats [dt] as a metadata timestamp: ISO 8601 with a `+00:00` offset and
/// trailing fractional zeros trimmed — matching the server's `createTime` /
/// `updateTime` format (PROTOCOL §2.1).
String formatMetaTimestamp(DateTime dt) {
  final utc = dt.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final mo = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  final h = utc.hour.toString().padLeft(2, '0');
  final mi = utc.minute.toString().padLeft(2, '0');
  final s = utc.second.toString().padLeft(2, '0');
  final ms = utc.millisecond;
  final us = utc.microsecond;
  final totalMicros = ms * 1000 + us;
  if (totalMicros == 0) {
    return '$y-$mo-${d}T$h:$mi:$s+00:00';
  }
  // Trim trailing zeros per PROTOCOL: "2026-06-07T10:05:00.001+00:00"
  var frac = totalMicros.toString().padLeft(6, '0');
  while (frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  return '$y-$mo-${d}T$h:$mi:$s.$frac+00:00';
}
