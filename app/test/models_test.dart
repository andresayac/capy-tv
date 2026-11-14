// The models of a playlist's lists: what they read from a panel comes back as it was, however
// they keep it to take little memory (one copy of what items repeat, ids and dates as small ints).
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/models.dart';

/// [s] in a string of its own, as each item decoded from JSON has.
String _copy(String s) => String.fromCharCodes(s.codeUnits);

void main() {
  test('a pool keeps one copy of each value, and every value as it was', () {
    final pool = ValuePool();
    final a = _copy('Drama, Comedia'), b = _copy('Drama, Comedia');
    expect(identical(a, b), isFalse, reason: 'two copies to begin with');
    expect(identical(Movie.fromJson({'genre': a}).genre, Movie.fromJson({'genre': b}).genre), isFalse);
    expect(identical(pool.text(a), a), isTrue);
    expect(identical(pool.text(b), a), isTrue, reason: 'the first copy');
    expect(pool.text(null), isNull);
    expect(pool.number(7.5), 7.5);
    expect(pool.number(-0.0)!.isNegative, isTrue, reason: '-0.0 equals 0.0, yet it is not shared with it');
    expect(pool.number(0.0)!.isNegative, isFalse);
    expect(pool.number(double.nan)!.isNaN, isTrue);
    expect(pool.number(null), isNull);
    expect(pool.duration(const Duration(minutes: 90)), const Duration(minutes: 90));
    expect(pool.duration(null), isNull);
  });

  test("a listing's items share what they repeat", () {
    final pool = ValuePool();
    Map<String, dynamic> item(int id) => {
      'stream_id': id,
      'name': _copy('Heat (1995)'),
      'plot': _copy('A heist.'),
      'genre': _copy('Crime, Drama'),
      'category_id': _copy('7'),
      'container_extension': _copy('mkv'),
      'rating': _copy('8.3'),
      'duration_secs': 6000,
    };
    final a = Movie.fromJson(item(1), pool), b = Movie.fromJson(item(2), pool);
    for (final (x, y) in [
      (a.name, b.name),
      (a.plot, b.plot),
      (a.genre, b.genre),
      (a.categoryId, b.categoryId),
      (a.extension, b.extension),
      (a.duration, b.duration),
    ]) {
      expect(identical(x, y), isTrue, reason: '$x');
    }
    final alone = Movie.fromJson(item(1));
    expect(
      [alone.name, alone.plot, alone.genre, alone.categoryId, alone.extension, alone.rating, alone.duration],
      [a.name, a.plot, a.genre, a.categoryId, a.extension, a.rating, a.duration],
      reason: 'shared or not, the same values',
    );
    final s1 = Series.fromJson({'series_id': 1, 'name': 'Dark', 'cover': _copy('http://i/d.jpg')}, pool);
    final s2 = Series.fromJson({'series_id': 2, 'name': 'Dark', 'cover': _copy('http://i/d.jpg')}, pool);
    expect(identical(s1.cover, s2.cover), isTrue);
    final c1 = LiveChannel.fromJson({'stream_id': 1, 'name': 'One', 'category_id': _copy('3')}, pool);
    final c2 = LiveChannel.fromJson({'stream_id': 2, 'name': 'Two', 'category_id': _copy('3')}, pool);
    expect(identical(c1.categoryId, c2.categoryId), isTrue);
  });

  test('ids come back as the panel wrote them', () {
    for (final (sent, id) in [
      (201, '201'),
      ('202', '202'),
      (' 203 ', '203'),
      ('0204', '0204'),
      ('+205', '+205'),
      ('-206', '-206'),
      ('0x1F', '0x1F'),
      ('12.0', '12.0'),
      (12.0, '12.0'),
      ('99999999999999999999999', '99999999999999999999999'),
      ('vod-207', 'vod-207'),
      (null, ''),
    ]) {
      expect(Movie.fromJson({'stream_id': sent}).id, id, reason: '$sent');
      expect(Series.fromJson({'series_id': sent}).id, id, reason: '$sent');
    }
    final m = Movie.fromJson({'stream_id': 201, 'name': 'Heat'});
    expect(m.withIds('1~201', null).id, '1~201');
    expect(m.withDetail(Movie.fromJson({'stream_id': '201', 'plot': 'p'})).id, '201');
    expect(const Movie(id: 'm7', name: 'x').id, 'm7');
  });

  test('dates come back as they were read, local or UTC, to the microsecond', () {
    final added = DateTime.fromMillisecondsSinceEpoch(1783669690 * 1000);
    for (final (sent, date) in [
      ('2024-05-01', DateTime(2024, 5, 1)),
      ('2024-05-01T10:00:00Z', DateTime.utc(2024, 5, 1, 10)),
      ('2024-05-01 10:00:00.250', DateTime(2024, 5, 1, 10, 0, 0, 250)),
      ('1890-01-02', DateTime(1890, 1, 2)),
      ('2090-12-31 23:59:59', DateTime(2090, 12, 31, 23, 59, 59)),
      ('not a date', null),
    ]) {
      final m = Movie.fromJson({'stream_id': 1, 'added': '1783669690', 'releasedate': sent});
      expect(m.releaseDate, date, reason: sent);
      expect(m.releaseDate?.isUtc, date?.isUtc, reason: sent);
      expect(m.releaseMicros, date?.microsecondsSinceEpoch, reason: sent);
      expect(m.added, added);
      expect(m.addedMicros, added.microsecondsSinceEpoch);
    }
    expect(Movie.fromJson({'added': '0'}).added, isNull, reason: 'panels send 0 for no date');
    expect(Movie.fromJson({'added': '-86400'}).added, DateTime.fromMillisecondsSinceEpoch(-86400000));
    expect(Movie.fromJson({}).addedMicros, isNull);
    final s = Series.fromJson({'series_id': 1, 'last_modified': 1783669690});
    expect(s.updated, added);
    expect(s.updatedMicros, added.microsecondsSinceEpoch);
    expect(s.withIds('0~1', null).updated, added);
  });

  test('a date given whole is kept as it is, and so are the copies', () {
    final utc = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7), local = DateTime(2026, 1, 2);
    final m = Movie(id: '1', name: 'x', added: utc, releaseDate: local);
    expect(m.added, utc);
    expect(m.added!.isUtc, isTrue);
    expect(m.releaseDate, local);
    expect(m.addedMicros, utc.microsecondsSinceEpoch);
    final listed = Movie.fromJson({'stream_id': 1, 'added': 1783669690});
    final full = Movie.fromJson({'stream_id': 1, 'releasedate': '2026-07-01'});
    final both = listed.withDetail(full);
    expect(both.added, listed.added);
    expect(both.releaseDate, DateTime(2026, 7, 1), reason: 'what the full record adds');
    expect(listed.withDetail(Movie(id: '1', name: 'x', releaseDate: utc)).releaseDate, utc);
    expect(both.withIds('0~1', '0~7').releaseDate, both.releaseDate);
    expect(Series(id: '1', name: 'x', updated: utc).updated, utc);
  });

  test('values as panels really send them', () {
    expect(asDouble('7,5'), 7.5, reason: 'a decimal comma');
    expect(asDouble('8.2/10'), 8.2);
    expect(asDouble(8), 8.0);
    expect(asDouble('N/A'), isNull);
    expect(asDouble(double.infinity), isNull);
    expect(asStr(const []), isNull, reason: 'plot: [] is no plot');
    expect(asStr(const {}), isNull);
    expect(asStr('null'), isNull);
    expect(asStr(' N/A '), isNull);
    expect(asStr(' Drama '), 'Drama');
    expect(asDate('0000-00-00'), isNull, reason: "MySQL's empty date");
    expect(asDate('2020-05-01')!.year, 2020);
    expect(asInt(true), 1, reason: 'a yes sent as true');
    expect(asInt(' false '), 0);
    expect(asInt('7'), 7);
  });

  test("an empty date field does not hide the other's", () {
    final m = Movie.fromJson({'stream_id': 1, 'name': 'x', 'release_date': '', 'releasedate': '2021-05-01'});
    expect(m.year, 2021);
    expect(m.releaseDate!.year, 2021);
    final n = Movie.fromJson({'stream_id': 1, 'name': 'x', 'releasedate': '', 'release_date': '2019-02-03'});
    expect(n.releaseDate!.year, 2019);
  });

  test("a series' details with a rating of 0 keep the listing's", () {
    const base = Series(id: '1', name: 'Show', rating: 8.1);
    expect(
      SeriesDetail.fromJson(base, {
        'info': {'rating': '0'},
      }).series.rating,
      8.1,
    );
    expect(
      SeriesDetail.fromJson(base, {
        'info': {'rating': '7.4'},
      }).series.rating,
      7.4,
    );
  });

  test("a panel's year 0 is none, a date written as a year gives it, a rating out of 5 is doubled", () {
    Movie movie(Map<String, dynamic> j) => Movie.fromJson({'stream_id': 1, 'name': 'M', ...j});
    expect(movie({'year': 0}).year, isNull);
    expect(movie({'year': '0', 'releasedate': '2014'}).year, 2014);
    expect(movie({'year': 0, 'release_date': '0000-00-00'}).year, isNull);
    expect(movie({'year': '2019'}).year, 2019);
    expect(Series.fromJson({'series_id': 1, 'name': 'S', 'year': 0, 'releaseDate': '2011-04-17'}).year, 2011);
    expect(movie({'rating': '0', 'rating_5based': 4.1}).rating, closeTo(8.2, 0.001));
    expect(movie({'rating': '7,5', 'rating_5based': 3}).rating, 7.5);
    expect(movie({'rating': 85}).rating, isNull, reason: 'not out of 10');
    expect(movie({'rating_5based': '0'}).rating, isNull);
  });

  test('catch-up is offered only within the days a channel keeps', () {
    final now = DateTime(2026, 11, 12, 20);
    const twoDays = LiveChannel(id: '1', name: 'News', archiveDays: 2);
    expect(twoDays.keeps(now.subtract(const Duration(hours: 3)), now), isTrue);
    expect(twoDays.keeps(now.subtract(const Duration(days: 3)), now), isFalse, reason: 'older than it keeps');
    expect(twoDays.keeps(now.add(const Duration(hours: 1)), now), isFalse, reason: 'not over yet');
    expect(const LiveChannel(id: '2', name: 'Other').keeps(now.subtract(const Duration(hours: 1)), now), isFalse);
  });
}
