import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/inference/chat_template.dart';

void main() {
  test('renders ChatML and opens the assistant turn', () {
    final prompt = QwenChatTemplate.render(const [
      ChatMessage.system('You extract tasks.'),
      ChatMessage.user('Call Ana by Friday.'),
    ]);

    expect(
      prompt,
      '<|im_start|>system\nYou extract tasks.<|im_end|>\n'
      '<|im_start|>user\nCall Ana by Friday.<|im_end|>\n'
      '<|im_start|>assistant\n',
    );
  });

  test('wraps tool results the way Qwen2.5 expects', () {
    final prompt = QwenChatTemplate.render(
      const [
        ChatMessage.assistant('{"type":"tool_call"}'),
        ChatMessage.tool('Saved'),
      ],
      addGenerationPrompt: false,
    );

    expect(
      prompt,
      '<|im_start|>assistant\n{"type":"tool_call"}<|im_end|>\n'
      '<|im_start|>user\n<tool_response>\nSaved\n</tool_response><|im_end|>\n',
    );
  });
}
