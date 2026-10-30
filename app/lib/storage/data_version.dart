import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped after any write to tasks or notes, from the UI or from a skill's
/// tool call, so lists that watch it refresh immediately.
class DataVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final dataVersionProvider = NotifierProvider<DataVersion, int>(DataVersion.new);
