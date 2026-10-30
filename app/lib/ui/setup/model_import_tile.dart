import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/model_manager.dart';
import '../../models/model_providers.dart';

/// Shows whether a model is installed and lets the user download or import
/// one. [onInstalled] runs after a successful install (e.g. to load it).
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
  DownloadControl? _download;

  bool get _busy => _stage != null;

  void _progress(String stage, double f) {
    if (!mounted) return;
    setState(() {
      _stage = switch (stage) {
        'copy' => 'Copying',
        'download' => 'Downloading',
        _ => 'Verifying',
      };
      _fraction = f;
    });
  }

  Future<void> _import() async {
    final manager = await ref.read(modelManagerProvider.future);
    setState(() {
      _stage = 'Waiting for file…';
      _fraction = 0;
      _message = null;
    });
    final result = await manager.import(widget.role, onProgress: _progress);
    if (!mounted) return;
    setState(() => _stage = null);
    switch (result) {
      case ImportCancelled():
        break;
      case ImportRejected(:final reason):
        setState(() => _message = reason);
      case ImportDone(:final verified):
        await _installed(verified: verified);
    }
  }

  Future<void> _startDownload() async {
    final manager = await ref.read(modelManagerProvider.future);
    final device = ref.read(deviceServicesProvider);
    final known = knownFor(widget.role);
    final left = known.bytes - manager.partialDownload(widget.role);
    if (await _quietly(device.isMeteredNetwork, fallback: false) && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Download on mobile data?'),
          content: Text('This needs ${_mb(left)} MB. Wi-Fi is recommended.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;

    final control = DownloadControl();
    setState(() {
      _download = control;
      _stage = 'Connecting…';
      _fraction = manager.partialDownload(widget.role) / known.bytes;
      _message = null;
    });
    // Keep it going off screen, with Pause on the notification.
    await _quietly(() => device.setKeepScreenOn(true));
    await _quietly(() => device.startRun('the ${_mb(known.bytes)} MB model download'));
    final stops = device.stopRequests.listen((_) => control.pause());
    final DownloadResult result;
    try {
      result = await manager.download(widget.role, onProgress: _progress, control: control);
    } finally {
      await stops.cancel();
      await _quietly(device.stopRun);
      await _quietly(() => device.setKeepScreenOn(false));
    }
    if (!mounted) return;
    setState(() {
      _stage = null;
      _download = null;
    });
    switch (result) {
      case DownloadDone():
        await _installed(verified: true);
      case DownloadStopped():
        break;
      case DownloadFailed(:final reason):
        setState(() => _message = reason);
    }
  }

  Future<void> _discardPartial() async {
    await (await ref.read(modelManagerProvider.future)).discardPartialDownload(widget.role);
    if (mounted) setState(() {});
  }

  Future<void> _installed({required bool verified}) async {
    setState(() => _verified = verified);
    await widget.onInstalled?.call();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final known = knownFor(widget.role);
    final manager = ref.watch(modelManagerProvider).value;
    final installed = manager?.installed(widget.role);
    final partial = _busy ? 0 : (manager?.partialDownload(widget.role) ?? 0);
    final theme = Theme.of(context);
    final sizeMb = _mb(known.bytes);
    final downloading = _download != null;

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
            if (_busy) ...[
              const SizedBox(height: 12),
              Text(
                _stage == 'Downloading'
                    ? 'Downloading ${_amount((known.bytes * _fraction).round())} of $sizeMb MB'
                    : _stage!,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: _fraction > 0 ? _fraction : null),
            ] else if (partial > 0) ...[
              const SizedBox(height: 12),
              Text('Paused at ${_amount(partial)} of $sizeMb MB', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: partial / known.bytes),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (downloading) ...[
                  TextButton(onPressed: _download!.cancel, child: const Text('Cancel')),
                  FilledButton.tonalIcon(
                    onPressed: _stage == 'Downloading' ? _download!.pause : null,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                ] else ...[
                  if (partial > 0)
                    TextButton(onPressed: _busy ? null : _discardPartial, child: const Text('Discard')),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(installed != null ? 'Replace file' : 'Import file'),
                  ),
                  if (installed == null)
                    FilledButton.icon(
                      onPressed: _busy ? null : _startDownload,
                      icon: const Icon(Icons.download),
                      label: Text(partial > 0 ? 'Resume' : 'Download ($sizeMb MB)'),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

int _mb(int bytes) => (bytes / (1 << 20)).round();

/// Device helpers are best effort; a download works without them.
Future<T> _quietly<T>(Future<T> Function() call, {T? fallback}) async {
  try {
    return await call();
  } catch (_) {
    return fallback as T;
  }
}

/// Megabytes done so far: one decimal while small, so a pause right after
/// starting does not read as "0 MB".
String _amount(int bytes) {
  final mb = bytes / (1 << 20);
  return mb < 10 ? mb.toStringAsFixed(1) : mb.round().toString();
}
