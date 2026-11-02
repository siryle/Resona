class LyricLine {
  final double? seconds;
  final String text;
  LyricLine(this.seconds, this.text);
}

List<LyricLine> parseLyrics(String text) {
  final lines = <LyricLine>[];
  final pattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  final offsetMatch = RegExp(
    r'\[offset:([+-]?\d+)\]',
    caseSensitive: false,
  ).firstMatch(text);
  final offset = (int.tryParse(offsetMatch?.group(1) ?? '') ?? 0) / 1000;
  var timed = false;
  for (final row in text.split('\n')) {
    final matches = pattern.allMatches(row).toList();
    if (matches.isEmpty) continue;
    timed = true;
    final body = row.replaceAll(pattern, '').trim();
    for (final match in matches) {
      final seconds =
          int.parse(match[1]!) * 60 +
          int.parse(match[2]!) +
          double.parse('0.${match[3] ?? '0'}') +
          offset;
      lines.add(LyricLine(seconds, body));
    }
  }
  if (timed) {
    lines.sort((a, b) => a.seconds!.compareTo(b.seconds!));
    return lines;
  }
  return text
      .split('\n')
      .where((row) => row.trim().isNotEmpty)
      .map((row) => LyricLine(null, row.trim()))
      .toList();
}
