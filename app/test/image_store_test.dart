// Images: the disk before the line, a few at a time, what is on screen first, and what each kind of
// device may spend on them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/image_store.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/device.dart';

const _a = 'http://posters.test/a.jpg', _b = 'http://posters.test/b.jpg', _c = 'http://posters.test/c.jpg';

/// Waits for what is already under way, disk included, to get as far as it can.
// Also between what a test starts one after another: each image looks on the disk first, and
// either may finish first and take the place
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  late Directory dir;
  late List<String> asked;
  late Map<String, Completer<http.StreamedResponse>> held;
  var now = Duration.zero;

  setUp(() {
    now = Duration.zero;
    dir = Directory.systemTemp.createTempSync('images');
    asked = [];
    held = {};
  });
  tearDown(() async {
    lowMemory = false;
    memoryMb = null;
    await settle(); // what was being written
    dir.deleteSync(recursive: true);
  });

  http.StreamedResponse ok(String body) => http.StreamedResponse(Stream.value(utf8.encode(body)), 200);

  /// A store whose server answers each image with its own address, or holds those in [hold].
  ImageStore store({Set<String> hold = const {}, int downloads = 6, int disk = 1 << 20, int status = 200}) =>
      ImageStore(
          client: MockClient.streaming((request, _) {
            final url = request.url.toString();
            asked.add(url);
            if (hold.contains(url)) return (held[url] = Completer()).future;
            return Future.value(status == 200 ? ok(url) : http.StreamedResponse(const Stream.empty(), status));
          }),
          directory: () async => dir,
          elapsed: () => now,
        )
        ..maxDownloads = downloads
        ..diskBytes = disk;

  String text(Uint8List bytes) => utf8.decode(bytes);

  test('an image seen before comes from the disk, not the line, the next time the app starts', () async {
    final first = store()..want(_a);
    expect(text(await first.bytes(_a)), _a);
    await settle();
    expect(asked, [_a]);

    final second = store()..want(_a);
    expect(text(await second.bytes(_a)), _a);
    expect(asked, [_a], reason: 'kept on disk');
  });

  test('with no room for images any more, those kept on earlier days go too', () async {
    final first = store()..want(_a);
    expect(text(await first.bytes(_a)), _a);
    await settle();
    expect(dir.listSync(), isNotEmpty);

    final low = store(disk: 0)..want(_b); // the next start, with the disk nearly full
    expect(text(await low.bytes(_b)), _b, reason: 'still shown');
    await settle();
    expect(dir.listSync().whereType<File>().where((f) => f.lengthSync() > 0), isEmpty);
  });

  test('a device with no room for images keeps none, and still shows them', () async {
    final s = store(disk: 0)..want(_a);
    expect(text(await s.bytes(_a)), _a);
    await settle();
    expect(dir.listSync(), isEmpty);
  });

  test('one image asked for twice comes once', () async {
    final s = store(hold: {_a})..want(_a);
    final one = s.bytes(_a), two = s.bytes(_a);
    await settle();
    held[_a]!.complete(ok('x'));
    expect(text(await one), 'x');
    expect(text(await two), 'x');
    expect(asked, [_a]);
  });

  test('no more than the device can take come at once, the rest wait their turn', () async {
    final s = store(hold: {_a, _b, _c}, downloads: 2);
    for (final u in [_a, _b, _c]) {
      s.want(u);
      unawaited(s.bytes(u));
      await settle();
    }
    await settle();
    expect(asked, [_a, _b], reason: 'two at once');
    held[_a]!.complete(ok('a'));
    await settle();
    expect(asked, [_a, _b, _c], reason: 'one left: the next');
  });

  test('what came on screen last goes before what has been waiting', () async {
    final s = store(hold: {_a, _b, _c}, downloads: 1);
    for (final u in [_a, _b]) {
      s.want(u);
      unawaited(s.bytes(u));
      await settle();
    }
    await settle();
    now += const Duration(seconds: 1); // another moment: the user moved on
    s.want(_c);
    unawaited(s.bytes(_c));
    await settle();
    expect(asked, [_a]);
    held[_a]!.complete(ok('a'));
    await settle();
    expect(asked, [_a, _c], reason: '_c is what the screen shows now');
  });

  test('of what is asked for together, what is on top of the screen first', () async {
    const first = 'http://posters.test/first.jpg';
    final s = store(hold: {first, _a, _b, _c}, downloads: 1)..want(first);
    unawaited(s.bytes(first));
    await settle();
    for (final u in [_a, _b, _c]) {
      s.want(u);
      unawaited(s.bytes(u));
    }
    await settle();
    held[first]!.complete(ok('x'));
    await settle();
    expect(asked, [first, _a], reason: 'in order, not the farthest off screen');
  });

  test('scrolled past before its turn, it never comes', () async {
    final s = store(hold: {_a, _b}, downloads: 1);
    for (final u in [_a, _b]) {
      s.want(u);
    }
    unawaited(s.bytes(_a));
    await settle();
    final gone = s.bytes(_b);
    await settle();
    s.unwant(_b);
    await expectLater(gone, throwsA(isA<ImageUnavailable>()));
    held[_a]!.complete(ok('a'));
    await settle();
    expect(asked, [_a], reason: 'nothing shows it any more');
  });

  test('while another card still shows it, it keeps its turn', () async {
    final s = store(hold: {_a, _b}, downloads: 1)
      ..want(_a)
      ..want(_b)
      ..want(_b);
    unawaited(s.bytes(_a));
    await settle();
    unawaited(s.bytes(_b));
    await settle();
    s.unwant(_b);
    held[_a]!.complete(ok('a'));
    await settle();
    expect(asked, [_a, _b]);
  });

  test('coming back to one that gave up its turn asks for it again', () async {
    final s = store(hold: {_a}, downloads: 1)
      ..want(_a)
      ..want(_b);
    unawaited(s.bytes(_a));
    await settle();
    final gone = s.bytes(_b);
    await settle();
    s.unwant(_b);
    await expectLater(gone, throwsA(isA<ImageUnavailable>()));
    held[_a]!.complete(ok('a'));
    await settle();

    s.want(_b);
    expect(text(await s.bytes(_b)), _b);
  });

  test('one the server refuses is left alone, and frees its place', () async {
    final s = store(status: 404, downloads: 1)..want(_a);
    await expectLater(s.bytes(_a), throwsA(isA<ImageUnavailable>()));
    await expectLater(s.bytes(_a), throwsA(isA<ImageUnavailable>()));
    expect(asked, [_a], reason: 'not asked again each time it shows');

    s.want(_b);
    await expectLater(s.bytes(_b), throwsA(isA<ImageUnavailable>()));
    expect(asked, [_a, _b], reason: 'the failure gave its place back');
    expect(dir.listSync(), isEmpty, reason: 'and nothing of it was kept');
  });

  test('what is no image is not kept, and not asked for again for a while', () async {
    final s = store()..want(_a);
    await s.bytes(_a);
    await settle();
    expect(dir.listSync(), hasLength(1));

    s.forget(_a);
    await settle();
    expect(dir.listSync(), isEmpty);
    await expectLater(s.bytes(_a), throwsA(isA<ImageUnavailable>()));
    expect(asked, [_a]);
  });

  test('something too big to be a poster is refused without holding it', () async {
    final s = ImageStore(
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.value(Uint8List(16)), 200, contentLength: 13 << 20),
      ),
      directory: () async => dir,
    )..want(_a);
    await expectLater(s.bytes(_a), throwsA(isA<ImageUnavailable>()));
  });

  test('one sent without a size stops at the limit too', () async {
    final s = ImageStore(
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.fromIterable(List.generate(14, (_) => Uint8List(1 << 20))), 200),
      ),
      directory: () async => dir,
    )..want(_a);
    await expectLater(s.bytes(_a), throwsA(isA<ImageUnavailable>()));
  });

  testWidgets('one given up on for silence has its request called off, not left open', (tester) async {
    Future<void>? abort;
    final s = ImageStore(
      client: MockClient.streaming((request, _) {
        abort = (request as http.Abortable).abortTrigger;
        return Completer<http.StreamedResponse>().future; // the host took it, and says nothing
      }),
      directory: () async => null,
    )..want(_a);
    Object? error;
    unawaited(s.bytes(_a).then((_) {}, onError: (Object e) => error = e));
    await tester.pump();
    var calledOff = false;
    unawaited(abort!.then((_) => calledOff = true));
    await tester.pump(const Duration(seconds: 10));
    expect(calledOff, isFalse, reason: 'still within its time');
    await tester.pump(const Duration(seconds: 6));
    expect(error, isA<ImageUnavailable>());
    expect(calledOff, isTrue);
  });

  test('the folder is gone through only once what is kept passes what it may take', () async {
    final s = ImageStore(
      client: MockClient((_) async => http.Response.bytes(Uint8List(400), 200)),
      directory: () async => dir,
    )..diskBytes = 1000;
    Future<void> show(String url) async {
      s.want(url);
      await s.bytes(url);
      s.unwant(url);
      await settle();
    }

    // A download being finished renames its .part file meanwhile: one gone counts nothing
    int size() => dir.listSync().whereType<File>().fold(0, (n, f) => n + f.statSync().size.clamp(0, 1 << 40));
    await show('http://posters.test/1.jpg');
    File('${dir.path}/stray').writeAsBytesSync(Uint8List(5000)); // put there behind its back
    await show('http://posters.test/2.jpg');
    expect(File('${dir.path}/stray').existsSync(), isTrue, reason: '800 bytes of its own: no need to look');
    await show('http://posters.test/3.jpg');
    for (var i = 0; i < 40 && size() > 1000; i++) {
      await settle();
    }
    expect(size(), lessThanOrEqualTo(1000), reason: 'past 1100 of its own: looked, and trimmed');
  });

  test('when full, the images seen longest ago go', () {
    final now = DateTime.now();
    for (final (i, name) in ['old', 'middle', 'new'].indexed) {
      File('${dir.path}/$name')
        ..writeAsBytesSync(Uint8List(100))
        ..setLastModifiedSync(now.subtract(Duration(days: 3 - i)));
    }
    expect(trimImages(dir.path, 200), 200, reason: 'what is left');
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'middle', 'new'});
  });

  group('what each device may spend', () {
    test('a 1 GB TV stick spends the least, and sharpness goes before the catalog', () {
      lowMemory = true;
      memoryMb = 900;
      expect(deviceTier, DeviceTier.low);
      expect(imageBudget.decodedMb, 50);
      expect(imageBudget.decodeScale, lessThan(1));
    });

    test('a phone or TV box in the middle spends the usual', () {
      memoryMb = 2800;
      expect(deviceTier, DeviceTier.medium);
      expect(imageBudget.decodedMb, 100);
    });

    test('plenty of memory reads further ahead, and a computer says nothing and has it', () {
      memoryMb = 7600;
      expect(deviceTier, DeviceTier.high);
      final phone = imageBudget;
      memoryMb = null;
      expect(deviceTier, DeviceTier.high);
      expect(imageBudget, phone);
      expect(imageBudget.downloads, greaterThan(4));
    });

    test('the disk gets a tenth of what is left at most, and nothing when little is left', () {
      expect(imagesOnDiskMb(150, 2900), 150, reason: 'room to spare: the whole budget');
      expect(imagesOnDiskMb(1024, 2900), 290, reason: 'a tenth of what is left');
      expect(imagesOnDiskMb(150, 200), 0, reason: 'the room is the user\'s first');
      expect(imagesOnDiskMb(1024, null), 1024, reason: 'a computer does not say');
    });
  });

  test('the file names give nothing away: an image address may carry an account', () async {
    const secret = 'http://panel.test/images/user/password/a.jpg';
    final s = store()..want(secret);
    await s.bytes(secret);
    await settle();
    expect(dir.listSync().single.uri.pathSegments.last, stableHash(secret));
  });
}
