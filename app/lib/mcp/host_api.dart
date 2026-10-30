import 'dart:async';

import '../storage/database.dart';
import '../storage/vector_store.dart';

/// A function a tool script can reach through `__host(name, payload)`.
typedef HostFunction = FutureOr<Object?> Function(Map<String, Object?> payload);

/// Host functions granted to one tool server. A server only sees the
/// capabilities it is registered with, e.g. the calendar server gets no SQL.
class HostApi {
  HostApi(this.functions);

  final Map<String, HostFunction> functions;

  Future<Object?> call(String name, Object? payload) async {
    final fn = functions[name];
    if (fn == null) throw StateError('Host function "$name" is not available');
    return fn(payload is Map ? payload.cast<String, Object?>() : const {});
  }
}

/// `host.sql.query` / `host.sql.execute` against the app database.
/// [onWrite] runs after each `sql.execute` that changed rows, so the UI can
/// refresh when a skill saves something.
Map<String, HostFunction> sqlFunctions(AppDatabase db, {void Function()? onWrite}) => {
      'sql.query': (p) => db.query(_sql(p), _params(p)),
      'sql.execute': (p) {
        final r = db.execute(_sql(p), _params(p));
        if (r.changes > 0) onWrite?.call();
        return {'changes': r.changes, 'lastInsertRowId': r.lastInsertRowId};
      },
    };

/// `host.vec.remember` / `host.vec.search` over a [VectorStore].
Map<String, HostFunction> vectorFunctions(VectorStore store) => {
      'vec.remember': (p) async {
        final text = p['text'];
        if (text is! String) throw ArgumentError('text is required');
        return {'id': await store.remember(text)};
      },
      'vec.search': (p) async {
        final query = p['query'];
        if (query is! String) throw ArgumentError('query is required');
        final k = p['k'];
        final hits = await store.search(query, k: k is num ? k.toInt() : 5);
        return [for (final h in hits) h.toJson()];
      },
    };

/// `console.log` from scripts.
Map<String, HostFunction> logFunctions(void Function(String line) sink) => {
      'log': (p) {
        sink(p['message']?.toString() ?? '');
        return null;
      },
    };

String _sql(Map<String, Object?> p) {
  final sql = p['sql'];
  if (sql is! String || sql.trim().isEmpty) throw ArgumentError('sql is required');
  return sql;
}

List<Object?> _params(Map<String, Object?> p) {
  final params = p['params'] ?? const [];
  if (params is! List) throw ArgumentError('params must be a list');
  for (final v in params) {
    if (v != null && v is! String && v is! num && v is! bool) {
      throw ArgumentError('params may only hold strings, numbers, booleans or null');
    }
  }
  return params;
}
