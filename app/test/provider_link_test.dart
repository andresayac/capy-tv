// The link a provider hands out carries a whole Xtream account: pasting it is enough.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/xtream.dart';

void main() {
  test('the account in the links providers send', () {
    expect(Playlist.xtreamLink('http://tv.example:8080/get.php?username=ana&password=s3cret&type=m3u_plus&output=ts'), (
      server: 'http://tv.example:8080',
      username: 'ana',
      password: 's3cret',
    ));
    expect(
      Playlist.xtreamLink(' https://tv.example/player_api.php?username=ana&password=s3cret ')?.server,
      'https://tv.example',
    );
    expect(Playlist.xtreamLink('http://tv.example:80/live/ana/s3cret/1234.ts')?.username, 'ana');
    expect(Playlist.xtreamLink('http://tv.example:80/movie/ana/s3cret/99.mkv')?.password, 's3cret');
    expect(Playlist.xtreamLink('http://tv.example/timeshift/ana/s3cret/120/2026-11-08:20-00/1234.ts')?.username, 'ana');
    expect(Playlist.xtreamLink('http://lists.example/my-list.m3u'), isNull, reason: 'a plain M3U list');
    expect(
      Playlist.xtreamLink('https://cdn.example.com/live/sports/us/playlist.m3u8'),
      isNull,
      reason: 'a CDN path under /live/, not a panel stream',
    );
    expect(Playlist.xtreamLink('https://cdn.example/series/2024/list/index.m3u'), isNull);
    expect(Playlist.xtreamLink('http://tv.example:8080'), isNull, reason: 'a server alone');
    expect(Playlist.xtreamLink('not a link'), isNull);
  });

  test('a panel in a folder of its own keeps it, and an IPv6 address its brackets', () {
    expect(
      Playlist.xtreamLink('http://tv.example:8080/panel/get.php?username=ana&password=s3cret&type=m3u_plus')?.server,
      'http://tv.example:8080/panel',
    );
    expect(
      Playlist.xtreamLink('http://tv.example/iptv/xmltv.php?username=ana&password=s3cret')?.server,
      'http://tv.example/iptv',
    );
    expect(
      Playlist.xtreamLink('http://[2001:db8::1]:8080/get.php?username=ana&password=s3cret')?.server,
      'http://[2001:db8::1]:8080',
    );
    expect(Playlist.xtreamLink('http://[2001:db8::1]/live/ana/s3cret/1.ts')?.server, 'http://[2001:db8::1]');
    expect(XtreamSource.normalizeServer('http://tv.example/iptv/xmltv.php').toString(), 'http://tv.example/iptv');
  });

  test('a User-Agent goes with the playlist, its copies and edits, and only for Xtream', () {
    final p = Playlist.create(
      type: PlaylistType.xtream,
      url: 'http://tv.example',
      username: 'a',
      userAgent: ' VLC/3.0 ',
    );
    expect(p.userAgent, 'VLC/3.0');
    expect(Playlist.fromJson(p.toJson()).userAgent, 'VLC/3.0');
    expect(p.copyWith(name: 'Other').userAgent, 'VLC/3.0');
    expect(p.toJson().containsKey('userAgent'), isTrue);
    expect(
      Playlist.create(
        type: PlaylistType.xtream,
        url: 'http://tv.example',
        username: 'a',
      ).toJson().containsKey('userAgent'),
      isFalse,
    );
    expect(Playlist.create(type: PlaylistType.m3u, url: 'http://lists.example/a.m3u', userAgent: 'VLC').userAgent, '');
    // A server written with no http:// still names the list
    expect(Playlist.create(type: PlaylistType.xtream, url: 'tv.example:8080', username: 'a').name, 'tv.example');
    expect(Playlist.create(type: PlaylistType.xtream, url: '10.0.0.5', username: 'a').name, '10.0.0.5');
    // Pasted from a chat with a space at the end
    expect(
      Playlist.create(type: PlaylistType.xtream, url: 'tv.example', username: 'a', password: ' s3cret ').password,
      's3cret',
    );
    expect(
      Playlist.fromJson(p.toJson()).extra,
      isEmpty,
      reason: 'a field of its own, not something unknown kept aside',
    );
  });

  test('pasted as an M3U list, it becomes the Xtream account it is', () {
    final p = Playlist.create(
      type: PlaylistType.m3u,
      url: 'http://tv.example:8080/get.php?username=ana&password=s3cret&type=m3u_plus',
    );
    expect(p.type, PlaylistType.xtream);
    expect(p.url, 'http://tv.example:8080');
    expect((p.username, p.password), ('ana', 's3cret'));
    expect(p.name, 'tv.example');
    // A plain list stays one
    expect(Playlist.create(type: PlaylistType.m3u, url: 'http://lists.example/a.m3u').type, PlaylistType.m3u);
  });

  test('the same account written another way is the same account', () {
    Playlist x(String url, [String user = 'a']) => Playlist.create(type: PlaylistType.xtream, url: url, username: user);
    expect(x('http://tv.example:8080').sameAccount(x('tv.example:8080')), isTrue);
    expect(x('http://tv.example:8080/').sameAccount(x(' http://tv.example:8080 ')), isTrue);
    expect(x('http://tv.example:8080').sameAccount(x('http://tv.example:8081')), isFalse);
    expect(x('http://tv.example:8080').sameAccount(x('http://tv.example:8080', 'b')), isFalse);
  });
}
