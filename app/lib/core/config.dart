/// Runtime limits from the SkillCraft spec, tuned for Snapdragon 680 / 8 GB.
class EngineConfig {
  const EngineConfig({
    this.threads = 4,
    this.contextTokens = 2048,
    this.temperature = 0.2,
    this.maxAgentSteps = 3,
  }) : assert(contextTokens <= maxContextTokens);

  /// Hard cap that keeps the KV cache under ~250 MB.
  static const maxContextTokens = 2048;

  /// One thread per Cortex-A73 performance core.
  final int threads;
  final int contextTokens;
  final double temperature;
  final int maxAgentSteps;
}

/// File and folder names shared across the app.
abstract final class AppPaths {
  static const defaultModelFile = 'Qwen2.5-1.5B-Instruct-Q4_K_M.gguf';
  static const embeddingModelFile = 'nomic-embed-text-v1.5.Q4_K_M.gguf';
  static const databaseFile = 'skillcraft.db';

  /// Relative to the app-specific external files dir: imported GGUF models.
  static const modelsDir = 'models';

  /// Relative to the app-specific external files dir (scoped storage).
  static const skillsDir = 'Documents/SkillCraft/skills';
}
