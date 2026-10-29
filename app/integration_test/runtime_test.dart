// On-device checks for the native runtime pieces that cannot run on the
// development PC: QuickJS, sqlite-vec, the bundled tool servers, and a full
// agent run with the real model.
//
//   flutter test integration_test/runtime_test.dart -d <device> --no-uninstall
//
// Always pass --no-uninstall: by default the app is uninstalled afterwards,
// which wipes Android/data/com.skillcraft.app, including the imported models.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quickjs_ffi/quickjs_ffi.dart';
import 'package:skillcraft/agent/agent_runner.dart';
import 'package:skillcraft/core/config.dart';
import 'package:skillcraft/inference/llama_engine.dart';
import 'package:skillcraft/mcp/calendar_bridge.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/mcp/mcp_host.dart';
import 'package:skillcraft/mcp/tool_servers.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';
import 'package:skillcraft/storage/database.dart';
import 'package:skillcraft/storage/vector_store.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

/// Records calendar writes instead of touching the user's real calendar.
class RecordingCalendar implements CalendarBridge {
  final inserted = <String>[];

  @override
  Future<String> insert(
      {required String title, required DateTime start, DateTime? end, String? description}) async {
    inserted.add('$title@${start.toIso8601String()}');
    return 'evt-${inserted.length}';
  }

  @override
  Future<List<Map<String, Object?>>> list({required DateTime from, required DateTime to}) async =>
      [
        {'title': 'Standup', 'start': from.toIso8601String()},
      ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('QuickJS', () {
    late QuickJs js;
    final hostCalls = <String>[];

    setUp(() {
      hostCalls.clear();
      js = QuickJs(
        onHost: (name, payload) async {
          hostCalls.add(name);
          if (name == 'fail') throw StateError('nope');
          return {'echo': payload};
        },
        timeout: const Duration(milliseconds: 500),
      );
    });
    tearDown(() => js.dispose());

    test('evaluates and returns JSON values', () {
      expect(js.eval('1 + 2'), 3);
      expect(js.eval('({a: [1, "x", null]})'), {
        'a': [1, 'x', null],
      });
      expect(js.eval('undefined'), isNull);
    });

    test('async host round trip', () async {
      final r = await js.evalAsync(
          '__host("ping", JSON.stringify({n: 1})).then((r) => r.echo.n + 1)');
      expect(r, 2);
      expect(hostCalls, ['ping']);
      expect(js.pendingHostCalls, 0);
    });

    test('host errors reject inside the script', () async {
      final r = await js.evalAsync(
          '__host("fail", "null").then(() => "resolved", (e) => "caught: " + e.message)');
      expect(r, contains('caught: Bad state: nope'));
    });

    test('script errors and rejections surface as JsException', () async {
      expect(() => js.eval('throw new TypeError("bad")'),
          throwsA(isA<JsException>().having((e) => e.message, 'message', contains('bad'))));
      await expectLater(js.evalAsync('Promise.reject(new Error("later"))'),
          throwsA(isA<JsException>()));
    });

    test('infinite loops are interrupted', () {
      expect(() => js.eval('for (;;) {}'),
          throwsA(isA<JsException>().having((e) => e.isTimeout, 'isTimeout', isTrue)));
      expect(js.eval('"still usable"'), 'still usable');
    });

    test('memory limit is enforced', () {
      final small = QuickJs(onHost: (_, _) => null, memoryLimitBytes: 4 * 1024 * 1024);
      addTearDown(small.dispose);
      expect(() => small.eval('const a = []; for (;;) a.push("x".repeat(1024));'),
          throwsA(isA<JsException>()));
    });

    test('sandbox has no file, network or module access', () {
      expect(
          js.eval('[typeof require, typeof fetch, typeof std, typeof os, typeof XMLHttpRequest]'),
          ['undefined', 'undefined', 'undefined', 'undefined', 'undefined']);
    });
  });

  group('sqlite-vec', () {
    test('registers and runs a KNN query', () {
      registerSqliteVec();
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      expect(db.hasVectorSupport, isTrue);

      db.execute('CREATE VIRTUAL TABLE v USING vec0(embedding float[3])');
      db.execute("INSERT INTO v(rowid, embedding) VALUES (1, '[1,0,0]'), (2, '[0,1,0]'), (3, '[0.9,0.1,0]')");
      final rows = db.query(
          "SELECT rowid FROM v WHERE embedding MATCH '[1,0,0]' AND k = 2 ORDER BY distance");
      expect(rows.map((r) => r['rowid']), [1, 3]);
    });
  });

  group('bundled tool servers', () {
    late AppDatabase db;
    late McpHost host;
    late RecordingCalendar calendar;

    setUp(() async {
      db = AppDatabase.inMemory();
      calendar = RecordingCalendar();
      final (h, failures) = await startToolServers(
        loadAsset: rootBundle.loadString,
        capabilityFunctions: {
          Capability.sql: sqlFunctions(db),
          Capability.calendar: calendarFunctions(calendar),
        },
        commonFunctions: logFunctions((_) {}),
        enabled: {'local_db', 'calendar'},
      );
      expect(failures, isEmpty);
      host = h;
    });
    tearDown(() async {
      await host.dispose();
      db.close();
    });

    test('advertise their tools', () {
      expect(host.servers.map((s) => s.name), ['SkillCraft-LocalDB', 'SkillCraft-Calendar']);
      expect(host.tools.map((t) => t.name), [
        'save_task_to_db',
        'list_tasks',
        'update_task_status',
        'create_event',
        'list_events',
      ]);
    });

    test('save_task_to_db writes to SQLite', () async {
      final r = await host.callTool(
          'save_task_to_db', {'title': 'Send budget', 'priority': 'high', 'due_date': 'Friday'});
      expect(r.isError, isFalse);
      expect(r.text, "Successfully saved task #1: 'Send budget'");
      expect(db.query('SELECT title, priority, due_date, status FROM tasks'), [
        {'title': 'Send budget', 'priority': 'high', 'due_date': 'Friday', 'status': 'pending'},
      ]);

      final done = await host.callTool('update_task_status', {'id': 1, 'status': 'done'});
      expect(done.text, 'Task #1 marked done');
      final listed = await host.callTool('list_tasks', {'status': 'done'});
      expect((listed.structured as Map)['tasks'], hasLength(1));
    });

    test('invalid arguments come back as tool errors', () async {
      final r = await host.callTool('save_task_to_db', {'title': 'x', 'priority': 'urgent'});
      expect(r.isError, isTrue);
      expect(db.query('SELECT * FROM tasks'), isEmpty);
    });

    test('calendar server only reaches the calendar bridge', () async {
      final r = await host.callTool('create_event', {'title': 'Review', 'start': '2026-11-03T14:00'});
      expect(r.isError, isFalse);
      expect(calendar.inserted.single, startsWith('Review@2026-11-03T14:00'));
    });
  });

  group('notes with real embeddings', () {
    late LlamaEngine engine;
    late AppDatabase db;
    late VectorStore store;

    setUpAll(() async {
      final base = await getExternalStorageDirectory();
      final model = File('${base!.path}/${AppPaths.modelsDir}/${AppPaths.embeddingModelFile}');
      if (!model.existsSync()) fail('embedding model missing at ${model.path}');
      registerSqliteVec();
      engine = LlamaEngine();
      final sw = Stopwatch()..start();
      await engine.loadEmbedder(model.path);
      // ignore: avoid_print
      print('EMBED_LOAD ${sw.elapsedMilliseconds} ms · dim ${engine.embeddingDimensions}');
    });
    tearDownAll(() => engine.dispose());

    setUp(() async {
      db = AppDatabase.inMemory();
      store = VectorStore(db, engine);
      await store.open();
    });
    tearDown(() => db.close());

    test('embeddings are unit-length and deterministic', () async {
      expect(engine.embeddingDimensions, 768);
      final a = await engine.embed('search_query: hello');
      final b = await engine.embed('search_query: hello');
      expect(a, b);
      final norm = a.fold<double>(0, (s, x) => s + x * x);
      expect(norm, closeTo(1, 1e-3));
    });

    test('search ranks notes by meaning, not keywords', () async {
      const notes = [
        'The wifi password for the office is Tr0ub4dor',
        "Dentist appointment moved to Thursday at 3pm",
        'Buy oat milk, eggs and spinach on the way home',
        'Our team retro will cover the failed release',
      ];
      final sw = Stopwatch()..start();
      for (final n in notes) {
        await store.remember(n);
      }
      final indexMs = sw.elapsedMilliseconds;

      sw.reset();
      final groceries = await store.search('what do I need from the supermarket', k: 2);
      final network = await store.search('how do I get on the internet at work', k: 2);
      final health = await store.search('when is my teeth checkup', k: 2);
      // ignore: avoid_print
      print('VEC_SEARCH index ${notes.length} notes $indexMs ms · 3 searches '
          '${sw.elapsedMilliseconds} ms · top scores '
          '${[groceries, network, health].map((h) => h.first.score.toStringAsFixed(3)).join(', ')}');

      expect(groceries.first.text, contains('oat milk'));
      expect(network.first.text, contains('wifi'));
      expect(health.first.text, contains('Dentist'));
      expect(groceries.first.score, greaterThan(groceries.last.score));
    });

    test('reopening keeps the index; a new dimension rebuilds it', () async {
      final id = await store.remember('Locker combination 1-2-3');
      await store.open();
      expect((await store.search('locker', k: 1)).single.id, id);

      db.setMeta('embedding_dim', '384'); // pretend the model changed
      await store.open();
      expect((await store.search('locker', k: 1)).single.id, id,
          reason: 'notes are re-embedded after a rebuild');
    });

    test('notes tool server end to end', () async {
      final (host, failures) = await startToolServers(
        loadAsset: rootBundle.loadString,
        capabilityFunctions: {Capability.vector: vectorFunctions(store)},
        commonFunctions: logFunctions((_) {}),
        enabled: {'notes'},
      );
      addTearDown(host.dispose);
      expect(failures, isEmpty);

      await host.callTool('remember_note', {'text': 'Parked on level 3, spot B12'});
      await host.callTool('remember_note', {'text': 'Mom’s birthday is March 9'});
      final r = await host.callTool('search_notes', {'query': 'where is my car', 'k': 1});
      expect(r.isError, isFalse);
      expect(((r.structured as Map)['notes'] as List).single['text'], contains('level 3'));
    });
  });

  group('agent with the real model', () {
    test('capture-tasks extracts and saves tasks', () async {
      final base = await getExternalStorageDirectory();
      final model = File('${base!.path}/${AppPaths.modelsDir}/${AppPaths.defaultModelFile}');
      if (!model.existsSync()) {
        markTestSkipped('model not found at ${model.path}');
        return;
      }

      final db = AppDatabase.inMemory();
      final (host, _) = await startToolServers(
        loadAsset: rootBundle.loadString,
        capabilityFunctions: {Capability.sql: sqlFunctions(db)},
        commonFunctions: logFunctions((_) {}),
        enabled: {'local_db'},
      );
      final engine = LlamaEngine();
      addTearDown(() async {
        await engine.dispose();
        await host.dispose();
        db.close();
      });
      await engine.load(model.path, const EngineConfig());

      final skill = parseSkill(await rootBundle.loadString('assets/skills/capture-tasks.md'));
      final runner = AgentRunner(engine: engine, compiler: SkillCompiler(engine), mcp: host);
      final sw = Stopwatch()..start();
      final events = await runner.run(skill, {
        'raw_text': 'Project kickoff, Nov 3. Leo needs to set up the staging server '
            'by Wednesday. Priya will write the API spec, no rush.',
      }).toList();

      final last = events.last;
      expect(last, isA<AgentFinished>(), reason: last is AgentFailed ? '${last.error}' : '');
      final tasks = ((last as AgentFinished).output as Map)['tasks'] as List;
      final rows = db.query('SELECT title, priority, due_date FROM tasks ORDER BY id');
      final hookResults = events.whereType<AgentToolResult>().where((r) => r.fromHook);

      // ignore: avoid_print
      print('AGENT_E2E ${sw.elapsedMilliseconds} ms · ${tasks.length} tasks · rows $rows');
      expect(tasks, isNotEmpty);
      expect(rows, hasLength(tasks.length));
      expect(hookResults.every((r) => !r.result.isError), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
