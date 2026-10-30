import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'skill.dart';
import 'skill_parser.dart';

/// One `.md` file in the skills folder, valid or not.
class SkillEntry {
  const SkillEntry({
    required this.path,
    required this.source,
    this.skill,
    this.issues = const [],
  });

  final String path;
  final String source;

  /// Null when the file has issues.
  final Skill? skill;
  final List<SkillIssue> issues;

  String get fileName => p.basename(path);
  bool get isValid => skill != null && issues.isEmpty;
}

/// Reads and writes skill playbooks in a folder of `.md` files.
class SkillRepository {
  SkillRepository({required this.root, required this.loadSeedSkills});

  /// Folder holding the `.md` skills.
  final Directory root;

  /// Bundled skills (file name -> contents) copied in on first run.
  final Future<Map<String, String>> Function() loadSeedSkills;

  static const _seededMarker = '.seeded';

  /// Creates the folder and copies in bundled skills that were never seeded
  /// before. The marker file lists seeded names, so skills added in an app
  /// update arrive, while a seeded skill the user deleted stays deleted and
  /// an edited one is never overwritten.
  Future<void> ensureSeeded() async {
    await root.create(recursive: true);
    final marker = File(p.join(root.path, _seededMarker));
    final bundled = await loadSeedSkills();

    final Set<String> seeded;
    if (!await marker.exists()) {
      seeded = {};
    } else {
      final listed = (await marker.readAsLines()).where((l) => l.trim().isNotEmpty);
      // An empty marker predates the list: treat bundled files that are
      // present as already seeded.
      seeded = listed.isNotEmpty
          ? listed.toSet()
          : {
              for (final name in bundled.keys)
                if (await File(p.join(root.path, name)).exists()) name,
            };
    }

    for (final MapEntry(key: name, value: text) in bundled.entries) {
      if (seeded.contains(name)) continue;
      final file = File(p.join(root.path, name));
      if (!await file.exists()) await file.writeAsString(text);
      seeded.add(name);
    }
    await marker.writeAsString('${(seeded.toList()..sort()).join('\n')}\n');
  }

  /// Parses every `.md` file, sorted by file name.
  Future<List<SkillEntry>> loadAll() async {
    if (!await root.exists()) return const [];
    final files = await root
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.md'))
        .cast<File>()
        .toList();
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final entries = <SkillEntry>[];
    final firstFileFor = <String, String>{};
    for (final file in files) {
      final entry = _parse(file.path, await file.readAsString());
      final skill = entry.skill;
      if (skill == null) {
        entries.add(entry);
        continue;
      }
      final other = firstFileFor[skill.name];
      if (other != null) {
        entries.add(SkillEntry(path: file.path, source: entry.source, issues: [
          SkillIssue('Skill name "${skill.name}" is already used by $other',
              line: 2),
        ]));
      } else {
        firstFileFor[skill.name] = entry.fileName;
        entries.add(entry);
      }
    }
    return entries;
  }

  /// One native watch per folder, shared by every listener in the isolate.
  /// On Android, watching a folder twice returns the same inotify handle,
  /// which trips an assertion in dart:io (it only expects reuse on Linux)
  /// and would double the work anyway.
  static final _watches = <String, Stream<FileSystemEvent>>{};

  static Stream<FileSystemEvent> _folderEvents(Directory dir) {
    final key = dir.absolute.path;
    return _watches[key] ??= dir.watch().asBroadcastStream(onCancel: (sub) {
      // Last listener gone: stop the native watch and forget it.
      sub.cancel();
      _watches.remove(key);
    });
  }

  /// Emits the current entries, then again whenever the folder changes.
  Stream<List<SkillEntry>> watch() async* {
    yield await loadAll();
    if (!await root.exists()) return;
    // Editors write in several steps; collapse bursts into one reload.
    final changes = StreamController<void>();
    Timer? debounce;
    final sub = _folderEvents(root).listen((_) {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), () => changes.add(null));
    });
    try {
      await for (final _ in changes.stream) {
        yield await loadAll();
      }
    } finally {
      debounce?.cancel();
      await sub.cancel();
      await changes.close();
    }
  }

  /// Validates and writes [source] to [fileName]. The file is written even
  /// when invalid, so work in progress is never lost; check the result.
  Future<SkillEntry> save(String fileName, String source) async {
    if (p.basename(fileName) != fileName || !fileName.endsWith('.md')) {
      throw ArgumentError.value(fileName, 'fileName', 'must be a plain .md name');
    }
    await root.create(recursive: true);
    final path = p.join(root.path, fileName);
    await File(path).writeAsString(source);
    return _parse(path, source);
  }

  Future<void> delete(String fileName) async {
    final file = File(p.join(root.path, p.basename(fileName)));
    if (await file.exists()) await file.delete();
  }

  static SkillEntry _parse(String path, String source) {
    try {
      return SkillEntry(
          path: path, source: source, skill: parseSkill(source, path: path));
    } on SkillFormatException catch (e) {
      return SkillEntry(path: path, source: source, issues: e.issues);
    }
  }
}
