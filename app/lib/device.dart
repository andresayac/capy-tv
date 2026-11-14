import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform.dart';

const _channel = MethodChannel('iptv_player/device');

/// True on Android TV, Google TV, Fire TV and TV boxes: everything is driven by a remote.
var isTv = false;

/// Little memory for everything, as on a 1 GB TV stick: no trailers playing behind pages (a web
/// view with YouTube's player takes a few hundred MB), fewer decoded images kept for later.
var lowMemory = false;

/// The device's memory and the room left on its disk, where the platform says (Android).
int? memoryMb, freeStorageMb;

/// What a device can afford, from a 1 GB TV stick up. Computers and iPhones do not say, and have plenty.
enum DeviceTier { low, medium, high }

DeviceTier get deviceTier => switch (memoryMb) {
  _ when lowMemory => DeviceTier.low,
  final mb? when mb < 3584 => DeviceTier.medium,
  _ => DeviceTier.high,
};

/// What images may take on this device: decoded in memory, kept on disk, coming at once, read ahead
/// of what a list shows (logical pixels), and their size against what they are shown at.
typedef ImageBudget = ({int decodedMb, int diskMb, int downloads, double readAhead, double decodeScale});

ImageBudget get imageBudget => switch (deviceTier) {
  DeviceTier.low => const (decodedMb: 50, diskMb: 150, downloads: 4, readAhead: 250, decodeScale: 0.75),
  DeviceTier.medium => const (decodedMb: 100, diskMb: 300, downloads: 6, readAhead: 500, decodeScale: 1),
  DeviceTier.high => const (decodedMb: 256, diskMb: 1024, downloads: 10, readAhead: 1000, decodeScale: 1),
};

/// The MB of images to keep on disk: [budgetMb], at most a tenth of the [freeMb] left, and none when
/// little is left: the room is the user's first.
int imagesOnDiskMb(int budgetMb, int? freeMb) {
  if (freeMb == null) return budgetMb;
  if (freeMb < 300) return 0;
  return freeMb ~/ 10 < budgetMb ? freeMb ~/ 10 : budgetMb;
}

/// TVs and computers offer a phone the companion page (add playlists, remote, backups); a phone
/// is the one that scans, so it does not offer it itself.
bool get offersCompanion => isTv || isWindows || isLinux || isMacOS;

/// How the device calls itself ("Living room TV", "DESKTOP-1234"), shown to a connected phone.
var deviceName = localHostname;

/// Phones and tablets show the app the way a TV does: always landscape, full screen (the system
/// bars come back with a swipe and hide again).
Future<void> useLandscapeFullScreen() async {
  if (!isAndroid && !isIOS) return;
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}

/// How this Android device is used, as chosen in Settings: 'tv' (a remote), 'touch' (a phone or
/// a tablet), or '' as the device says. A cheap box may claim a touch screen it has not got. Read
/// at startup, where the layouts are chosen: a change applies on the next start.
var deviceMode = '';

const _deviceModeKey = 'device.mode';

Future<void> setDeviceMode(String mode) async {
  deviceMode = mode;
  try {
    await (await SharedPreferences.getInstance()).setString(_deviceModeKey, mode);
  } on Object {
    // Not kept: the device says, as before
  }
}

/// Asks the platform once at startup (see MainActivity.kt).
Future<void> detectDevice() async {
  if (!isAndroid) return;
  try {
    deviceMode = (await SharedPreferences.getInstance()).getString(_deviceModeKey) ?? '';
  } on Object {
    deviceMode = '';
  }
  // Each on its own: one that fails must not undo the others, a TV taken for a phone
  isTv = switch (deviceMode) {
    'tv' => true,
    'touch' => false,
    _ => await _ask<bool>('isTv') ?? false,
  };
  deviceName = await _ask<String>('deviceName') ?? deviceName;
  lowMemory = await _ask<bool>('lowMemory') ?? false;
  memoryMb = await _ask<int>('memoryMb');
  freeStorageMb = await _ask<int>('freeStorageMb');
}

/// Whether the network in use is paid by the amount (mobile data, a hotspot): Android says; elsewhere
/// it is taken as not.
Future<bool> networkMetered() async => await _ask<bool>('metered') ?? false;

Future<T?> _ask<T>(String method) async {
  try {
    return await _channel.invokeMethod<T>(method);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
