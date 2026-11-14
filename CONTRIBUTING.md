# Contributing

Thanks for helping with Capy TV. Bug reports, translations and pull requests are welcome.

## Before you start

- **Bugs**: open an issue saying the device, the app's version (Settings → About) and what
  happened. Never paste a provider's address, user or password: say "an Xtream account" or
  "an M3U list" instead.
- **Security problems**: report them in private, as [SECURITY.md](SECURITY.md) says.
- **Bigger changes**: open an issue first, so we can agree on the approach before you write it.

How to build and test each part: [docs/development.md](docs/development.md).

## Pull requests

- Keep each pull request to one change, with tests for what it fixes or adds.
- Run the checks CI runs before you push: `app/tool/test_all.sh`, or at least
  `dart format --page-width 120`, `flutter analyze` and `flutter test` in `app/`, and
  `go vet ./... && go test ./...` in `server/` when you touch it.
- A change to what the app shows goes in English and Spanish (`app/lib/l10n/app_en.arb` and
  `app_es.arb`), then `flutter gen-l10n`. A change to the Flutter app usually has its twin in the
  Samsung TV app (`tizen/`).
- Never commit credentials, provider addresses with credentials in them, or real media. Tests use
  made-up providers (`*.example`, `*.test`) and generated streams.

## Writing

- Code, comments and docs are in English. UI text lives in `app/lib/l10n/*.arb`: English is the
  template, and each language has a file of its own.
- Punctuation: a message of one short sentence (a snackbar, an error under a field) has no final
  period; one of two sentences or more, and all body text, ends each with one. Titles, buttons and
  labels have none. English uses straight quotes and apostrophes ("Live", don't) and the short
  forms for what failed (*couldn't*, *can't*).
- In English, what the heart saves is *Favorites*.
- Spanish is neutral Latin American Spanish, one word per thing:
  - *celular*, not *móvil* or *teléfono*;
  - *agregar*, *en vivo*, *video*, *la TV*, *vence*;
  - *control remoto* (on the phone page's tab, *Control*);
  - *dispositivo*, not *equipo*;
  - *Favoritos* for what the heart saves, and *lista* only for a provider's;
  - *respaldo* for a backup, and *copia* only for another copy of a title;
  - *clave* for pairing, and *llave* only for the recovery key;
  - *servidor de sincronización*, not *Sync*;
  - « » for quotes.

## License

By contributing you agree that your contribution is licensed under the
[Mozilla Public License 2.0](LICENSE), like the rest of the project.
