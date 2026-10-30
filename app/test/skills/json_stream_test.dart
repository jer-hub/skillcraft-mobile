import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/skills/json_stream.dart';

JsonStreamScanner scan(String text, {int chunk = 5}) {
  final s = JsonStreamScanner();
  for (var i = 0; i < text.length; i += chunk) {
    s.add(text.substring(i, i + chunk > text.length ? text.length : i + chunk));
  }
  return s;
}

String task(String title) => '{"title": "$title", "priority": "high"}';

void main() {
  test('a finished document is complete and not looping', () {
    final s = scan('{"tasks": [${task('A')}, ${task('B')}]}');
    expect(s.isComplete, isTrue);
    expect(s.isLooping, isFalse);
  });

  test('detects the same item three times in a row (the #21 loop)', () {
    final s = scan('{"tasks": [${task('Collect')}, ${task('Arrange')}, ${task('Arrange')}, '
        '${task('Arrange')}, {"title": "Arr');
    expect(s.isLooping, isTrue);
    expect(s.isComplete, isFalse);

    final best = jsonDecode(s.salvageCandidates().first) as Map;
    expect((best['tasks'] as List).map((t) => t['title']), ['Collect', 'Arrange'],
        reason: 'the repeated item is kept once');
  });

  test('two repeats then a new item is not a loop', () {
    final s = scan('[${task('A')}, ${task('A')}, ${task('B')}, ${task('B')}]');
    expect(s.isLooping, isFalse);
    expect(s.isComplete, isTrue);
  });

  test('salvages a document cut off mid-string by the token limit (#48)', () {
    final items = List.generate(13, (i) => task('review section $i'));
    final s = scan('{"tasks": [${items.join(', ')}, {"title": "review sect');

    final candidates = s.salvageCandidates();
    final best = jsonDecode(candidates.first) as Map;
    expect(best['tasks'], hasLength(13));
    for (final c in candidates) {
      expect(() => jsonDecode(c), returnsNormally, reason: c);
    }
  });

  test('an array that just opened salvages to an empty list', () {
    final s = scan('{"tasks": [');
    expect(jsonDecode(s.salvageCandidates().first), {'tasks': <Object?>[]});
  });

  test('brackets and commas inside strings are ignored', () {
    final s = scan('{"tasks": [{"title": "a, [b] {c} \\"d\\""}, {"title": "e');
    final best = jsonDecode(s.salvageCandidates().first) as Map;
    expect(best['tasks'], [
      {'title': 'a, [b] {c} "d"'},
    ]);
  });

  test('nothing to salvage before any array opens', () {
    expect(scan('{"tas').salvageCandidates(), isEmpty);
  });
}
