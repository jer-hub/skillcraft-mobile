import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skillcraft/skills/skill_repository.dart';

String skillSource(String name) => '''
---
name: $name
description: Test skill $name.
output_schema:
  type: object
  properties:
    ok: {type: boolean}
---
Body.
''';

void main() {
  late Directory tmp;
  late SkillRepository repo;
  var seedCalls = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('skills_test');
    seedCalls = 0;
    repo = SkillRepository(
      root: Directory(p.join(tmp.path, 'skills')),
      loadSeedSkills: () async {
        seedCalls++;
        return {'alpha.md': skillSource('alpha')};
      },
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('seeds bundled skills once', () async {
    await repo.ensureSeeded();
    expect((await repo.loadAll()).single.skill?.name, 'alpha');

    await repo.delete('alpha.md');
    await repo.ensureSeeded();
    expect(await repo.loadAll(), isEmpty, reason: 'deleted seed stays deleted');
    expect(seedCalls, 1);
  });

  test('keeps invalid files with their issues', () async {
    await repo.save('broken.md', 'no frontmatter');
    final entry = (await repo.loadAll()).single;
    expect(entry.isValid, isFalse);
    expect(entry.issues, isNotEmpty);
    expect(entry.source, 'no frontmatter');
  });

  test('flags duplicate skill names', () async {
    await repo.save('a.md', skillSource('same'));
    await repo.save('b.md', skillSource('same'));
    final entries = await repo.loadAll();
    expect(entries[0].isValid, isTrue);
    expect(entries[1].isValid, isFalse);
    expect(entries[1].issues.single.message, contains('a.md'));
  });

  test('ignores non-markdown files and rejects path traversal', () async {
    await repo.save('ok.md', skillSource('ok'));
    File(p.join(repo.root.path, 'notes.txt')).writeAsStringSync('x');
    expect((await repo.loadAll()).map((e) => e.fileName), ['ok.md']);
    expect(() => repo.save('../evil.md', 'x'), throwsArgumentError);
  });

  test('watch emits again after a file changes', () async {
    await repo.ensureSeeded();
    final emissions = repo.watch().take(2).toList();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await repo.save('beta.md', skillSource('beta'));
    final results = await emissions.timeout(const Duration(seconds: 5));
    expect(results.first.length, 1);
    expect(results.last.map((e) => e.skill?.name), ['alpha', 'beta']);
  });
}
