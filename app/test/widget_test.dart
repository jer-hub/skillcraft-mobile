import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skillcraft/main.dart';

void main() {
  testWidgets('app shell renders', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SkillCraftApp()));

    expect(find.text('SkillCraft'), findsOneWidget);
    expect(find.text('No model loaded'), findsOneWidget);
  });
}
