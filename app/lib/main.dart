import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/app_shell.dart';

void main() {
  runApp(const ProviderScope(child: SkillCraftApp()));
}

class SkillCraftApp extends StatelessWidget {
  const SkillCraftApp({super.key, this.home = const AppShell()});

  /// Overridable for widget tests.
  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkillCraft',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: home,
    );
  }
}
