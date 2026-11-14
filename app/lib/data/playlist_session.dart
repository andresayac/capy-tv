import 'dart:async';

import 'kids.dart';
import 'library.dart';
import 'models.dart' show AccountInfo;
import 'playlists.dart';
import 'profiles.dart';
import 'source.dart';
import 'xtream.dart';

/// A playlist opened for a profile, and what goes with it (tizen/src/session.ts's Session): its
/// source, limited to what the profile may see, the account the panel says it is (Xtream), and the
/// profile's library in it.
///
/// Opening a playlist and updating its lists take the same steps, here, so the two cannot drift
/// apart: an update once skipped the login that gives the panel's clock (REL-019), and a library
/// published apart from its playlist mixed one playlist's with another's (CON-009). Home still
/// holds the catalog and the guide, and screens still read [currentLibrary] and [currentCatalog]:
/// moving those here is what is left of ARF-009.
class PlaylistSession {
  PlaylistSession._(this.playlist, this.profile, this.source, this.account, this.library);

  final Playlist playlist;
  final Profile profile;
  final ContentSource source;

  /// The account, as the panel said at login or as saved from the last one; null for M3U.
  final AccountInfo? account;
  final Library library;

  /// Opens [p] for [profile]: its source (lists on the device while fresh), the account and the
  /// library. Throws (a SourceException) when it does not open.
  static Future<PlaylistSession> open(Playlist p, Profile profile, {required String liveFormat}) async {
    final source = await sourceFor(p, profile, liveFormat: liveFormat);
    // No answer from the panel with its lists on disk: those open, as when they cannot be updated
    final account = source is XtreamSource ? await source.loginOrSaved() : null;
    final library = await Library.load(p.id, profile.id);
    return PlaylistSession._(p, profile, source, account, library);
  }

  /// [p]'s source for [profile], with only what the profile may see; its lists from the provider
  /// whatever their age with [refetch].
  static Future<ContentSource> sourceFor(
    Playlist p,
    Profile profile, {
    required String liveFormat,
    bool refetch = false,
  }) async {
    final source = await p.open(liveFormat: liveFormat, refetch: refetch);
    limitTo(source, profile);
    return source;
  }

  /// [p]'s lists from the provider again, for an update, as [open] would for [profile]: the panel
  /// is also asked for its clock (catch-up goes by it; without it the device's time zone would be
  /// used), not waited for.
  static Future<ContentSource> fresh(Playlist p, Profile profile, {required String liveFormat}) async {
    final source = await sourceFor(p, profile, liveFormat: liveFormat, refetch: true);
    if (source case final XtreamSource x) unawaited(x.login().then((_) {}, onError: (Object _) {}));
    return source;
  }

  /// Its library is the open one ([currentLibrary]) from now on.
  void publish() => currentLibrary.value = library;

  /// It is closed: its library is no longer the open one, unless another session's took its place
  /// (the same playlist opened again for another profile).
  void close() {
    if (currentLibrary.value == library) currentLibrary.value = null;
  }
}
