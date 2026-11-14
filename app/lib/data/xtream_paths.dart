/// A panel's stream address, as Xtream panels write them: /live/user/password/id.ts,
/// /movie/user/password/id.mkv, or the short /user/password/id of the live channels in a panel's M3U
/// export ([type] null).
typedef XtreamPath = ({String? type, String user, String password, String id, String? extension});

final _path = RegExp(r'^/(?:(live|movie|series)/)?([^/]+)/([^/]+)/(\d+)(?:\.(\w+))?$');

/// The parts of [path] (a URL's path) when it is a panel's stream; null otherwise. The one place
/// that says what such a path is: ids, casting and links all go by it.
XtreamPath? parseXtreamPath(String path) {
  final m = _path.firstMatch(path);
  return m == null ? null : (type: m[1], user: m[2]!, password: m[3]!, id: m[4]!, extension: m[5]);
}
