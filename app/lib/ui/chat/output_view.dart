import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Renders skill output: arrays of objects as item cards, scalars as rows,
/// anything else as indented JSON. Always offers "Copy JSON".
class OutputView extends StatelessWidget {
  const OutputView(this.output, {super.key});

  final Object? output;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final json = const JsonEncoder.withIndent('  ').convert(output);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._sections(context, output),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy JSON'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
        ),
        if (output is! Map)
          SelectableText(json, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
      ],
    );
  }

  List<Widget> _sections(BuildContext context, Object? value) {
    if (value is! Map) return const [];
    final theme = Theme.of(context);
    return [
      for (final MapEntry(:key, :value) in value.entries)
        if (value is List && value.every((v) => v is Map)) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text('${_label(key.toString())} (${value.length})',
                style: theme.textTheme.labelLarge),
          ),
          if (value.isEmpty) Text('None', style: theme.textTheme.bodySmall),
          for (final item in value.cast<Map>()) _ItemCard(item),
        ] else
          _FieldRow(_label(key.toString()), value),
    ];
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard(this.item);
  final Map item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = item.entries.toList();
    // Lead with a title-like field when there is one.
    final titleIdx = entries.indexWhere((e) => const ['title', 'name', 'text'].contains(e.key));
    final title = titleIdx >= 0 ? entries.removeAt(titleIdx).value : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) Text('$title', style: theme.textTheme.bodyLarge),
            if (entries.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final e in entries)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${_label(e.key.toString())}: ${_scalar(e.value)}',
                          style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow(this.label, this.value);
  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: _scalar(value)),
        ])),
      );
}

String _label(String key) =>
    key.replaceAll('_', ' ').replaceFirstMapped(RegExp('^.'), (m) => m[0]!.toUpperCase());

String _scalar(Object? v) => v is String ? v : jsonEncode(v);
