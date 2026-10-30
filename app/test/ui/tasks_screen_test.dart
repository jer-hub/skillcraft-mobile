import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/main.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/mcp/mcp_providers.dart';
import 'package:skillcraft/storage/data_providers.dart';
import 'package:skillcraft/storage/database.dart';
import 'package:skillcraft/storage/storage_providers.dart';
import 'package:skillcraft/ui/tasks/tasks_screen.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.inMemory();
    db.execute("INSERT INTO tasks (title, priority, due_date) VALUES ('Send budget', 'high', 'Friday')");
    db.execute("INSERT INTO tasks (title, priority) VALUES ('Book room', 'low')");
    db.execute("INSERT INTO notes (text) VALUES ('Gate code 4412')");
  });
  tearDown(() => db.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => db),
      vectorStoreProvider.overrideWith((ref) async => null),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const SkillCraftApp(home: TasksScreen()),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('shows tasks with priority and due date', (tester) async {
    await pump(tester);
    expect(find.text('Send budget'), findsOneWidget);
    expect(find.text('Book room'), findsOneWidget);
    expect(find.text('Friday'), findsOneWidget);
  });

  testWidgets('ticking a task moves it to Done', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Send budget'));
    await tester.pumpAndSettle();
    expect(db.query("SELECT status FROM tasks WHERE title = 'Send budget'").single['status'], 'done');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Send budget'), findsOneWidget);
    expect(find.text('Book room'), findsNothing);
  });

  testWidgets('swipe deletes with undo', (tester) async {
    await pump(tester);
    await tester.drag(find.text('Book room'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Book room'), findsNothing);
    expect(db.query('SELECT * FROM tasks'), hasLength(1));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Book room'), findsOneWidget);
    expect(db.query('SELECT * FROM tasks'), hasLength(2));
  });

  testWidgets('a task saved by a skill appears without leaving the screen', (tester) async {
    final container = await pump(tester);
    final toolSql = sqlFunctions(db, onWrite: container.read(dataVersionProvider.notifier).bump);

    await tester.runAsync(() async => toolSql['sql.execute']!({
          'sql': 'INSERT INTO tasks (title, priority) VALUES (?, ?)',
          'params': ['Mara: file the grant report', 'high'],
        }));
    await tester.pumpAndSettle();

    expect(find.text('Mara: file the grant report'), findsOneWidget);
  });

  testWidgets('notes tab searches by text and deletes after confirming', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Gate code 4412'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('note-search')), 'nothing like it');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('No notes match'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('note-search')), '');
    await tester.pumpAndSettle();
    await tester.drag(find.text('Gate code 4412'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(db.query('SELECT * FROM notes'), isEmpty);
  });
}
