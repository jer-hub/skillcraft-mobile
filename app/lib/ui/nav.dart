import 'package:flutter_riverpod/flutter_riverpod.dart';

enum HomeTab { chat, tasks, skills, settings }

class HomeTabController extends Notifier<HomeTab> {
  @override
  HomeTab build() => HomeTab.chat;

  void show(HomeTab tab) => state = tab;
}

final homeTabProvider = NotifierProvider<HomeTabController, HomeTab>(HomeTabController.new);

/// Text to place in the chat composer (e.g. "/capture-tasks " from the
/// skill editor's Run button). The composer consumes and clears it.
class ComposerDraft extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String text) => state = text;
  void clear() => state = null;
}

final composerDraftProvider = NotifierProvider<ComposerDraft, String?>(ComposerDraft.new);
