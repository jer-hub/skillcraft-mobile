import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mcp/mcp_providers.dart';
import '../../models/model_manager.dart';
import '../../models/model_providers.dart';
import 'model_import_tile.dart';

/// First run: import the chat model (and optionally the embedding model).
class SetupScreen extends ConsumerWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final memory = ref.watch(_memoryProvider).value;
    final gb = memory == null ? null : memory.total / (1 << 30);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 24),
            Text('Welcome to SkillCraft', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('Everything runs on this phone. Import the model files once; '
                'after that SkillCraft works offline.'),
            const SizedBox(height: 8),
            if (gb != null)
              Text(
                gb >= 5.5
                    ? 'Memory: ${gb.toStringAsFixed(1)} GB. Enough for the 1.5B model.'
                    : 'Memory: ${gb.toStringAsFixed(1)} GB. The 1.5B model needs about '
                        '1.5 GB free; it may be slow or fail to load.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 24),
            ModelImportTile(
              role: ModelRole.chat,
              onInstalled: () async => ref.invalidate(chatModelProvider),
            ),
            const SizedBox(height: 12),
            ModelImportTile(
              role: ModelRole.embedding,
              onInstalled: () async => ref.invalidate(vectorStoreProvider),
            ),
            const SizedBox(height: 16),
            Text(
              'Get the files from Hugging Face (Qwen/Qwen2.5-1.5B-Instruct-GGUF and '
              'nomic-ai/nomic-embed-text-v1.5-GGUF), or copy them over USB into '
              'Android/data/com.skillcraft.app/files/models.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

final _memoryProvider = FutureProvider.autoDispose(
    (ref) => ref.watch(deviceServicesProvider).memory());
