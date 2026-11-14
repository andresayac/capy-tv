import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../data/catalog.dart' show displayCategoryName;
import '../data/clock.dart';
import '../data/image_store.dart';
import '../data/models.dart' show Episode, ungrouped, untitled, untitledEpisode;
import '../data/source.dart';
import '../device.dart';
import '../l10n/app_localizations.dart';
import 'capy_status.dart';
import 'fitted_image.dart';
import 'theme.dart';

export 'capy_status.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// None where no app is around it (a widget on its own): for what only a screen reader says.
  AppLocalizations? get l10nOrNull => Localizations.of<AppLocalizations>(this, AppLocalizations);
}

/// Whether to use the wide layouts (side navigation, two panes) of TVs, computers and phones,
/// which the app always shows in landscape. Narrow desktop windows get the stacked layout. Pass
/// the [width] actually available (from a LayoutBuilder) when it can differ from the window's.
bool isWide(BuildContext context, {double? width, double min = 600}) =>
    (width ?? MediaQuery.sizeOf(context).width) >= min;

/// The window heights where the layout changes. Below [shortHeight], a phone on its side (or a
/// window as low): smaller heroes and posters, the rail of icons alone. Below [lowHeight], a TV's
/// 540 points: names under the icons, a little closer together.
const shortHeight = 560.0, lowHeight = 600.0;

/// A phone in landscape: wide but only about 400 points tall, so heroes and posters shrink. A TV is
/// about 540 tall but seen from the sofa: it keeps them large.
bool isShort(BuildContext context) => MediaQuery.sizeOf(context).height < shortHeight && !isTv;

/// A poster's width in a row: smaller on a phone in landscape, so about six fit, as in streaming
/// apps; a TV, seen from the sofa, keeps them large.
double posterWidth(BuildContext context) => isShort(context) ? 104 : 150;

/// A row of posters: the artwork (2:3), the title under it and room for the focus ring.
double posterRailHeight(BuildContext context) => posterWidth(context) * 1.5 + 43;

/// A time of day as this device shows its clock ("21:05", "9:05 p. m."): the same on every screen.
String clockText(BuildContext context, DateTime t) => clockFormat(
  Localizations.localeOf(context).toLanguageTag(),
  h24: MediaQuery.alwaysUse24HourFormatOf(context),
).format(t);

/// A day and its time, short: "12 nov, 21:05".
String dayAndClock(BuildContext context, DateTime t) =>
    '${DateFormat.MMMd(Localizations.localeOf(context).toLanguageTag()).format(t)}, ${clockText(context, t)}';

/// A date with its year ("26 mar 2026" / "Mar 26, 2026") in the app's language.
String formatDate(BuildContext context, DateTime d) {
  final tag = Localizations.localeOf(context).toLanguageTag();
  return (_dateFormats[tag] ??= DateFormat.yMMMd(tag)).format(d);
}

/// One format per language: making one each time read its patterns again, for each of a soap's
/// episodes.
final _dateFormats = <String, DateFormat>{};

/// User-facing text for any error coming from a source.
/// [children] kept clear of a landscape phone's camera cutout at the sides, but for the first
/// [skip], which go edge to edge (artwork that minds the cutout itself, such as [HeroCarousel]).
List<Widget> clearOfCutout(List<Widget> children, {int skip = 0}) => [
  ...children.take(skip),
  for (final c in children.skip(skip)) SafeArea(top: false, bottom: false, child: c),
];

String errorText(AppLocalizations l, Object error) {
  if (error is! SourceException) return l.errorUnknown;
  return switch (error.error) {
    SourceError.unreachable => l.errorUnreachable,
    SourceError.timeout => l.errorTimeout,
    SourceError.unauthorized => l.errorUnauthorized,
    // One that ended says when: what to ask the provider for
    SourceError.inactiveAccount => switch (error.until) {
      final d? when d.isBefore(DateTime.now()) => l.errorExpiredOn(DateFormat.yMMMd(l.localeName).format(d)),
      _ => l.errorInactive(accountStatusText(l, error.detail ?? '')),
    },
    SourceError.httpStatus => l.errorHttp(error.detail ?? ''),
    SourceError.badResponse => l.errorBadResponse,
    SourceError.notFound => l.errorNotFound,
    SourceError.emptyPlaylist => l.errorEmptyPlaylist,
    SourceError.badAddress => l.errorBadAddress,
    SourceError.wrongServer => l.errorWrongServer,
    SourceError.providerBusy => l.errorProviderBusy,
    SourceError.noSpace => l.errorNoSpace,
    SourceError.offline => l.errorOffline,
    SourceError.dns => l.errorDns,
    SourceError.tls => l.errorTls,
  };
}

/// An account's status as the panel sends it ("Expired", "Banned"), in the app's language; one it
/// does not know, as sent.
String accountStatusText(AppLocalizations l, String raw) => switch (raw.trim().toLowerCase()) {
  'active' => l.statusActive,
  'expired' => l.statusExpired,
  'banned' => l.statusBanned,
  'disabled' => l.statusDisabled,
  'trial' => l.statusTrial,
  '' || 'unknown' => l.statusUnknown,
  _ => raw,
};

/// A category's name as shown: the provider's, tidied, or the app's words for one it did not name.
String categoryLabel(AppLocalizations l, String raw) => switch (raw) {
  ungrouped => l.ungrouped,
  untitled => l.untitled,
  _ => displayCategoryName(raw),
};

/// An episode's own title, without the series' name it often repeats; null when the panel sent
/// none, for the screen to say its number instead.
String? episodeName(Episode e, String seriesName) {
  final t = e.cleanTitle(seriesName);
  return t == untitledEpisode ? null : t;
}

/// FutureBuilder with the loading, error (with retry) and empty states every list needs.
/// [load] runs once; give the widget a new key to load again (e.g. per category).
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.load,
    required this.builder,
    this.isEmpty,
    this.empty,
    this.loading,
    this.failed,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  final bool Function(T data)? isEmpty;
  final Widget? loading;

  /// What [isEmpty] data says; "nothing here" when not given.
  final String? empty;

  /// What shows when [load] fails, in place of a message and Retry over the whole of it: a page
  /// that still has what it had, with its error where the rest would go.
  final Widget Function(BuildContext context, Object error, VoidCallback retry)? failed;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  late Future<T> _future = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _future,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) {
        return widget.loading ?? const Center(child: CapyStatus(mood: CapyMood.loading));
      }
      if (snap.hasError) {
        void retry() => setState(() {
          _future = widget.load(); // a block: setState takes no Future back
        });
        if (widget.failed case final failed?) return failed(context, snap.error!, retry);
        // A Material under it, whatever is above: without one the text would take Flutter's
        // fallback style (big, red, underlined), and Retry would not answer a remote
        return Material(
          type: MaterialType.transparency,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: CapyMessage(
                mood: capyMoodForError(snap.error!),
                text: errorText(context.l10n, snap.error!),
                style: null, // in the body's colour: something to act on
                action: SecondaryButton(icon: Icons.refresh_rounded, label: context.l10n.retry, onPressed: retry),
              ),
            ),
          ),
        );
      }
      final data = snap.data as T;
      if (widget.isEmpty?.call(data) ?? false) {
        return Center(
          child: CapyMessage(mood: CapyMood.empty, text: widget.empty ?? context.l10n.nothingHere),
        );
      }
      return widget.builder(context, data);
    },
  );
}

/// How far the lists being waited for have got ([listDownloads]), in words: the share of them, or
/// how much has come when the server does not say how much there is. Null while none downloads.
String? listDownloadText(BuildContext context, DownloadProgress? p) {
  if (p == null) return null;
  final l = context.l10n;
  final total = p.total;
  if (total != null && total > 0) return l.downloadingCatalogPercent((100 * p.received ~/ total).clamp(0, 100));
  final mb = p.received / 1000000;
  final tag = Localizations.localeOf(context).toLanguageTag();
  return l.downloadingCatalogSize(NumberFormat(mb < 10 ? '0.0' : '0', tag).format(mb));
}

/// How far ahead of what they show lists of posters build, and so bring images, on this device.
ScrollCacheExtent get listReadAhead => ScrollCacheExtent.pixels(imageBudget.readAhead);

/// Changes when what the loading screens say about the lists may have.
final listProgress = Listenable.merge([listDownloads, listImports]);

/// How far the lists have got, on one line: what has come and how many are in it.
String? listProgressText(BuildContext context) {
  final download = listDownloadText(context, listDownloads.value);
  final items = listImports.items;
  if (items == 0) return download;
  final tag = Localizations.localeOf(context).toLanguageTag();
  final imported = context.l10n.importedCount(NumberFormat.decimalPattern(tag).format(items));
  return download == null ? imported : '$download · $imported';
}

/// Capy while the provider's lists load and, as they come, how far they have got and how many
/// channels, movies and series are in them already: a big catalog on a slow line takes minutes, and
/// a spinner alone looks stuck. So does one that goes quiet with the list here and still to be
/// read, tens of MB of it.
class ListLoading extends StatelessWidget {
  const ListLoading({super.key});

  // Said once as it starts, not at each step of its progress
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: context.l10n.loadingCatalog,
    // Where there is little height (a small phone on its side, large text), the words alone
    child: LayoutBuilder(builder: (context, box) => _progress(context, picture: box.maxHeight >= 260)),
  );

  Widget _progress(BuildContext context, {required bool picture}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (picture) ...[const CapyStatus(mood: CapyMood.loading), const SizedBox(height: 16)],
      ListenableBuilder(
        listenable: listProgress,
        builder: (context, _) {
          final p = listDownloads.value, rows = listImports.current;
          final total = p?.total;
          final downloaded = p != null && total != null && total > 0 ? (p.received / total).clamp(0.0, 1.0) : null;
          final read = p != null || rows.isEmpty || rows.every((r) => r.done)
              ? null
              : rows.fold<double>(0, (sum, r) => sum + (r.read ?? 0)) / rows.length;
          final share = downloaded ?? read;
          final say = rows.isEmpty ? context.l10n.loadingCatalog : context.l10n.organizingCatalog;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                listDownloadText(context, p) ?? say,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 160,
                height: 2,
                child: share == null
                    ? null
                    : LinearProgressIndicator(value: share, minHeight: 2, backgroundColor: AppColors.stroke),
              ),
              if (rows.isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 28,
                  runSpacing: 10,
                  children: [for (final row in rows) _ImportCount(row)],
                ),
              ],
            ],
          );
        },
      ),
    ],
  );
}

/// How many of a kind have come so far, and a check once they are all here.
class _ImportCount extends StatelessWidget {
  const _ImportCount(this.row);

  final ListImportRow row;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final tag = Localizations.localeOf(context).toLanguageTag();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.items == 0 ? '–' : NumberFormat.decimalPattern(tag).format(row.items),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.done) ...[
              const Icon(Icons.check_rounded, size: 13, color: AppColors.muted),
              const SizedBox(width: 3),
            ],
            Text(switch (row.kind) {
              ListKind.live => l.liveTv,
              ListKind.movies => l.movies,
              ListKind.series => l.series,
              ListKind.playlist => l.importedPlaylist,
            }, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          ],
        ),
      ],
    );
  }
}

/// A flat, solid surface. Over video, pass [AppColors.scrim] so controls stay legible.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.radius = AppRadius.panel,
    this.padding,
    this.color = AppColors.surface,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius)),
    child: child,
  );
}

/// A setting with a few values, chosen in a window: a whole row, its name and its value said
/// together. A dropdown lost the focus to the row above it with a remote, so what came after it
/// could not be reached, and a screen reader heard its value with no name ("Automatic, button").
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.text,
    required this.onChanged,
    this.hint,
    this.autofocus = false,
  });

  final String label;
  final String? hint;
  final bool autofocus;
  final T value;
  final List<T> options;
  final String Function(T) text;
  final ValueChanged<T> onChanged;

  Future<void> _open(BuildContext context) async {
    final picked = await showDialog<({T value})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final o in options)
                Focusable(
                  autofocus: o == value,
                  selected: o == value,
                  radius: 12,
                  scale: 1.01,
                  onTap: () => Navigator.pop(ctx, (value: o)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            text(o),
                            style: TextStyle(fontWeight: o == value ? FontWeight.w700 : FontWeight.w500),
                          ),
                        ),
                        if (o == value) const Icon(Icons.check_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked.value != value) onChanged(picked.value);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Focusable(
      autofocus: autofocus,
      radius: 12,
      scale: 1.01,
      semanticLabel: [label, text(value), ?hint].join(', '),
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  if (hint != null) ...[
                    const SizedBox(height: 2),
                    Text(hint!, style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            // A long value (a language's name, with large text) goes on to a second line, not past the edge
            Flexible(
              child: Text(
                text(value),
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Icon(Icons.arrow_drop_down_rounded, color: AppColors.muted),
          ],
        ),
      ),
    ),
  );
}

/// [action], unless [busy]: then off, except with a remote, where a button switched off as it is
/// pressed would lose the focus for good; there it stays a stop and does nothing meanwhile.
VoidCallback? unlessBusy(bool busy, VoidCallback action) => !busy ? action : (isTv ? () {} : null);

/// Makes any child focusable and hoverable with the app's focus treatment: a slight lift and a
/// crisp white ring, separated from the child by a small gap so it reads on any content.
/// This is what makes D-pad navigation readable from the couch.
class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.child,
    required this.onTap,
    this.radius = AppRadius.card,
    this.scale = 1.04,
    this.autofocus = false,
    this.onLongPress,
    this.focusNode,
    this.semanticLabel,
    this.selected,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Picked among others (a chip, an option): said by a screen reader, as it is painted.
  final bool? selected;

  /// What a screen reader says for it, in place of what is inside it: a poster's title and rating
  /// once, rather than its image's fallback text and then its title, or nothing for an icon alone.
  final String? semanticLabel;
  final VoidCallback? onLongPress;
  final double radius;
  final double scale;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  var _focused = false, _hovered = false;

  // A remote has no long press of its own: OK held a moment is one, and so is its ☰ or info button
  static const _holdTime = Duration(milliseconds: 500);
  static final _ok = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };
  Timer? _hold; // OK down on it, until let go
  var _long = false; // held long enough for the long press

  // The ring is for remotes and keyboards; after a touch the focused item looks like any other
  bool get _keyboard => FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  void _onHighlightMode(FocusHighlightMode _) {
    if (_focused) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    _hold?.cancel();
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.dispose();
  }

  /// With a long press, OK acts once let go: a tap, or held [_holdTime] the long press. Not while
  /// held, as its repeats would then press what the long press opened.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final long = widget.onLongPress;
    if (long == null) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.info) {
      if (e is KeyDownEvent) long();
      return KeyEventResult.handled;
    }
    if (!_ok.contains(k)) return KeyEventResult.ignored;
    switch (e) {
      case KeyDownEvent():
        _hold?.cancel();
        _long = false;
        _hold = Timer(_holdTime, () => _long = true);
      case KeyUpEvent() when _hold != null:
        _hold!.cancel();
        _hold = null;
        (_long ? long : widget.onTap)?.call();
      default: // held: its repeats
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focused && _keyboard;
    final ring = focused ? AppColors.text : (_hovered ? const Color(0x59FFFFFF) : Colors.transparent);
    final well = _well(focused, ring);
    return widget.onLongPress == null
        ? well
        : Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: well);
  }

  Widget _well(bool focused, Color ring) {
    final well = _inkWell(focused, ring);
    // A screen reader is told what is picked, and what does nothing now (on a TV it still takes
    // the focus, so it looks no different to one). Always there: a node coming and going as it is
    // switched on and off would build the well anew, and the remote lose its focus
    return Semantics(
      container: widget.semanticLabel != null,
      label: widget.semanticLabel,
      selected: widget.selected,
      enabled: widget.onTap == null ? false : null,
      child: well,
    );
  }

  Widget _inkWell(bool focused, Color ring) {
    return InkWell(
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      // With a remote it stays a stop while it does nothing: one switched off as it is pressed
      // would otherwise lose the focus for good, and the screen be left with none
      onTap: widget.onTap ?? (isTv ? () {} : null),
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onLongPress, // a mouse's way to what OK held or Info opens
      onFocusChange: (f) => setState(() => _focused = f),
      onHover: (h) => setState(() => _hovered = h),
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      splashColor: Colors.white10,
      highlightColor: Colors.white10,
      borderRadius: BorderRadius.circular(widget.radius),
      child: AnimatedScale(
        scale: focused ? widget.scale : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(3),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius + 3),
            border: Border.all(color: ring, width: 2),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: widget.semanticLabel == null ? widget.child : ExcludeSemantics(child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onPressed,
    required this.background,
    required this.foreground,
    this.icon,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color background, foreground;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final fg = onPressed == null ? AppColors.subtle : foreground;
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onPressed,
      radius: AppRadius.button,
      scale: 1.03,
      child: Container(
        color: onPressed == null ? AppColors.surfaceHigh : background,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        // A label wider than its place (large text, a narrow phone) goes on to a second line rather
        // than being cut off: the screen's width is a bound to wrap against, whatever row the
        // button is in, one with no bound of its own too
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.max(120, MediaQuery.sizeOf(context).width - 96)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, color: fg, size: 22), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Main action: white with black text.
/// Asks to confirm [confirmLabel]: Cancel (or [cancelLabel], where "Cancel" would read as the
/// action itself), which has the focus, and the action, as buttons of the app's own (the TV's
/// dialogs are the same). True only when the action was chosen.
Future<bool> showConfirm(
  BuildContext context, {
  String? title,
  String? message,
  required String confirmLabel,
  String? cancelLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: title == null ? null : Text(title),
        content: message == null ? null : Text(message),
        actions: [
          SecondaryButton(
            label: cancelLabel ?? ctx.l10n.cancel,
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          PrimaryButton(label: confirmLabel, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    ) ==
    true;

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => _ActionButton(
    label: label,
    icon: icon,
    onPressed: onPressed,
    autofocus: autofocus,
    focusNode: focusNode,
    background: AppColors.text,
    foreground: AppColors.black,
  );
}

/// Secondary action: dark grey with white text.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.autofocus = false});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => _ActionButton(
    label: label,
    icon: icon,
    onPressed: onPressed,
    autofocus: autofocus,
    background: AppColors.surfaceHigh,
    foreground: AppColors.text,
  );
}

/// The app's white focus ring around a Material control that only tints itself when focused
/// (a dropdown, say), so a remote can tell where it is.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child, this.radius = AppRadius.button});

  final Widget child;
  final double radius;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  var _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (f) => setState(() => _focused = f),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      // Always one, its border see-through when not focused: from none to one the Container's root
      // changes, and the field under it is built anew, losing its focus
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional
              ? AppColors.text
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: widget.child,
    ),
  );
}

/// The height of a row of [AppChip]s with its 8 above and below: the ring, the padding and a line
/// of text, as large as the text is set.
double chipRowHeight(BuildContext context) => 16 + 20 + MediaQuery.textScalerOf(context).scale(20);

/// Takes a touch up to [extra] above or below its child as one on the child's middle, the child
/// laid out as it is (as Material's buttons take one near them): for what is drawn smaller than a
/// finger, in a row with room around it.
class WiderHit extends SingleChildRenderObjectWidget {
  const WiderHit({super.key, required this.extra, super.child});

  final double extra;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderWiderHit(extra);

  @override
  void updateRenderObject(BuildContext context, RenderWiderHit renderObject) => renderObject.extra = extra;
}

class RenderWiderHit extends RenderProxyBox {
  RenderWiderHit(this.extra);

  double extra;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    final child = this.child;
    if (child == null || !Rect.fromLTRB(0, -extra, size.width, size.height + extra).contains(position)) return false;
    final center = child.size.center(Offset.zero);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(center),
      position: center,
      hitTest: (result, _) => child.hitTest(result, position: center),
    );
  }
}

/// Selectable pill (categories, seasons, sort order, playlist type): white when selected, with
/// the same focus ring as every other element so it reads well with a TV remote.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.black : AppColors.text;
    // Low, to keep its row low on a phone on its side: a finger just above or below it takes it too
    return WiderHit(extra: 8, child: _chip(context, fg));
  }

  Widget _chip(BuildContext context, Color fg) {
    return Focusable(
      autofocus: autofocus,
      onTap: onTap,
      selected: selected,
      radius: AppRadius.pill,
      scale: 1.05,
      child: Container(
        color: selected ? AppColors.text : AppColors.surfaceHigh,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        // As a button's: a label wider than its place goes on to a second line, not past the edge
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.max(120, MediaQuery.sizeOf(context).width - 96)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Network image with a neutral placeholder; IPTV logos and posters are often missing or broken.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.icon = Icons.image_outlined, this.label});

  final String? url;
  final BoxFit fit;
  final IconData? icon; // null for backgrounds, where a centered icon would look stray
  final String? label; // shown on the placeholder, e.g. the title

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: AppColors.surface,
      child: Center(
        child: label == null
            ? (icon == null ? null : Icon(icon, color: AppColors.subtle))
            : Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  label!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
              ),
      ),
    );
    if (url == null || !url!.startsWith('http')) return fallback;
    // The placeholder stays underneath until the image fades in over it
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(child: fallback),
        _SizedNetImage(url!, fit: fit),
      ],
    );
  }
}

/// [url]'s image decoded at the size it is shown (see [fitted]), in steps, and kept at that size
/// while its box changes a little: each new size is the image downloaded and decoded again (a
/// window being resized), and meanwhile the one there stays.
class _SizedNetImage extends StatefulWidget {
  const _SizedNetImage(this.url, {required this.fit});

  final String url;
  final BoxFit fit;

  @override
  State<_SizedNetImage> createState() => _SizedNetImageState();
}

class _SizedNetImageState extends State<_SizedNetImage> {
  Size? _size; // in pixels
  var _shown = false; // it fades in once, not again at another size

  @override
  void initState() {
    super.initState();
    ImageStore.instance.want(widget.url);
  }

  @override
  void didUpdateWidget(_SizedNetImage old) {
    super.didUpdateWidget(old);
    if (old.url == widget.url) return;
    _shown = false;
    ImageStore.instance
      ..want(widget.url)
      ..unwant(old.url);
  }

  @override
  void dispose() {
    ImageStore.instance.unwant(widget.url); // scrolled past before its turn: it stops waiting
    super.dispose();
  }

  static double _step(double v) => v.isFinite ? (v / 64).ceil() * 64.0 : v;

  /// [box] in steps of 64 pixels; the size before while [box] fits in it and is more than half.
  Size _sizeFor(Size box) {
    final want = Size(_step(box.width), _step(box.height));
    final had = _size;
    final keep =
        had != null &&
        want.width <= had.width &&
        want.height <= had.height &&
        want.width * 2 > had.width &&
        want.height * 2 > had.height;
    return _size = keep ? had : want;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Image(
      key: ValueKey(widget.url), // another image starts from the placeholder, not from the one before
      image: fitted(
        StoredImage(widget.url),
        _sizeFor(box.biggest * MediaQuery.devicePixelRatioOf(context) * imageBudget.decodeScale),
        widget.fit,
      ),
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      frameBuilder: (_, child, frame, sync) {
        if (frame != null) _shown = true;
        // A fade per poster is the screen drawn again for each frame of it, which a TV stick pays for
        return sync || lowMemory
            ? child
            : AnimatedOpacity(opacity: _shown ? 1 : 0, duration: const Duration(milliseconds: 250), child: child);
      },
    ),
  );
}

/// Small rating label with a star, e.g. on posters.
class RatingBadge extends StatelessWidget {
  const RatingBadge(this.rating, {super.key});

  final double rating;

  @override
  Widget build(BuildContext context) {
    final small = isShort(context); // on a phone's smaller posters
    return Panel(
      radius: small ? 5 : 6,
      color: AppColors.scrim,
      padding: small
          ? const EdgeInsets.symmetric(horizontal: 5, vertical: 2)
          : const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: small ? 11 : 13, color: AppColors.text),
          SizedBox(width: small ? 2 : 3),
          Text(
            rating.toStringAsFixed(1),
            style: TextStyle(fontSize: small ? 10.5 : 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Poster tile used in rails and grids.
/// In place of a backdrop a title does not have: a flat surface with its poster, sharp, at the
/// right, rather than the poster blown up and blurred (heavy on a modest device, and not this
/// app's flat look).
class PosterInPlace extends StatelessWidget {
  const PosterInPlace(this.poster, {super.key});

  final String? poster;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.surface,
    child: poster == null
        ? null
        : Align(
            alignment: Alignment.centerRight,
            child: FractionallySizedBox(
              heightFactor: 0.7,
              child: Padding(
                padding: EdgeInsets.only(right: 48 + MediaQuery.paddingOf(context).right),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: NetImage(poster, icon: null),
                  ),
                ),
              ),
            ),
          ),
  );
}

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.poster,
    this.rating,
    this.note,
    this.autofocus = false,
    this.rank,
  });

  final String title;
  final String? poster;
  final double? rating;
  final String? note; // a line under the title, such as why it was picked
  final int? rank; // its place in a top-ten row, drawn beside it: said first
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Focusable(
          autofocus: autofocus,
          onTap: onTap,
          semanticLabel: [
            if (rank != null) ?context.l10nOrNull?.rankLabel(rank!),
            title,
            if (rating != null && rating! > 0) context.l10n.ratingOf(rating!.toStringAsFixed(1)),
            ?note,
          ].join(', '),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetImage(poster, label: title),
              if (rating != null && rating! > 0)
                Positioned(top: isShort(context) ? 6 : 8, right: isShort(context) ? 6 : 8, child: RatingBadge(rating!)),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      // Said with the poster already: not a second stop for a screen reader
      ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: isShort(context) ? 12 : 13, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      if (note != null)
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(3, 2, 3, 0),
            child: Text(
              note!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.3),
            ),
          ),
        ),
    ],
  );
}

/// Section title with an optional trailing action ("See all").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: isShort(context) ? const EdgeInsets.fromLTRB(24, 14, 12, 4) : const EdgeInsets.fromLTRB(24, 24, 16, 10),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: isShort(context)
                  ? Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17)
                  : Theme.of(context).textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(action!, style: const TextStyle(fontWeight: FontWeight.w600)),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Capy TV's mascot, shared with the platform launcher icons.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/branding/capy-icon.svg', width: size, height: size);
}

/// A thin white progress line on a dim track.
class ProgressLine extends StatelessWidget {
  const ProgressLine(this.value, {super.key, this.height = 3});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.l10nOrNull?.watchedPercent((value.clamp(0, 1) * 100).round()),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: const Color(0x33FFFFFF),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0, 1),
          child: Container(color: AppColors.text),
        ),
      ),
    ),
  );
}
