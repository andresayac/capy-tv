import 'dart:async';

/// A response body that sends [piece] and then goes quiet, until whoever reads it stops listening.
class StalledBody {
  StalledBody(List<int> piece) {
    final body = StreamController<List<int>>();
    body.onListen = () {
      body.add(piece);
      listening.complete();
    };
    body.onCancel = () => dropped.complete();
    stream = body.stream;
  }

  final listening = Completer<void>(), dropped = Completer<void>();
  late final Stream<List<int>> stream;
}
