import 'package:flutter/foundation.dart';

/// A write to the device's storage failed, a full disk usually: what is on screen is not saved.
final storageFailed = ValueNotifier<bool>(false);

/// Waits for [write], one of the preferences', and raises [storageFailed] if it did not reach the disk.
Future<void> saveOrFlag(Future<bool> write) async {
  try {
    if (!await write) storageFailed.value = true;
  } on Object {
    storageFailed.value = true;
  }
}
