import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_providers.dart';
import 'chat/chat_screen.dart';
import 'nav.dart';
import 'settings/settings_screen.dart';
import 'setup/setup_screen.dart';
import 'skills/skills_screen.dart';

/// Setup until a chat model is installed, then Chat / Skills / Settings.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(chatModelProvider);
    final tab = ref.watch(homeTabProvider);

    // First load (no previous value): show a splash, not the setup screen.
    if (model.isLoading && !model.hasValue) return const _Loading();
    if (!model.hasError && model.value == null) return const SetupScreen();

    return Scaffold(
      body: IndexedStack(
        index: tab.index,
        children: const [ChatScreen(), SkillsScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab.index,
        onDestinationSelected: (i) => ref.read(homeTabProvider.notifier).show(HomeTab.values[i]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.bolt_outlined), label: 'Skills'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading model…'),
          ]),
        ),
      );
}
