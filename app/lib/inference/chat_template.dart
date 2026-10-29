/// Roles understood by the Qwen2.5 ChatML template.
enum ChatRole { system, user, assistant, tool }

class ChatMessage {
  const ChatMessage(this.role, this.content);

  const ChatMessage.system(this.content) : role = ChatRole.system;
  const ChatMessage.user(this.content) : role = ChatRole.user;
  const ChatMessage.assistant(this.content) : role = ChatRole.assistant;
  const ChatMessage.tool(this.content) : role = ChatRole.tool;

  final ChatRole role;
  final String content;
}

/// Builds Qwen2.5-Instruct ChatML prompts.
///
/// Tool results are wrapped in `<tool_response>` inside a user turn, which is
/// how Qwen2.5's own template renders the `tool` role.
abstract final class QwenChatTemplate {
  static const imStart = '<|im_start|>';
  static const imEnd = '<|im_end|>';

  /// Renders [messages] and, by default, opens the assistant turn so the model
  /// continues from there.
  static String render(
    List<ChatMessage> messages, {
    bool addGenerationPrompt = true,
  }) {
    final b = StringBuffer();
    for (final m in messages) {
      switch (m.role) {
        case ChatRole.tool:
          b.write('${imStart}user\n<tool_response>\n${m.content}\n'
              '</tool_response>$imEnd\n');
        case ChatRole.system || ChatRole.user || ChatRole.assistant:
          b.write('$imStart${m.role.name}\n${m.content}$imEnd\n');
      }
    }
    if (addGenerationPrompt) b.write('${imStart}assistant\n');
    return b.toString();
  }
}
