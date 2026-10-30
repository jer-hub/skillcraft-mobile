// Renders the legacy (pre-Android 8) launcher PNGs from the same bolt path as
// res/drawable/ic_launcher_foreground.xml. Android 8+ uses that adaptive
// vector icon instead.
//
//   flutter test tool/icon/render_icon.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _teal = Color(0xFF00796B);
const _res = 'android/app/src/main/res';
const _sizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};

/// The bolt on a 24x24 grid (same points as the vector drawable).
Path _bolt() => Path()
  ..moveTo(13, 2)
  ..lineTo(4.5, 13.5)
  ..lineTo(11, 13.5)
  ..lineTo(10, 22)
  ..lineTo(19.5, 10.5)
  ..lineTo(13, 10.5)
  ..close();

Future<List<int>> _render(int px) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = px.toDouble();
  // Rounded square like most legacy launchers expect.
  canvas.drawRRect(
    RRect.fromRectAndRadius(Offset.zero & Size(size, size), Radius.circular(size * 0.22)),
    Paint()..color = _teal,
  );
  // Legacy icons have no safe zone, so the bolt can be larger than in the
  // adaptive icon: 60% of the icon, centred.
  final scale = size * 0.6 / 24;
  canvas
    ..translate((size - 24 * scale) / 2, (size - 24 * scale) / 2)
    ..scale(scale)
    ..drawPath(_bolt(), Paint()..color = Colors.white..isAntiAlias = true);
  final image = await recorder.endRecording().toImage(px, px);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  testWidgets('render legacy launcher icons', (tester) async {
    await tester.runAsync(() async {
      for (final MapEntry(key: density, value: px) in _sizes.entries) {
        File('$_res/mipmap-$density/ic_launcher.png').writeAsBytesSync(await _render(px));
      }
    });
  });
}
