import 'dart:async';

import '../storage/database.dart';

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
Map<String, HostFunction> sqlFunctions(AppDatabase db) => {
      'sql.query': (p) => db.query(_sql(p), _params(p)),
      'sql.execute': (p) {
        final r = db.execute(_sql(p), _params(p));
        return {'changes': r.changes, 'lastInsertRowId': r.lastInsertRowId};
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
