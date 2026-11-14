// Calls window.capyReady(), which web/index.html defines to fade its splash away.
import 'dart:js_interop';

@JS('capyReady')
external void _capyReady();

void notifyReady() {
  try {
    _capyReady();
  } on Object {
    // The page is not ours (a test, an embed): there is no splash to take away
  }
}
