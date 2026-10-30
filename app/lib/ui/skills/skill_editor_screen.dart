import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../skills/skill_parser.dart';
import '../../skills/skill_providers.dart';
import '../nav.dart';

const newSkillTemplate = '''---
name: my-skill
description: Says what this skill does in one sentence.
inputs:
  text:
    type: string
    description: The text to work on.
    required: true
output_schema:
  type: object
  properties:
    result:
      type: string
  required: [result]
---

# Instructions
1. Read the `text` input.
2. Describe the steps the model should follow.
3. Output the result strictly matching the declared `output_schema`.
''';

/// Markdown + YAML editor with live validation against the skill parser.
class SkillEditorScreen extends ConsumerStatefulWidget {
  const SkillEditorScreen({super.key, required this.fileName, required this.source, this.isNew = false});

  final String fileName;
  final String source;
  final bool isNew;

  @override
  ConsumerState<SkillEditorScreen> createState() => _SkillEditorScreenState();
}

class _SkillEditorScreenState extends ConsumerState<SkillEditorScreen> {
  late final _text = TextEditingController(text: widget.source);
  late String _fileName = widget.fileName;
  List<SkillIssue> _issues = const [];
  String? _skillName;
  Timer? _debounce;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _validate();
    _text.addListener(() {
      _dirty = true;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), _validate);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _validate() {
    if (!mounted) return;
    setState(() {
      try {
        _skillName = parseSkill(_text.text).name;
        _issues = const [];
      } on SkillFormatException catch (e) {
        _issues = e.issues;
        _skillName = null;
      }
    });
  }

  /// Saves even when invalid (work is never lost). Returns true on success.
  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      final repo = await ref.read(skillRepositoryProvider.future);
      // A new skill is named after its `name:` once it is valid.
      if (widget.isNew && _skillName != null && _fileName != '$_skillName.md') {
        _fileName = '$_skillName.md';
      }
      await repo.save(_fileName, _text.text);
      _dirty = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_issues.isEmpty ? 'Saved $_fileName' : 'Saved with ${_issues.length} problem(s)')));
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _run() async {
    if (!await _save() || _skillName == null || !mounted) return;
    ref.read(composerDraftProvider.notifier).set('/$_skillName ');
    ref.read(homeTabProvider.notifier).show(HomeTab.chat);
    Navigator.of(context).pop();
  }

  void _jumpTo(int line) {
    final lines = _text.text.split('\n');
    var offset = 0;
    for (var i = 0; i < line - 1 && i < lines.length; i++) {
      offset += lines[i].length + 1;
    }
    _text.selection = TextSelection.collapsed(offset: offset.clamp(0, _text.text.length));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valid = _issues.isEmpty;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Discard changes?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          _dirty = false;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_fileName),
          actions: [
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.save_outlined),
              onPressed: _saving ? null : _save,
            ),
            IconButton(
              tooltip: 'Save and run',
              icon: const Icon(Icons.play_arrow),
              onPressed: _saving || !valid ? null : _run,
            ),
          ],
        ),
        body: Column(
          children: [
            Material(
              color: valid ? theme.colorScheme.secondaryContainer : theme.colorScheme.errorContainer,
              child: valid
                  ? ListTile(
                      dense: true,
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text('Valid skill: /$_skillName'),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final issue in _issues)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.error_outline),
                              title: Text(issue.message),
                              trailing: issue.line == null ? null : Text('line ${issue.line}'),
                              onTap: issue.line == null ? null : () => _jumpTo(issue.line!),
                            ),
                        ],
                      ),
                    ),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('skill-source'),
                controller: _text,
                expands: true,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
