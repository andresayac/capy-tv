// Install links: a short code from the sync server for a device with no session (a Fire TV with
// Downloader), and the dialog that shows it.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/sync/sync_client.dart';
import 'package:iptv_player/ui/install_link_dialog.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  final server = Uri.parse('https://sync.example/');

  group('the client', () {
    SyncClient answering(int status, Object body) => SyncClient(
      server,
      token: 't',
      client: MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/v1/app/link');
        expect(req.headers['authorization'], 'Bearer t');
        return http.Response(jsonEncode(body), status);
      }),
    );

    test('a code and when it ends', () async {
      final link = await answering(201, {'code': 'K7Q3X', 'expires': '2026-11-06T12:30:00.000Z'}).appLink();
      expect(link!.code, 'K7Q3X');
      expect(link.expires, DateTime.utc(2026, 11, 6, 12, 30));
    });

    test('none when the server has no release; other problems said', () async {
      expect(await answering(404, {'error': 'no_app'}).appLink(), isNull);
      expect(
        () => answering(429, {'error': 'rate_limited'}).appLink(),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.rateLimited)),
      );
      expect(
        () => answering(401, {'error': 'auth'}).appLink(),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.signedOut)),
      );
    });

    test("the page is on the server, under its path too, typed without the scheme", () {
      expect(SyncClient(server).installPage('K7Q3X').toString(), 'https://sync.example/i/K7Q3X');
      final under = SyncClient(Uri.parse('https://example.org/sync/')).installPage('K7Q3X');
      expect(under.toString(), 'https://example.org/sync/i/K7Q3X');
      expect(InstallLinkDialog.typed(under), 'example.org/sync/i/K7Q3X');
      expect(InstallLinkDialog.typed(Uri.parse('http://192.168.1.20:8080/i/K7Q3X')), '192.168.1.20:8080/i/K7Q3X');
    });
  });

  group('the dialog', () {
    Future<void> open(
      WidgetTester t,
      Future<InstallLink?> Function() request, {
      Locale locale = const Locale('en'),
      Size size = const Size(1280, 720), // landscape, as phones and TVs run it
    }) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InstallLinkDialog(request: request),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump();
    }

    testWidgets('the address to type, big, its QR, and Close with the focus', (t) async {
      final answer = Completer<InstallLink?>();
      await open(t, () => answer.future);
      expect(find.text('Install on another device'), findsOneWidget);
      expect(find.text('Getting a link…'), findsOneWidget);

      answer.complete((
        address: Uri.parse('https://sync.example/i/K7Q3X'),
        expires: DateTime.now().add(const Duration(minutes: 30)),
      ));
      await t.pumpAndSettle();
      expect(find.text('Getting a link…'), findsNothing);
      expect(find.text('In Downloader on the Fire TV, type this address'), findsOneWidget);
      final address = t.widget<Text>(find.text('sync.example/i/K7Q3X'));
      expect(address.style!.fontSize, greaterThanOrEqualTo(28));
      expect(find.text('Valid for 30 minutes'), findsOneWidget);
      expect(t.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel, 'https://sync.example/i/K7Q3X');
      expect(t.takeException(), isNull); // fits

      // A remote's OK closes it
      expect(Focus.of(t.element(find.text('Close'))).hasFocus, isTrue);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.byType(InstallLinkDialog), findsNothing);
    });

    testWidgets('fits a phone lying down, with a long address', (t) async {
      await open(
        t,
        () async => (
          address: Uri.parse('https://sync.a-rather-long-family-domain.example/i/K7Q3X'),
          expires: DateTime.now().add(const Duration(minutes: 30)),
        ),
        size: const Size(740, 360),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('sync.a-rather-long-family-domain.example/i/K7Q3X'), findsOneWidget);
    });

    testWidgets('a server without the app, said in words', (t) async {
      await open(t, () async => null);
      await t.pumpAndSettle();
      expect(find.textContaining('no copy of the app'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(Focus.of(t.element(find.text('Close'))).hasFocus, isTrue);
    });

    testWidgets('offline, said in words', (t) async {
      await open(t, () async => throw const SyncException(SyncProblem.network));
      await t.pumpAndSettle();
      expect(find.text("Can't reach the sync server"), findsOneWidget);
    });

    testWidgets('in Spanish', (t) async {
      await open(
        t,
        () async => (
          address: Uri.parse('https://sync.example/i/K7Q3X'),
          expires: DateTime.now().add(const Duration(minutes: 30)),
        ),
        locale: const Locale('es'),
      );
      await t.pumpAndSettle();
      expect(find.text('Instalar en otro dispositivo'), findsOneWidget);
      expect(find.text('Válido durante 30 minutos'), findsOneWidget);
      expect(find.text('Cerrar'), findsOneWidget);
    });
  });
}
