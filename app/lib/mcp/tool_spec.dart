/// A tool as advertised by MCP `tools/list`.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;

  /// JSON Schema for the tool's `arguments`.
  final Map<String, Object?> inputSchema;
}
