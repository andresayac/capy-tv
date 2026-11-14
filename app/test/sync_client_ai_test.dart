// The sync server's language model, as the app asks for it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/sync/sync_client.dart';

void main() {
  final server = Uri.parse('https://sync.example/');

  test('which model the server offers, or none', () async {
    SyncClient with_(int status, Object body) => SyncClient(
      server,
      token: 't',
      client: MockClient((req) async {
        expect(req.url.path, '/v1/ai');
        expect(req.headers['authorization'], 'Bearer t');
        return http.Response(jsonEncode(body), status);
      }),
    );
    expect(await with_(200, {'model': 'family-model'}).aiModel(), 'family-model');
    expect(await with_(404, {'error': 'no_ai'}).aiModel(), isNull);
    expect(() => with_(401, {'error': 'auth'}).aiModel(), throwsA(isA<SyncException>()));
  });

  test("asks the server's model, which picks neither model nor key here", () async {
    late Map<String, dynamic> sent;
    final client = SyncClient(
      server,
      token: 't',
      client: MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/v1/ai/chat');
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'content': '{"picks":[]}'}), 200);
      }),
    );
    final answer = await client.aiChat([
      {'role': 'user', 'content': 'Watched: Ozark'},
    ], json: true);
    expect(answer, '{"picks":[]}');
    expect(sent, {
      'messages': [
        {'role': 'user', 'content': 'Watched: Ozark'},
      ],
      'json': true,
    });
  });
}
