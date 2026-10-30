import '../inference/llama_engine.dart';
import '../skills/skill.dart';
import '../storage/vector_store.dart';

typedef SkillMatch = ({Skill skill, double score});

/// Finds the skill whose name and description best match a free-text
/// message, using the on-device embedding model.
class SkillMatcher {
  SkillMatcher(this._embedder, {this.profile = const EmbeddingProfile()});

  final EmbeddingEngine _embedder;
  final EmbeddingProfile profile;

  /// Skill vectors keyed by file contents, so edits are re-embedded.
  final _cache = <String, List<double>>{};

  /// The best match with its cosine similarity, or null if [skills] is empty.
  Future<SkillMatch?> best(String message, List<Skill> skills) async {
    if (skills.isEmpty || message.trim().isEmpty) return null;
    final query = await _embedder.embed('${profile.queryPrefix}${message.trim()}');
    SkillMatch? top;
    for (final skill in skills) {
      final vector = _cache[skill.source] ??= await _embedder
          .embed('${profile.documentPrefix}${describe(skill)}');
      final score = _dot(query, vector);
      if (top == null || score > top.score) top = (skill: skill, score: score);
    }
    return top;
  }

  /// "capture tasks: Extracts actionable tasks ..." — what gets embedded.
  static String describe(Skill skill) =>
      '${skill.name.replaceAll('-', ' ')}: ${skill.description}';

  /// Vectors are unit length, so the dot product is the cosine.
  static double _dot(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
