import 'package:flutter/material.dart';

import '../../skills/skill.dart';
import '../../skills/skill_compiler.dart';

/// A form generated from a skill's declared inputs.
class SkillInputForm extends StatefulWidget {
  const SkillInputForm({
    super.key,
    required this.skill,
    required this.onSubmit,
    this.initial = const {},
    this.problems = const [],
  });

  final Skill skill;
  final Map<String, Object?> initial;
  final List<String> problems;
  final void Function(Map<String, Object?> inputs) onSubmit;

  @override
  State<SkillInputForm> createState() => _SkillInputFormState();
}

class _SkillInputFormState extends State<SkillInputForm> {
  late final Map<String, TextEditingController> _text = {
    for (final i in widget.skill.inputs)
      if (i.type != InputType.boolean && i.enumValues == null)
        i.name: TextEditingController(
            text: '${widget.initial[i.name] ?? i.defaultValue ?? ''}'),
  };
  late final Map<String, Object?> _choice = {
    for (final i in widget.skill.inputs)
      if (i.type == InputType.boolean || i.enumValues != null)
        i.name: widget.initial[i.name] ?? i.defaultValue,
  };
  List<String> _problems = const [];

  @override
  void initState() {
    super.initState();
    _problems = widget.problems;
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final raw = <String, Object?>{
      for (final e in _text.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text,
      for (final e in _choice.entries)
        if (e.value != null) e.key: e.value,
    };
    try {
      widget.onSubmit(SkillCompiler.resolveInputs(widget.skill, raw));
    } on SkillInputException catch (e) {
      setState(() => _problems = e.problems);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 16, bottom: MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.skill.command, style: theme.textTheme.titleLarge),
            Text(widget.skill.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            for (final input in widget.skill.inputs) ...[
              _field(input),
              const SizedBox(height: 12),
            ],
            for (final p in _problems)
              Text(p, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _submit, child: const Text('Run')),
          ],
        ),
      ),
    );
  }

  Widget _field(SkillInput input) {
    final label = '${input.name}${input.required ? ' *' : ''}';
    if (input.type == InputType.boolean) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: input.description.isEmpty ? null : Text(input.description),
        value: _choice[input.name] == true,
        onChanged: (v) => setState(() => _choice[input.name] = v),
      );
    }
    if (input.enumValues != null) {
      return DropdownButtonFormField<Object?>(
        initialValue: _choice[input.name],
        decoration: InputDecoration(labelText: label, helperText: input.description),
        items: [
          for (final v in input.enumValues!) DropdownMenuItem(value: v, child: Text('$v')),
        ],
        onChanged: (v) => setState(() => _choice[input.name] = v),
      );
    }
    final numeric = input.type == InputType.number || input.type == InputType.integer;
    return TextField(
      key: ValueKey('input-${input.name}'),
      controller: _text[input.name],
      minLines: input.type == InputType.string ? 3 : 1,
      maxLines: input.type == InputType.string ? 10 : 1,
      keyboardType: numeric ? TextInputType.number : TextInputType.multiline,
      decoration: InputDecoration(
        labelText: label,
        helperText: [
          if (input.description.isNotEmpty) input.description,
          if (input.type == InputType.array || input.type == InputType.object) 'JSON',
        ].join(' · '),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
