/// Follows JSON as the model streams it, to catch repetition loops and to
/// recover a valid prefix if generation stops before the document closes.
///
/// The grammar guarantees the *shape* of every token, but not that the model
/// ever stops: a 1.5B model can repeat the same array item until it hits the
/// token limit, which leaves an unterminated document.
class JsonStreamScanner {
  /// Consecutive identical array items that count as a loop.
  JsonStreamScanner({this.loopRepeats = 3});

  final int loopRepeats;

  final _text = StringBuffer();
  final _stack = <_Frame>[];
  final _safePoints = <({int cut, String closers})>[];
  bool _inString = false;
  bool _escape = false;
  int _pos = 0;
  String? _lastItem;
  int _sameCount = 0;
  bool _complete = false;

  /// Safe point recorded at the last array comma (just after an item).
  int? _lastCommaSafe;

  /// Safe point that keeps one copy of the item that started repeating.
  int? _beforeRepeat;

  String get text => _text.toString();

  /// The top-level value has been closed.
  bool get isComplete => _complete;

  /// The same array item appeared [loopRepeats] times in a row.
  bool get isLooping => _sameCount >= loopRepeats;

  void add(String chunk) {
    _text.write(chunk);
    final all = _text.toString();
    for (; _pos < all.length; _pos++) {
      _step(all, _pos);
    }
  }

  /// Valid-JSON candidates built from prefixes that end on an item boundary,
  /// latest (most complete) first. Empty if nothing usable streamed yet.
  ///
  /// After a loop, only prefixes up to the first repeat are offered, so the
  /// repeated item is kept once.
  List<String> salvageCandidates() {
    final all = _text.toString();
    final limit = isLooping && _beforeRepeat != null ? _beforeRepeat! + 1 : _safePoints.length;
    return [
      for (final p in _safePoints.take(limit).toList().reversed)
        all.substring(0, p.cut).trimRight() + p.closers,
    ];
  }

  void _step(String all, int i) {
    final c = all[i];
    if (_inString) {
      if (_escape) {
        _escape = false;
      } else if (c == r'\') {
        _escape = true;
      } else if (c == '"') {
        _inString = false;
      }
      return;
    }
    switch (c) {
      case '"':
        _inString = true;
      case '{' || '[':
        _stack.add(_Frame(c, i + 1));
        // An array may always be closed right after it opens: "[]".
        if (c == '[') _recordSafe(i + 1);
      case ',':
        final top = _stack.lastOrNull;
        if (top != null && top.open == '[') {
          if (_item(all.substring(top.itemStart, i)) == 2) {
            // First duplicate: the previous comma kept exactly one copy.
            _beforeRepeat ??= _lastCommaSafe;
          }
          // Cutting before the comma keeps every finished item.
          _recordSafe(i);
          _lastCommaSafe = _safePoints.length - 1;
          top.itemStart = i + 1;
        }
      case '}' || ']':
        if (_stack.isEmpty) return;
        final closed = _stack.removeLast();
        if (closed.open == '[') {
          final last = all.substring(closed.itemStart, i).trim();
          if (last.isNotEmpty && _item(last) == 2) _beforeRepeat ??= _lastCommaSafe;
        }
        if (_stack.isEmpty) {
          _complete = true;
        } else if (_stack.last.open == '[') {
          // A whole item just finished inside an array.
          _recordSafe(i + 1);
        }
    }
  }

  /// Records a finished array item; returns how many times in a row it has
  /// now been seen (0 for empty).
  int _item(String raw) {
    final item = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (item.isEmpty) return 0;
    if (item == _lastItem) {
      _sameCount++;
    } else {
      _lastItem = item;
      _sameCount = 1;
      _beforeRepeat = null; // a new item breaks any earlier run of repeats
    }
    return _sameCount;
  }

  void _recordSafe(int cut) {
    final closers = StringBuffer();
    for (final f in _stack.reversed) {
      closers.write(f.open == '{' ? '}' : ']');
    }
    _safePoints.add((cut: cut, closers: closers.toString()));
  }
}

class _Frame {
  _Frame(this.open, this.itemStart);
  final String open;
  int itemStart;
}
