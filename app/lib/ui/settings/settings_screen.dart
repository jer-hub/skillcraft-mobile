import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../mcp/mcp_providers.dart';
import '../../mcp/tool_servers.dart';
import '../../models/model_manager.dart';
import '../../models/model_providers.dart';
import '../../settings/app_settings.dart';
import '../debug/engine_debug_screen.dart';
import '../debug/skill_debug_screen.dart';
import '../setup/model_import_tile.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final model = ref.watch(chatModelProvider);
    final servers = ref.watch(toolServersProvider);
    final controller = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final info = model.value;
    final needsReload = info != null &&
        (info.threads != settings.threads || info.contextTokens != settings.contextTokens);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _Header('Model'),
          ListTile(
            leading: const Icon(Icons.memory),
            title: Text(model.isLoading
                ? 'Loading…'
                : info == null
                    ? 'No chat model loaded'
                    : 'Loaded in ${(info.loadMs / 1000).toStringAsFixed(1)} s'),
            subtitle: Text(info == null
                ? (model.error?.toString() ?? '')
                : '${info.threads} threads · ${info.contextTokens}-token context'),
            trailing: FilledButton.tonal(
              onPressed: model.isLoading ? null : () => ref.read(chatModelProvider.notifier).reload(),
              child: Text(needsReload ? 'Apply' : 'Reload'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(children: [
              ModelImportTile(
                  role: ModelRole.chat, onInstalled: () async => ref.invalidate(chatModelProvider)),
              ModelImportTile(
                  role: ModelRole.embedding, onInstalled: () async => ref.invalidate(vectorStoreProvider)),
            ]),
          ),
          const _Header('Performance'),
          _SliderTile(
            title: 'Threads',
            value: settings.threads.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            label: '${settings.threads}',
            help: '4 uses the fast cores on Snapdragon 680. Reload to apply.',
            onChanged: (v) => controller.change((s) => s.copyWith(threads: v.round())),
          ),
          _SliderTile(
            title: 'Context window',
            value: settings.contextTokens.toDouble(),
            min: 512,
            max: EngineConfig.maxContextTokens.toDouble(),
            divisions: 6,
            label: '${settings.contextTokens} tokens',
            help: 'Smaller uses less memory but fits shorter inputs. Reload to apply.',
            onChanged: (v) => controller.change((s) => s.copyWith(contextTokens: v.round())),
          ),
          _SliderTile(
            title: 'Chat creativity',
            value: settings.chatTemperature,
            min: 0,
            max: 1.2,
            divisions: 12,
            label: settings.chatTemperature.toStringAsFixed(1),
            help: 'Plain chat only. Skills always pick the most likely answer.',
            onChanged: (v) => controller.change((s) => s.copyWith(chatTemperature: v)),
          ),
          const _Header('Tool servers'),
          for (final def in bundledToolServers)
            SwitchListTile(
              title: Text(def.id),
              subtitle: Text(_serverStatus(def, settings, servers)),
              value: !settings.disabledToolServers.contains(def.id),
              onChanged: (on) => controller.change((s) => s.copyWith(
                    disabledToolServers: on
                        ? (Set.of(s.disabledToolServers)..remove(def.id))
                        : {...s.disabledToolServers, def.id},
                  )),
            ),
          const _Header('Background'),
          const _BatteryExemptionTile(),
          const _Header('Skill suggestions'),
          _SliderTile(
            title: 'Suggestion threshold',
            value: settings.suggestThreshold,
            min: 0.4,
            max: 0.9,
            divisions: 10,
            label: settings.suggestThreshold.toStringAsFixed(2),
            help: 'How closely a plain message must match a skill before it is '
                'suggested. Needs the embedding model.',
            onChanged: (v) => controller.change((s) => s.copyWith(suggestThreshold: v)),
          ),
          const _Header('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About & licenses'),
            subtitle: Text(ref.watch(appVersionProvider).value == null
                ? 'SkillCraft'
                : 'SkillCraft ${ref.watch(appVersionProvider).value!.name}'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'SkillCraft',
              applicationVersion: ref.read(appVersionProvider).value?.name,
              applicationLegalese: 'MIT License · © 2026 Jerwin Carreon\n'
                  'Runs fully on this device. Models are downloaded separately '
                  'under their own licenses.',
            ),
          ),
          const _Header('Developer'),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Engine debug'),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const EngineDebugScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Skill debug'),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const SkillDebugScreen())),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Everything runs on this device. Nothing is sent anywhere.',
                style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  static String _serverStatus(ToolServerDef def, AppSettings settings, AsyncValue<ToolServers> servers) {
    if (settings.disabledToolServers.contains(def.id)) return 'Off';
    final s = servers.value;
    if (s == null) return servers.isLoading ? 'Starting…' : 'Not running';
    final running = s.host.servers.where((x) => x.id == def.id).firstOrNull;
    if (running != null) return running.tools.map((t) => t.name).join(', ');
    final failure = s.failures[def.id];
    return failure == null ? 'Not running' : 'Not started: $failure';
  }
}

final batteryExemptProvider =
    FutureProvider.autoDispose<bool>((ref) => ref.watch(deviceServicesProvider).isBatteryExempt());

/// "Keep runs alive in the background": some phones (e.g. vivo) stop apps
/// that work off screen; the exemption lets a run finish.
class _BatteryExemptionTile extends ConsumerStatefulWidget {
  const _BatteryExemptionTile();

  @override
  ConsumerState<_BatteryExemptionTile> createState() => _BatteryExemptionTileState();
}

class _BatteryExemptionTileState extends ConsumerState<_BatteryExemptionTile>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the system dialog: show the new state.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(batteryExemptProvider);
  }

  @override
  Widget build(BuildContext context) {
    final exempt = ref.watch(batteryExemptProvider).value;
    return ListTile(
      leading: Icon(exempt == true ? Icons.battery_charging_full : Icons.battery_alert_outlined),
      title: const Text('Keep runs alive in the background'),
      subtitle: Text(exempt == true
          ? 'On. Skill runs can finish while you use other apps.'
          : 'Off. Some phones stop SkillCraft a few minutes after you switch away '
              'during a run.'),
      trailing: exempt == true
          ? null
          : FilledButton.tonal(
              onPressed: exempt == null
                  ? null
                  : () => ref.read(deviceServicesProvider).requestBatteryExemption(),
              child: const Text('Allow'),
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                )),
      );
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.help,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final String help;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Row(children: [Expanded(child: Text(title)), Text(label)]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
          Text(help),
        ]),
      );
}
