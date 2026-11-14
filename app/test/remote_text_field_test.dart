// Forms with a TV remote: one field at a time, its keyboard alone (TV keyboards confuse fields when
// focus moves between them with the keyboard up).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/remote/remote_input.dart';
import 'package:iptv_player/ui/remote_text_field.dart';
import 'package:iptv_player/ui/theme.dart';

void main() {
  final server = TextEditingController(), email = TextEditingController(), password = TextEditingController();
  var submitted = 0;

  Future<void> form(WidgetTester t) => t.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Form(
          child: Column(
            children: [
              RemoteTextFormField(
                controller: server,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Server'),
              ),
              RemoteTextFormField(
                controller: email,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              RemoteTextFormField(
                controller: password,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => submitted++,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  setUp(() {
    server.text = 'https://sync.example.com';
    email.clear();
    password.clear();
    submitted = 0;
  });
  tearDown(() => isTv = false);

  testWidgets('on a TV: OK opens the field alone; what is typed goes in, and on to the next', (t) async {
    isTv = true;
    await form(t);
    expect(find.byType(TextField), findsNothing, reason: 'no keyboard by moving onto a field');
    expect(find.text('https://sync.example.com'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // to the email field
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget, reason: 'one field, its keyboard alone');
    await t.enterText(find.byType(TextField), 'ana@example.com');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(email.text, 'ana@example.com');
    expect(find.text('ana@example.com'), findsOneWidget);
    expect(server.text, 'https://sync.example.com', reason: 'the field above untouched');

    // Focus went on to the password: OK, type, done submits as the keyboard's done does
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'secret');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(password.text, 'secret');
    expect(find.text('••••••'), findsOneWidget, reason: 'shown hidden');
    expect(submitted, 1);
  });

  testWidgets('on a TV, typed on the phone with a field focused, it goes in that field', (t) async {
    isTv = true;
    await form(t);
    await t.pump();
    remoteSearch.text = '';
    expect(typeRemoteText('https://other.example'), isTrue);
    await t.pump();
    expect(server.text, 'https://other.example', reason: 'the focused field, not a search behind the form');
    expect(remoteSearch.text, isEmpty);
    // A password's field takes no text that came unsealed
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(typeRemoteText('secret', sealed: false), isFalse);
    expect(password.text, isEmpty);
  });

  testWidgets('elsewhere, plain fields', (t) async {
    await form(t);
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets('on a TV the label of a field shows whole inside its focus ring', (t) async {
    isTv = true;
    await form(t);
    final label = t.getRect(find.text('Server'));
    final ring = t.getRect(find.ancestor(of: find.text('Server'), matching: find.byType(ClipRRect)).first);
    expect(ring.contains(label.topLeft) && ring.contains(label.bottomRight), isTrue, reason: '$label in $ring');
  });
}
