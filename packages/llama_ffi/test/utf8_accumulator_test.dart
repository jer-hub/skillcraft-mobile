import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_ffi/src/utf8_accumulator.dart';

void main() {
  test('passes ASCII straight through', () {
    final acc = Utf8Accumulator();
    expect(acc.add(utf8.encode('hello')), 'hello');
    expect(acc.close(), '');
  });

  test('holds back a code point split across pieces', () {
    final bytes = utf8.encode('a😀b'); // emoji is 4 bytes
    final acc = Utf8Accumulator();
    expect(acc.add(bytes.sublist(0, 2)), 'a');
    expect(acc.add(bytes.sublist(2, 4)), '');
    expect(acc.add(bytes.sublist(4)), '😀b');
  });

  test('reassembles any byte-wise split', () {
    const text = 'Gawain: ayusin ang ulat 📋 — 截止日期 Biyernes';
    final bytes = utf8.encode(text);
    final acc = Utf8Accumulator();
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(acc.add([b]));
    }
    out.write(acc.close());
    expect(out.toString(), text);
  });

  test('close flushes a dangling partial sequence as U+FFFD', () {
    final acc = Utf8Accumulator();
    expect(acc.add([0xE2, 0x82]), '');
    expect(acc.close(), '�');
  });
}
