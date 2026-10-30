import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/model_manager.dart';
import '../../models/model_providers.dart';

/// Shows whether a model is installed and lets the user import one.
/// [onInstalled] runs after a successful import (e.g. to load it).
class ModelImportTile extends ConsumerStatefulWidget {
  const ModelImportTile({super.key, required this.role, this.onInstalled});

  final ModelRole role;
  final Future<void> Function()? onInstalled;

  @override
  ConsumerState<ModelImportTile> createState() => _ModelImportTileState();
}

class _ModelImportTileState extends ConsumerState<ModelImportTile> {
  String? _stage;
  double _fraction = 0;
  String? _message;
  bool? _verified;

  Future<void> _import() async {
    final manager = await ref.read(modelManagerProvider.future);
    setState(() {
      _stage = 'Waiting for file…';
      _fraction = 0;
      _message = null;
    });
    final result = await manager.import(widget.role, onProgress: (stage, f) {
      if (mounted) {
        setState(() {
          _stage = stage == 'copy' ? 'Copying' : 'Verifying';
          _fraction = f;
        });
      }
    });
    if (!mounted) return;
    setState(() => _stage = null);
    switch (result) {
      case ImportCancelled():
        break;
      case ImportRejected(:final reason):
        setState(() => _message = reason);
      case ImportDone(:final verified):
        setState(() => _verified = verified);
        await widget.onInstalled?.call();
        if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final known = knownFor(widget.role);
    final manager = ref.watch(modelManagerProvider).value;
    final installed = manager?.installed(widget.role);
    final theme = Theme.of(context);
    final sizeMb = (known.bytes / (1 << 20)).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                installed != null ? Icons.check_circle : Icons.download_for_offline_outlined,
                color: installed != null ? Colors.green : theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(known.label, style: theme.textTheme.titleMedium),
                  Text(
                    widget.role == ModelRole.chat
                        ? 'Required · runs skills and chat · $sizeMb MB'
                        : 'Optional · notes search and skill suggestions · $sizeMb MB',
                    style: theme.textTheme.bodySmall,
                  ),
                ]),
              ),
            ]),
            if (_verified != null) ...[
              const SizedBox(height: 8),
              Text(
                _verified!
                    ? 'Verified: matches the published file.'
                    : 'Installed, but not the known file. It may still work.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: _verified! ? Colors.green : theme.colorScheme.tertiary),
              ),
            ],
            if (_stage != null) ...[
              const SizedBox(height: 12),
              Text(_stage!, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: _fraction > 0 ? _fraction : null),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _stage == null ? _import : null,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(installed != null ? 'Replace file' : 'Import .gguf file'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
