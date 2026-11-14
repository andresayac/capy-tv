import 'dart:async';

import 'package:flutter/material.dart';

import '../chromecast/cast_discovery.dart';
import '../chromecast/cast_plan.dart';
import '../chromecast/chromecast_service.dart';
import '../data/library.dart';
import '../data/profiles.dart';
import '../l10n/app_localizations.dart';
import '../player/play.dart';
import '../sync/sync_client.dart';
import '../sync/sync_service.dart';
import 'common.dart';
import 'theme.dart';

/// Where something went from "Send to…".
sealed class SendTarget {
  const SendTarget();
}

/// Another device of the account, sent the request through the sync: it plays it when it gets it,
/// which nothing here can tell.
class SentToDevice extends SendTarget {
  const SentToDevice(this.name, {required this.active});

  final String name;

  /// It was about a moment ago, so likely on and taking it; one long unseen may be off.
  final bool active;
}

/// A Chromecast on this network: the caller starts the cast (see CastScreen).
class CastToDevice extends SendTarget {
  const CastToDevice(this.device);

  final ChromecastDevice device;
}

/// Whether "Send to…" has anywhere to offer for [item] (of [ref]): the account's devices, or a
/// Chromecast. A profile with a time per day sends nowhere: its time would not be counted there.
bool canSend({MediaRef? ref, PlayItem? item}) =>
    ProfileStore.instance.current.dailyMinutes == null &&
    ((ref != null && SyncService.instance.signedIn && currentLibrary.value != null) ||
        (item != null && item.url.startsWith('http')));

/// Asks where [ref] / [item] goes: another device of the account (sent from here, from [position]),
/// or a Chromecast on this network (the caller casts it). Null if none was picked.
Future<SendTarget?> sendTo(
  BuildContext context, {
  MediaRef? ref,
  PlayItem? item,
  Duration position = Duration.zero,
}) async {
  final l = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final playlist = currentLibrary.value?.playlistId;
  final account =
      ref != null &&
      playlist != null &&
      SyncService.instance.signedIn &&
      ProfileStore.instance.current.dailyMinutes == null;
  final nearby = item != null && canSend(item: item);
  if (nearby) unawaited(ChromecastService.instance.discover());
  final picked = await showDialog<Object>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(l.sendTo),
      children: [
        if (account && nearby) _Header(l.sendToYourDevices),
        if (account) _AccountDevices(onPick: (d) => Navigator.pop(ctx, d)),
        if (account && nearby) _Header(l.sendToNearby),
        if (nearby) _NearbyDevices(item: item, firstFocus: !account, onPick: (d) => Navigator.pop(ctx, d)),
      ],
    ),
  );
  if (nearby) unawaited(ChromecastService.instance.stopDiscovery()); // picked or not, it is done looking
  switch (picked) {
    case ChromecastDevice device:
      return CastToDevice(device);
    case Device device when ref != null && playlist != null:
      try {
        await SyncService.instance.cast(to: device.id, playlistId: playlist, ref: ref, position: position);
        return SentToDevice(device.name, active: DateTime.now().difference(device.seen) < SyncService.castFor);
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text(errorText(l, e))));
        return null;
      }
    default:
      return null;
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
    child: Text(text.toUpperCase(), style: const TextStyle(color: AppColors.muted, fontSize: 12, letterSpacing: 1)),
  );
}

/// A row of the dialog: an icon, a name and a line under it.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.autofocus = false,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Focusable(
    autofocus: autofocus, // the row itself takes the remote's focus
    scale: 1,
    radius: 10,
    onTap: onPressed,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: AppColors.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtitle case final sub? when sub.isNotEmpty)
                  Text(sub, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The account's other devices, the one most recently about first.
class _AccountDevices extends StatelessWidget {
  const _AccountDevices({required this.onPick});

  final ValueChanged<Device> onPick;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<List<Device>>(
      future: SyncService.instance.devices(),
      builder: (ctx, snap) {
        if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text(errorText(l, snap.error!)));
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          );
        }
        final others = [
          for (final d in snap.data ?? const <Device>[])
            if (!d.current) d,
        ]..sort((a, b) => b.seen.compareTo(a.seen));
        if (others.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(l.noOtherDevices, style: const TextStyle(color: AppColors.muted)),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, d) in others.indexed)
              _Row(
                icon: Icons.tv_rounded,
                title: d.name,
                subtitle: DateTime.now().difference(d.seen) < SyncService.castFor
                    ? l.deviceActive
                    : l.syncSeen(dayAndClock(context, d.seen.toLocal())),
                autofocus: i == 0, // for a remote too
                onPressed: () => onPick(d),
              ),
          ],
        );
      },
    );
  }
}

/// Chromecasts on this network, as they are found, and one by its address.
class _NearbyDevices extends StatefulWidget {
  const _NearbyDevices({required this.item, required this.firstFocus, required this.onPick});

  final PlayItem item;
  final bool firstFocus; // nothing above takes the remote's focus
  final ValueChanged<ChromecastDevice> onPick;

  @override
  State<_NearbyDevices> createState() => _NearbyDevicesState();
}

class _NearbyDevicesState extends State<_NearbyDevices> {
  late final _plan = ChromecastService.planFor(widget.item);
  var _searching = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 8), () => mounted ? setState(() => _searching = false) : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _byAddress() async {
    final l = context.l10n;
    final text = TextEditingController();
    final device = await showDialog<ChromecastDevice>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setError) {
            void done() {
              // As copied from a browser: "http://192.168.1.20/"
              final typed = text.text.trim().replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
              final d = parseCastAddress(typed.endsWith('/') ? typed.substring(0, typed.length - 1) : typed);
              if (d != null) return Navigator.pop(ctx, d);
              setError(() => error = l.castAddressInvalid);
            }

            return AlertDialog(
              title: Text(l.castByAddress),
              content: TextField(
                controller: text,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(hintText: l.castAddressHint, errorText: error, errorMaxLines: 3),
                onChanged: (_) => error == null ? null : setError(() => error = null),
                onSubmitted: (_) => done(),
              ),
              actions: [
                SecondaryButton(label: l.cancel, onPressed: () => Navigator.pop(ctx)),
                PrimaryButton(label: l.castConnect, onPressed: done),
              ],
            );
          },
        );
      },
    );
    text.dispose();
    if (device == null) return;
    await ChromecastService.instance.remember(device);
    widget.onPick(device);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (!_plan.castable) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text(castRefusalText(l, _plan), style: const TextStyle(color: AppColors.muted)),
      );
    }
    final service = ChromecastService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([service.devices, service.typed]),
      builder: (context, _) {
        // Found ones once their address is known (a moment after they show up)
        final found = [
          for (final d in service.devices.value)
            if (d.host.isNotEmpty) d,
        ];
        final typed = [
          for (final d in service.typed.value)
            if (!found.any((f) => f.host == d.host)) d,
        ];
        final all = [...found, ...typed];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, d) in all.indexed)
              _Row(
                key: ValueKey(d.id),
                icon: Icons.cast_rounded,
                title: d.name,
                subtitle: d.model.isNotEmpty ? d.model : d.host,
                autofocus: widget.firstFocus && i == 0,
                onPressed: () => widget.onPick(d),
              ),
            if (all.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Row(
                  children: [
                    if (_searching) ...[
                      const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        _searching ? l.castSearching : l.castNoneFound,
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ),
                  ],
                ),
              ),
            _Row(
              icon: Icons.add_link_rounded,
              title: l.castByAddress,
              autofocus: widget.firstFocus && all.isEmpty,
              onPressed: _byAddress,
            ),
          ],
        );
      },
    );
  }
}

/// Why [plan] cannot be cast, in words.
String castRefusalText(AppLocalizations l, CastPlan plan) => switch (plan.refusal) {
  CastRefusal.file => l.castUnsupportedFile(plan.format ?? '?'),
  CastRefusal.local => l.castUnsupportedLocal,
  CastRefusal.noHls => l.castNoHls,
  CastRefusal.liveFormat || null => l.castUnsupportedLive,
};
