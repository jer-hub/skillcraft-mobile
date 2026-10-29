import 'dart:convert';

/// Decodes UTF-8 arriving in arbitrary byte chunks.
///
/// llama.cpp token pieces are byte sequences that can split a multi-byte code
/// point across tokens (common for emoji and CJK). Bytes of an incomplete
/// trailing sequence are held back until the rest arrives.
class Utf8Accumulator {
  final List<int> _pending = [];

  /// Adds [bytes] and returns the text that is now complete (maybe empty).
  String add(List<int> bytes) {
    _pending.addAll(bytes);
    final complete = _pending.length - _incompleteTail(_pending);
    if (complete == 0) return '';
    final text = utf8.decode(_pending.sublist(0, complete), allowMalformed: true);
    _pending.removeRange(0, complete);
    return text;
  }

  /// Flushes any held-back bytes (malformed ones become U+FFFD).
  String close() {
    if (_pending.isEmpty) return '';
    final text = utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    return text;
  }

  /// Length of an unfinished multi-byte sequence at the end of [b], else 0.
  static int _incompleteTail(List<int> b) {
    // Walk back over at most 3 continuation bytes to the lead byte.
    for (var i = 1; i <= 4 && i <= b.length; i++) {
      final byte = b[b.length - i];
      if (byte & 0xC0 == 0x80) continue; // continuation byte
      final needed = byte >= 0xF0
          ? 4
          : byte >= 0xE0
              ? 3
              : byte >= 0xC0
                  ? 2
                  : 1;
      return needed > i ? i : 0;
    }
    return 0;
  }
}
