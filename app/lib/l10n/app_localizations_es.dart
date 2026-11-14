// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Capy TV';

  @override
  String get playlists => 'Listas';

  @override
  String get addPlaylist => 'Agregar lista';

  @override
  String get playlistTypeXtream => 'Usuario y contraseña (Xtream)';

  @override
  String get playlistTypeM3u => 'Enlace (M3U)';

  @override
  String get playlistKindXtream => 'Xtream Codes';

  @override
  String get playlistName => 'Nombre';

  @override
  String get serverUrl => 'URL del servidor';

  @override
  String get username => 'Usuario';

  @override
  String get password => 'Contraseña';

  @override
  String get m3uUrl => 'URL de la lista M3U';

  @override
  String get save => 'Guardar';

  @override
  String get cancel => 'Cancelar';

  @override
  String get delete => 'Eliminar';

  @override
  String deletePlaylistQuestion(String name) {
    return '¿Eliminar «$name»?';
  }

  @override
  String get connecting => 'Conectando…';

  @override
  String get required => 'Obligatorio';

  @override
  String get liveTv => 'TV';

  @override
  String get movies => 'Películas';

  @override
  String get series => 'Series';

  @override
  String get nothingHere => 'No hay contenido';

  @override
  String get retry => 'Reintentar';

  @override
  String get play => 'Reproducir';

  @override
  String season(int n) {
    return 'Temporada $n';
  }

  @override
  String get seasonSpecials => 'Especiales';

  @override
  String minutes(int n) {
    return '$n min';
  }

  @override
  String get status => 'Estado';

  @override
  String get expires => 'Vence';

  @override
  String get neverExpires => 'Nunca';

  @override
  String get connections => 'Conexiones';

  @override
  String connectionsValue(int active, int max) {
    return '$active de $max en uso';
  }

  @override
  String get outputFormats => 'Formatos de salida';

  @override
  String get serverTimezone => 'Zona horaria del servidor';

  @override
  String get providerMessage => 'Mensaje del proveedor';

  @override
  String sentFrom(String device) {
    return 'Enviado desde $device';
  }

  @override
  String get switchPlaylist => 'Cambiar de lista';

  @override
  String get trialAccount => 'Cuenta de prueba';

  @override
  String get nowPlaying => 'Ahora';

  @override
  String get upNext => 'Después';

  @override
  String get noGuide => 'Este canal no tiene guía';

  @override
  String catchupDays(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: '$n días', one: '1 día');
    return 'Programas anteriores: $_temp0';
  }

  @override
  String get audioAndSubtitles => 'Audio y subtítulos';

  @override
  String get audio => 'Audio';

  @override
  String get subtitles => 'Subtítulos';

  @override
  String get off => 'Desactivados';

  @override
  String get notAvailable => 'No disponible';

  @override
  String get speed => 'Velocidad';

  @override
  String get normalSpeed => 'Normal';

  @override
  String get live => 'EN VIVO';

  @override
  String trackN(int n) {
    return 'Pista $n';
  }

  @override
  String languageName(String code) {
    String _temp0 = intl.Intl.selectLogic(code, {
      'spa': 'Español',
      'eng': 'Inglés',
      'fra': 'Francés',
      'deu': 'Alemán',
      'ita': 'Italiano',
      'por': 'Portugués',
      'jpn': 'Japonés',
      'kor': 'Coreano',
      'zho': 'Chino',
      'ara': 'Árabe',
      'rus': 'Ruso',
      'other': '$code',
    });
    return '$_temp0';
  }

  @override
  String listPartsMissing(String names) {
    return '$names no respondió: las listas siguen como estaban.';
  }

  @override
  String get errorBadAddress => 'Revisa la dirección del servidor: tal como está escrita no puede ser una.';

  @override
  String get errorWrongServer => 'Revisa la dirección del servidor, el usuario y la contraseña.';

  @override
  String get errorProviderBusy => 'Tu proveedor está saturado o caído un rato. Prueba de nuevo en unos minutos.';

  @override
  String get errorNoSpace =>
      'No queda espacio en este dispositivo para la lista. Libera espacio y vuelve a intentarlo.';

  @override
  String get errorOffline =>
      'Este dispositivo parece estar sin conexión. Revisa el Wi-Fi o el cable y vuelve a intentarlo.';

  @override
  String get errorDns =>
      'No se encontró el nombre del servidor. Revisa que este dispositivo tenga internet y que la dirección esté bien escrita.';

  @override
  String get errorTls =>
      'Falló la conexión segura con el servidor. Revisa la fecha y la hora de este dispositivo: si están mal, ninguna conexión segura funciona.';

  @override
  String get errorUnreachable =>
      'No se pudo conectar con el servidor. Revisa la dirección y tu conexión; si están bien, puede que el proveedor esté caído.';

  @override
  String get errorTimeout => 'El servidor no responde.';

  @override
  String get errorUnauthorized => 'Usuario o contraseña incorrectos, o la cuenta está bloqueada.';

  @override
  String errorInactive(String status) {
    return 'La cuenta no está activa ($status). Pide a tu proveedor que la renueve o la reactive.';
  }

  @override
  String get statusActive => 'Activa';

  @override
  String get statusExpired => 'Vencida';

  @override
  String get statusBanned => 'Bloqueada';

  @override
  String get statusDisabled => 'Desactivada';

  @override
  String get statusTrial => 'De prueba';

  @override
  String get statusUnknown => 'Desconocido';

  @override
  String get untitled => 'Sin título';

  @override
  String get ungrouped => 'Sin categoría';

  @override
  String episodeNumber(int number) {
    return 'Episodio $number';
  }

  @override
  String errorHttp(String code) {
    return 'El servidor respondió con el error $code. Vuelve a intentarlo en un rato; si sigue, consulta a tu proveedor.';
  }

  @override
  String get errorBadResponse => 'El servidor no devolvió una respuesta válida.';

  @override
  String get errorNotFound => 'El servidor no lo tiene. Revisa la dirección; si está bien, consulta a tu proveedor.';

  @override
  String get errorEmptyPlaylist => 'La lista está vacía o no es un archivo M3U válido.';

  @override
  String get errorUnknown => 'Algo salió mal. Vuelve a intentarlo; si sigue pasando, reinicia la app.';

  @override
  String get seeAll => 'Ver todo';

  @override
  String get details => 'Detalles';

  @override
  String get welcomeTitle => 'Tu TV, a tu manera';

  @override
  String get welcomeBody =>
      'Conecta tu servicio de TV con los datos que te dio tu proveedor: usuario y contraseña, o un enlace. La app no incluye canales: usas tu propia suscripción.';

  @override
  String episodesCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: '$n episodios', one: '1 episodio');
    return '$_temp0';
  }

  @override
  String get watchLive => 'Ver en vivo';

  @override
  String get home => 'Inicio';

  @override
  String get search => 'Buscar';

  @override
  String get searchHint => 'Películas, series, canales o lo que están dando';

  @override
  String get myList => 'Favoritos';

  @override
  String get inMyList => 'En favoritos';

  @override
  String get continueWatching => 'Continuar viendo';

  @override
  String get recentChannels => 'Canales vistos recientemente';

  @override
  String get favoriteChannels => 'Canales favoritos';

  @override
  String get favoriteMovies => 'Películas favoritas';

  @override
  String get favoriteSeries => 'Series favoritas';

  @override
  String get homeEmptyTitle => 'Hazla tuya';

  @override
  String get homeEmptyBody => 'Lo que veas y agregues a favoritos aparecerá aquí, listo para seguir donde lo dejaste.';

  @override
  String resumedFrom(String time) {
    return 'Reanudando desde $time';
  }

  @override
  String get startOver => 'Empezar de nuevo';

  @override
  String get nextEpisode => 'Siguiente episodio';

  @override
  String get nextChannel => 'Siguiente canal';

  @override
  String get channelUnavailable => 'Este canal no está emitiendo ahora';

  @override
  String get reconnecting => 'Reconectando…';

  @override
  String get videoUnavailable => 'No se pudo reproducir este video';

  @override
  String get unavailableHint =>
      'Tu proveedor no lo está enviando en este momento. Vuelve a intentarlo en un rato o elige otra cosa.';

  @override
  String get continueAction => 'Continuar';

  @override
  String get settings => 'Ajustes';

  @override
  String get playback => 'Reproducción';

  @override
  String get appLanguage => 'Idioma de la app';

  @override
  String get appLanguageDevice => 'Como el dispositivo';

  @override
  String get languageSelf => 'Español';

  @override
  String get advanced => 'Avanzado';

  @override
  String get preferredAudio => 'Idioma de audio preferido';

  @override
  String get preferredSubtitles => 'Subtítulos preferidos';

  @override
  String get automatic => 'Automático';

  @override
  String get liveFormat => 'Formato de los directos';

  @override
  String get liveFormatTs => 'MPEG-TS (más compatible)';

  @override
  String get liveFormatHls => 'HLS (m3u8)';

  @override
  String get decoder => 'Decodificador de video';

  @override
  String get decoderHardware => 'Hardware (recomendado)';

  @override
  String get decoderSoftware => 'Software (compatibilidad)';

  @override
  String get failMissing =>
      'El proveedor ya no lo tiene en esta dirección. Prueba a actualizar la lista o elige otra cosa.';

  @override
  String get failDenied =>
      'El proveedor lo rechazó. Vuelve a intentarlo en un rato; si sigue, consulta a tu proveedor.';

  @override
  String get failNetwork => 'No se puede llegar al proveedor. Revisa la conexión a internet de este dispositivo.';

  @override
  String get decoderHint =>
      'La señal llegó, pero la imagen no arrancó. En Ajustes, Reproducción, Avanzado, cambia Decodificador de video a Software.';

  @override
  String get noResults => 'Sin resultados';

  @override
  String get clearHistory => 'Borrar historial de reproducción';

  @override
  String get clearHistoryQuestion =>
      '¿Borrar lo que vio este perfil en esta lista? Con sincronización, también en todos tus dispositivos.';

  @override
  String get removeFromContinue => 'Quitado de «Continuar viendo»';

  @override
  String get deletePlaylistEverywhere =>
      'Con la sincronización activa, se quita de todos los dispositivos de esta cuenta.';

  @override
  String get historyCleared => 'Historial borrado';

  @override
  String get loadingCatalog => 'Cargando el catálogo completo…';

  @override
  String get organizingCatalog => 'Organizando tu catálogo…';

  @override
  String get importedPlaylist => 'En la lista';

  @override
  String importedCount(String count) {
    return '$count importados';
  }

  @override
  String downloadingCatalogPercent(int percent) {
    return 'Descargando el catálogo… $percent %';
  }

  @override
  String downloadingCatalogSize(String size) {
    return 'Descargando el catálogo… $size MB';
  }

  @override
  String get typeToSearch => 'Escribe al menos 2 letras';

  @override
  String minutesLeft(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: 'Quedan $n min', one: 'Queda 1 min');
    return '$_temp0';
  }

  @override
  String get tvGuide => 'Guía de TV';

  @override
  String get holdOkHint => 'Mantén OK o pulsa Info sobre un programa: sus detalles, verlo de nuevo y grabarlo';

  @override
  String get recentlyAdded => 'Recién agregadas';

  @override
  String get topRated => 'Mejor valoradas';

  @override
  String get newReleases => 'Estrenos';

  @override
  String get newEpisodes => 'Nuevos episodios';

  @override
  String get newMovies => 'Nuevas películas';

  @override
  String get sortRecent => 'Más recientes';

  @override
  String get sortTitle => 'A–Z';

  @override
  String get trailer => 'Tráiler';

  @override
  String get moreLikeThis => 'Más títulos similares';

  @override
  String get director => 'Dirección';

  @override
  String get cast => 'Reparto';

  @override
  String get releaseDate => 'Estreno';

  @override
  String get country => 'País';

  @override
  String get duration => 'Duración';

  @override
  String get quality => 'Calidad';

  @override
  String hoursMinutes(int h, int m) {
    return '$h h $m min';
  }

  @override
  String seasonsCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: '$n temporadas', one: '1 temporada');
    return '$_temp0';
  }

  @override
  String get connectPhone => 'Conecta tu celular';

  @override
  String get connectPhoneBody =>
      'Escanea el código con la cámara del celular. Se abrirá una página para agregar listas con el teclado del celular, usarlo como control remoto y mover tus listas entre dispositivos.';

  @override
  String connectSameNetwork(String device) {
    return 'El celular y $device deben estar en la misma Wi-Fi.';
  }

  @override
  String get connectOrOpen => 'O abre esta dirección en cualquier dispositivo:';

  @override
  String get connectWaiting => 'Esperando a tu celular…';

  @override
  String get connectRemoteOn => 'Tu celular está conectado como control remoto';

  @override
  String get connectNoNetwork => 'Conecta este dispositivo a Wi-Fi o Ethernet para usar el celular.';

  @override
  String connectAnyNetwork(String device) {
    return 'El celular solo necesita internet: no hace falta que esté en la misma Wi-Fi que $device.';
  }

  @override
  String get connectNeedsServer => 'Configura un servidor en Sincronizar para usar el celular con esta TV.';

  @override
  String get connectServerDown => 'El servidor de sincronización no responde ahora. Inténtalo en un momento.';

  @override
  String get addFromPhone => 'Usar el celular';

  @override
  String playlistReceived(String name) {
    return '«$name» agregada desde el celular';
  }

  @override
  String backupReceived(int added, int updated) {
    String _temp0 = intl.Intl.pluralLogic(added, locale: localeName, other: '$added nuevas', one: '1 nueva');
    String _temp1 = intl.Intl.pluralLogic(
      updated,
      locale: localeName,
      other: '$updated actualizadas',
      one: '1 actualizada',
    );
    return 'Listas recibidas: $_temp0, $_temp1';
  }

  @override
  String get phoneConnected => 'Celular conectado como control remoto';

  @override
  String pairTitle(String device) {
    return 'Conectado a $device';
  }

  @override
  String pairBody(String device) {
    return 'Mueve tus listas, perfiles, favoritos, historial y ajustes entre este celular y $device. Todo va directo por tu Wi-Fi.';
  }

  @override
  String pairSend(String device) {
    return 'Enviar todo a $device';
  }

  @override
  String pairReceive(String device) {
    return 'Traer las listas de $device';
  }

  @override
  String get pairRemote => 'Usar este celular como control remoto';

  @override
  String pairSent(int added, int updated, String device) {
    String _temp0 = intl.Intl.pluralLogic(
      added,
      locale: localeName,
      other: '$added listas nuevas',
      one: '1 lista nueva',
    );
    String _temp1 = intl.Intl.pluralLogic(
      updated,
      locale: localeName,
      other: '$updated actualizadas',
      one: '1 actualizada',
    );
    return 'Enviado a $device: $_temp0, $_temp1';
  }

  @override
  String pairReceived(int added, int updated) {
    String _temp0 = intl.Intl.pluralLogic(
      added,
      locale: localeName,
      other: '$added listas nuevas',
      one: '1 lista nueva',
    );
    String _temp1 = intl.Intl.pluralLogic(
      updated,
      locale: localeName,
      other: '$updated actualizadas',
      one: '1 actualizada',
    );
    return 'Recibido: $_temp0, $_temp1';
  }

  @override
  String pairFailed(String device) {
    return 'No se pudo conectar con $device. Vuelve a escanear su código: cambia cada vez.';
  }

  @override
  String get webTabAdd => 'Agregar lista';

  @override
  String get webTabRemote => 'Control';

  @override
  String get webTabBackup => 'Respaldo';

  @override
  String get webAddTitle => 'Agrega una lista';

  @override
  String webAddBody(String device) {
    return 'Escríbela aquí, con el teclado del celular. $device la comprueba con tu proveedor y la guarda.';
  }

  @override
  String get webShow => 'Ver';

  @override
  String get showPassword => 'Mostrar contraseña';

  @override
  String get hidePassword => 'Ocultar contraseña';

  @override
  String get webHide => 'Ocultar';

  @override
  String webSendToDevice(String device) {
    return 'Enviar a $device';
  }

  @override
  String get webChecking => 'Comprobando con tu proveedor…';

  @override
  String webAddedTitle(String name, String device) {
    return '«$name» ya está en $device';
  }

  @override
  String get webAddedBody => 'Ya puedes abrirla allí.';

  @override
  String get webAddAnother => 'Agregar otra';

  @override
  String webLostConnection(String device) {
    return 'No se pudo conectar con $device. ¿Sigue encendido y en esta Wi-Fi?';
  }

  @override
  String get webRelayWaiting => 'Conectando con la TV…';

  @override
  String get webRelayNoAnswer => 'La TV no responde. Revisa que siga encendida y con Capy TV abierta.';

  @override
  String get webRelayExpired => 'Esta página venció. Vuelve a escanear el código en la TV.';

  @override
  String webRelayLostConnection(String device) {
    return 'No se pudo conectar con $device. ¿Sigue encendido y con la app abierta?';
  }

  @override
  String webExpired(String device) {
    return 'Esta página venció. Vuelve a escanear el código en $device.';
  }

  @override
  String get webNowPlaying => 'Reproduciendo';

  @override
  String get webNothingPlaying => 'Nada en reproducción';

  @override
  String get webBack => 'Atrás';

  @override
  String get webPlayPause => 'Play/Pausa';

  @override
  String get webChannelDown => 'Canal −';

  @override
  String get webChannelUp => 'Canal +';

  @override
  String get webSend => 'Enviar';

  @override
  String webTypePlaceholder(String device) {
    return 'Buscar en $device';
  }

  @override
  String get webTypeHint => 'Lo que escribas sustituye el texto del campo seleccionado en pantalla, o busca.';

  @override
  String webConnectedTo(String device) {
    return 'Conectado a $device';
  }

  @override
  String get webReconnecting => 'Reconectando…';

  @override
  String get webBackupTitle => 'Guarda o mueve tus listas';

  @override
  String get webBackupBody =>
      'Un respaldo lleva tus listas con sus contraseñas, todos los perfiles con su PIN y lo que vio y guardó cada uno, y tus ajustes. Guárdalo en un sitio privado.';

  @override
  String get webDownloadBackup => 'Descargar un respaldo';

  @override
  String get webDownloadHint => 'Se guarda en este celular como archivo.';

  @override
  String get webRestoreBackup => 'Restaurar un respaldo';

  @override
  String get webRestoreHint => 'Las listas que ya existan se actualizan, no se duplican.';

  @override
  String webRestored(String added, String updated, String device) {
    return 'Listo en $device. Listas nuevas: $added · Actualizadas: $updated';
  }

  @override
  String get webNotBackup => 'Ese archivo no es un respaldo de Capy TV.';

  @override
  String get webBackupNewer => 'Este respaldo es de una versión más nueva de Capy TV: actualiza primero la app aquí.';

  @override
  String get webBackupSaved => 'Respaldo guardado en tus descargas.';

  @override
  String get webWorking => 'Un momento…';

  @override
  String get webSent => 'Enviado';

  @override
  String webOpenAppBody(String device) {
    return '¿Tienes Capy TV en este celular? Ábrelo para enviar tus listas a $device o traerlas aquí.';
  }

  @override
  String get webOpenApp => 'Abrir la app';

  @override
  String webPrivacy(String device) {
    return 'Todo queda entre este celular y $device, en tu red.';
  }

  @override
  String webRelayPrivacy(String device) {
    return 'El servidor solo pasa lo que se dicen este celular y $device, cerrado con una clave que solo tienen ellos dos.';
  }

  @override
  String get webUp => 'Arriba';

  @override
  String get webDown => 'Abajo';

  @override
  String get webLeft => 'Izquierda';

  @override
  String get webRight => 'Derecha';

  @override
  String get close => 'Cerrar';

  @override
  String get editPlaylist => 'Editar lista';

  @override
  String get moveHistory => 'Traer favoritos e historial de otra lista';

  @override
  String get moveHistoryChoose => '¿De qué lista?';

  @override
  String get moveHistoryWorking => 'Buscando tus títulos en esta lista…';

  @override
  String moveHistoryDone(int moved, int missing) {
    String _temp0 = intl.Intl.pluralLogic(
      moved,
      locale: localeName,
      other: '$moved elementos traídos',
      one: '1 elemento traído',
      zero: 'No se encontró nada en esta lista',
    );
    String _temp1 = intl.Intl.pluralLogic(
      missing,
      locale: localeName,
      other: '; $missing no están en esta lista',
      one: '; 1 no está en esta lista',
      zero: '',
    );
    return '$_temp0$_temp1';
  }

  @override
  String get sync => 'Sincronizar';

  @override
  String get syncTitle => 'Tus listas en todas partes';

  @override
  String get syncBody =>
      'Inicia sesión en cada dispositivo y tus listas, favoritos y progreso te siguen. Todo se cifra en el dispositivo antes de salir: el servidor lo guarda pero no puede leerlo. Solo las recomendaciones, si tu servidor las da, le envían de forma legible los títulos para recomendar.';

  @override
  String get syncServer => 'Servidor de sincronización';

  @override
  String get syncEmail => 'Correo';

  @override
  String get syncPassword => 'Contraseña';

  @override
  String get syncPasswordAgain => 'Repite la contraseña';

  @override
  String get syncSignIn => 'Iniciar sesión';

  @override
  String get syncCreate => 'Crear cuenta de sincronización';

  @override
  String get syncToCreate => '¿Primera vez? Crea una cuenta';

  @override
  String get syncToSignIn => '¿Ya tienes cuenta? Inicia sesión';

  @override
  String get syncPasswordNote =>
      'Solo tú conoces esta contraseña. Después recibes una llave de recuperación: guárdala, es la única forma de volver a entrar si olvidas la contraseña.';

  @override
  String get syncWorking => 'Protegiendo tus claves…';

  @override
  String get syncErrorServer => 'Usa una dirección https:// (http solo en tu red local)';

  @override
  String get syncErrorEmail => 'Escribe un correo válido';

  @override
  String get syncErrorShort => 'Usa al menos 8 caracteres';

  @override
  String get syncErrorMismatch => 'Las contraseñas no coinciden';

  @override
  String get syncErrorCredentials => 'Correo o contraseña incorrectos';

  @override
  String get syncErrorExists => 'Ya existe una cuenta con este correo';

  @override
  String get syncErrorRateLimited => 'Demasiados intentos. Prueba en un minuto.';

  @override
  String get syncErrorNetwork => 'No se puede conectar con el servidor de sincronización';

  @override
  String get syncErrorFailed => 'El servidor de sincronización tuvo un problema. Inténtalo más tarde.';

  @override
  String syncStatusSynced(String time) {
    return 'Al día · $time';
  }

  @override
  String get syncStatusSyncing => 'Sincronizando…';

  @override
  String get syncStatusOffline => 'Sin conexión. Los cambios saldrán cuando vuelva el servidor.';

  @override
  String get syncStatusExpired => 'Tu sesión terminó. Vuelve a iniciar sesión.';

  @override
  String get syncExpiredNotice =>
      'La sincronización se detuvo: la sesión terminó. Vuelve a iniciar sesión en Ajustes, Sincronizar.';

  @override
  String get syncStatusOff => 'Desactivada';

  @override
  String get syncNow => 'Sincronizar ahora';

  @override
  String get syncDevices => 'Dispositivos con sesión';

  @override
  String syncSeen(String time) {
    return 'Visto $time';
  }

  @override
  String get syncSignOut => 'Cerrar sesión';

  @override
  String get syncSignOutConfirm =>
      '¿Cerrar la sesión de este dispositivo? Lo que tiene se queda aquí, pero no recibe nada nuevo hasta que vuelvas a iniciarla.';

  @override
  String get syncDeleteAccount => 'Eliminar cuenta';

  @override
  String get syncDeleteConfirm =>
      '¿Eliminar la cuenta y todo lo sincronizado? Cada dispositivo conserva sus propias listas e historial.';

  @override
  String get syncSignedOut => 'Sesión cerrada. Todo sigue en este dispositivo.';

  @override
  String get whoIsWatching => '¿Quién está viendo?';

  @override
  String get profileYou => 'Tú';

  @override
  String get profiles => 'Perfiles';

  @override
  String get profilesTitle => 'Perfiles y control parental';

  @override
  String get profilesBody =>
      'Cada perfil tiene sus propios favoritos, historial y «Continuar viendo». Los perfiles infantiles nunca muestran contenido para adultos.';

  @override
  String get addProfile => 'Agregar perfil';

  @override
  String get editProfile => 'Editar perfil';

  @override
  String get profileName => 'Nombre';

  @override
  String get kidsProfile => 'Infantil';

  @override
  String get kidsAdultTitle => 'Este título es para mayores y este perfil no puede verlo.';

  @override
  String get kidsProfileHint => 'Nunca muestra contenido para adultos.';

  @override
  String get kidsProfileNoPinHint =>
      'Nunca muestra contenido para adultos. Al guardarlo te pedirá un PIN parental, para que un niño no pueda desactivarlo.';

  @override
  String get kidsPinTitle => 'Un PIN para que un niño no cambie esto';

  @override
  String get adultPinTitle => 'Un PIN para que solo los adultos vean esto';

  @override
  String get lockProfile => 'Pedir el PIN';

  @override
  String get lockProfileHint => 'Solo quien sepa su PIN podrá abrir este perfil.';

  @override
  String get profilePin => 'PIN de este perfil';

  @override
  String enterPinOf(String name) {
    return 'PIN de $name';
  }

  @override
  String get enterPinMain => 'Tu PIN';

  @override
  String get forgotPin => 'Olvidé el PIN';

  @override
  String get forgotPinAccount =>
      'Escribe la contraseña de tu cuenta de sincronización para quitar el PIN parental de todos tus dispositivos.';

  @override
  String get forgotPinNoAccount =>
      'Sin cuenta de sincronización no hay forma de comprobar que eres tú: la única salida es borrar los datos de la app o reinstalarla, y se pierden los perfiles, listas e historial de este dispositivo.';

  @override
  String forgotPinProfile(String name) {
    return 'Para volver a usarlo hay que borrar a $name, con sus favoritos y su historial. Nadie verá lo que se vio.';
  }

  @override
  String forgotPinMain(String name) {
    return 'Se borrarán los favoritos y el historial de $name y se quitará su PIN. Nadie verá lo que se vio.';
  }

  @override
  String get forgotPinMainUnnamed =>
      'Se borrarán los favoritos y el historial de este perfil y se quitará su PIN. Nadie verá lo que se vio.';

  @override
  String get showAdult => 'Mostrar contenido para adultos';

  @override
  String get showAdultHint =>
      'Categorías para adultos (XXX, +18…) y lo que el proveedor marque como adulto. Oculto de forma predeterminada.';

  @override
  String get deleteProfile => 'Eliminar perfil';

  @override
  String deleteProfileQuestion(String name) {
    return '¿Eliminar a $name? Se borran sus favoritos e historial.';
  }

  @override
  String get parentalPin => 'PIN parental';

  @override
  String get parentalPinBody => 'Se pide para cambiar estos ajustes. Cada perfil puede tener además su propio PIN.';

  @override
  String get setPin => 'Crear PIN';

  @override
  String get changePin => 'Cambiar PIN';

  @override
  String get removePin => 'Quitar PIN';

  @override
  String get enterPin => 'Escribe el PIN';

  @override
  String get newPin => 'PIN nuevo';

  @override
  String get repeatPin => 'Repite el PIN';

  @override
  String get wrongPin => 'PIN incorrecto';

  @override
  String get pinMismatch => 'Los PIN no coinciden';

  @override
  String get pinSaved => 'PIN guardado';

  @override
  String get pinRemoved => 'PIN quitado';

  @override
  String get storageFull => 'No se pudieron guardar los cambios: puede que este dispositivo no tenga espacio.';

  @override
  String get noSecureStorage => 'Este dispositivo no tiene almacén seguro: la contraseña no se guardó.';

  @override
  String get startupFailed => 'Capy TV no pudo iniciar.';

  @override
  String get pickFieldFirst => 'Elige primero un campo en la TV';

  @override
  String get castNotAllowed => 'Lo que enviaron aquí no está disponible en este perfil.';

  @override
  String pairCheck(String address, String code) {
    return 'Comprueba que coincide con el otro dispositivo: $address · código $code';
  }

  @override
  String pinWait(int seconds) {
    return 'Demasiados intentos. Espera $seconds s';
  }

  @override
  String get switchProfile => 'Cambiar de perfil';

  @override
  String get profileLocked => 'PIN';

  @override
  String get adultTag => 'Para adultos';

  @override
  String get backspace => 'Borrar dígito';

  @override
  String get syncInvite => 'Código de invitación';

  @override
  String get syncInviteHint => 'Solo si tu servidor lo pide';

  @override
  String get syncErrorInvite => 'Este servidor solo crea cuentas con su código de invitación';

  @override
  String get syncErrorQuota => 'La cuenta está llena: pide más espacio a quien administra el servidor';

  @override
  String get syncErrorFull => 'Este servidor no admite más cuentas: pregúntale a quien lo administra';

  @override
  String get syncThisDevice => 'Este dispositivo';

  @override
  String get syncSignOutDevice => 'Cerrar sesión';

  @override
  String syncSignOutDeviceConfirm(String name) {
    return '¿Cerrar la sesión de $name? Conserva lo que tiene, pero no recibe nada nuevo hasta que vuelva a iniciar sesión.';
  }

  @override
  String syncSignedInAs(String email) {
    return 'Sesión iniciada como $email';
  }

  @override
  String get webTabAccount => 'Cuenta';

  @override
  String get webAccountTitle => 'Inicia sesión en la sincronización';

  @override
  String webAccountBody(String device) {
    return '$device recibe de tu cuenta tus listas, perfiles, favoritos e historial. La contraseña viaja cifrada y solo la usa $device.';
  }

  @override
  String webSignInOn(String device) {
    return 'Iniciar sesión en $device';
  }

  @override
  String get webSigningIn => 'Iniciando sesión… tarda unos segundos';

  @override
  String webSignedInTitle(String device) {
    return '$device ya inició sesión';
  }

  @override
  String webSignedInBody(String email) {
    return 'Como $email. Tus listas llegan en un momento.';
  }

  @override
  String webCurrentAccount(String device, String email) {
    return '$device tiene la sesión de $email. Iniciar sesión de nuevo cambia de cuenta.';
  }

  @override
  String webNeedQr(String device) {
    return 'Para enviar contraseñas, cuentas o respaldos desde aquí, escanea el código QR de $device: lleva la clave que los mantiene privados en tu red.';
  }

  @override
  String get syncForgot => '¿Olvidaste la contraseña?';

  @override
  String get syncBackToSignIn => 'Volver a iniciar sesión';

  @override
  String get syncRecoveryKey => 'Llave de recuperación';

  @override
  String get syncNewPassword => 'Contraseña nueva';

  @override
  String get syncCurrentPassword => 'Contraseña actual';

  @override
  String get syncRecover => 'Poner contraseña nueva';

  @override
  String get syncRecoverBody =>
      'Escribe la llave de recuperación que recibiste al crear la cuenta y elige una contraseña nueva. Tus otros dispositivos te la pedirán.';

  @override
  String get syncErrorRecoveryKey => 'Eso no es una llave de recuperación: tiene 32 letras y números';

  @override
  String get syncErrorRecovery => 'Correo o llave de recuperación incorrectos';

  @override
  String get syncErrorPassword => 'Contraseña incorrecta';

  @override
  String get syncRecoveryTitle => 'Tu llave de recuperación';

  @override
  String get syncRecoveryBody =>
      'Si olvidas la contraseña, esta llave es la única forma de volver a tu cuenta: nadie puede restablecerla por ti, ni siquiera quien administra el servidor. Anótala o tómale una foto, y guárdala en un lugar seguro.';

  @override
  String get syncRecoverySaved => 'Ya la anoté';

  @override
  String get syncCopy => 'Copiar';

  @override
  String get syncCopied => 'Copiada';

  @override
  String get syncChangePassword => 'Cambiar contraseña';

  @override
  String get syncChangePasswordBody =>
      'Tus otros dispositivos cierran sesión hasta que entren con la contraseña nueva.';

  @override
  String get syncPasswordChanged => 'Contraseña cambiada';

  @override
  String get syncNewRecoveryKey => 'Nueva llave de recuperación';

  @override
  String get syncNewRecoveryKeyBody =>
      'La llave de recuperación que tienes ahora deja de funcionar. Escribe tu contraseña para crear una nueva.';

  @override
  String get trendingMovie => 'Película en tendencia esta semana';

  @override
  String get trendingSeries => 'Serie en tendencia esta semana';

  @override
  String get about => 'Acerca de';

  @override
  String get aboutLicense =>
      'Código abierto, bajo la Mozilla Public License 2.0. Reproduce el contenido de tu propio proveedor y no incluye ninguno.';

  @override
  String get tmdbNotice =>
      'Este producto usa la API de TMDB, pero TMDB no lo respalda ni lo certifica. Las películas y series en tendencia, con sus imágenes, vienen de The Movie Database.';

  @override
  String get trendingNow => 'En tendencia esta semana';

  @override
  String forYou(String name) {
    return 'Elegido para $name';
  }

  @override
  String get forYouMain => 'Elegido para ti';

  @override
  String get aiTitle => 'Recomendaciones con IA';

  @override
  String get aiBody =>
      'Un modelo de lenguaje elige títulos para cada perfil según lo que ha visto y tiene en Favoritos, y dice por qué. Esos títulos, y algunos del catálogo para elegir, nunca de adultos, van al servicio que recomienda: el configurado aquí, si no el de tu servidor de sincronización, si no el de la app. Los perfiles infantiles nunca lo usan.';

  @override
  String get aiOff => 'Sin configurar';

  @override
  String get aiSetUp => 'Configurar';

  @override
  String get aiChange => 'Cambiar';

  @override
  String get aiRemove => 'Quitar';

  @override
  String get aiUrl => 'Dirección del servicio';

  @override
  String get aiUrlHint =>
      'Cualquier servicio con la API de chat de OpenAI: Ollama, OpenAI, OpenRouter, tu propio servidor…';

  @override
  String get aiModel => 'Modelo';

  @override
  String get aiKey => 'Clave de la API';

  @override
  String get aiKeyKept => 'Déjala vacía para conservar la clave actual';

  @override
  String get aiTestAndSave => 'Comprobar y guardar';

  @override
  String get aiSaved => 'Recomendaciones activadas';

  @override
  String get aiWrongKey => 'El servicio no aceptó la clave';

  @override
  String get aiWrongModel => 'El servicio no tiene ese modelo, o la dirección no es correcta';

  @override
  String get aiUnreachable => 'El servicio no respondió: revisa la dirección';

  @override
  String get aiBusy => 'El servicio está ocupado o caído por ahora: prueba más tarde';

  @override
  String aiServiceError(String code) {
    return 'El servicio respondió con el error $code';
  }

  @override
  String get aiUrlInsecure => 'Usa una dirección https: http solo para un servicio en esta red';

  @override
  String get aiKeyLost => 'La clave de tu servicio de IA no se pudo leer en este dispositivo: configúralo de nuevo';

  @override
  String get aiKeyAgain => 'Una dirección nueva necesita que escribas su clave otra vez';

  @override
  String get aiBuiltIn => 'Activadas: incluidas en esta versión de la app';

  @override
  String get aiUseBuiltIn => 'Volver a activar';

  @override
  String get aiTurnedOff => 'Desactivadas en este dispositivo';

  @override
  String get aiTurnOff => 'Desactivar';

  @override
  String get aiOwn => 'Usar otro servicio';

  @override
  String aiFromServer(String server) {
    return 'Activadas: a través de tu servidor de sincronización, $server';
  }

  @override
  String get aiServerNote =>
      'Los títulos que se envían para recomendar pasan por tu servidor de sincronización, que puede leerlos; los reenvía a su modelo y no guarda nada.';

  @override
  String get aiTypeOnPhone =>
      'Escanea el código con tu celular, abre Control y escribe ahí: el texto va al campo seleccionado en la TV.';

  @override
  String get recentSearches => 'Búsquedas recientes';

  @override
  String get clearRecent => 'Borrar';

  @override
  String get bestMatch => 'Más relevantes';

  @override
  String get onTvNow => 'En TV';

  @override
  String get onNow => 'Ahora';

  @override
  String get browseGenres => 'Películas por género';

  @override
  String seeAllCount(int count) {
    return 'Ver todo ($count)';
  }

  @override
  String versionsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count versiones', one: '1 versión');
    return '$_temp0';
  }

  @override
  String versionNumber(int n) {
    return 'Versión $n';
  }

  @override
  String get mostWatchedMovies => 'Películas más vistas de la semana';

  @override
  String get mostWatchedSeries => 'Series más vistas de la semana';

  @override
  String get tryingAnotherCopy => 'Probando otra copia…';

  @override
  String get combinePlaylists => 'Combinar listas';

  @override
  String get combineBody =>
      'Elige dos o más proveedores para usarlos como una sola lista. Sus catálogos se juntan: un título que tienen varios aparece una vez, con la copia de cada proveedor entre sus versiones, y se reproduce desde el que suele ser más rápido a esa hora, o desde otro si uno falla. Cada lista sigue como está.';

  @override
  String get pasteLinkHint => 'O pega el enlace que te envió tu proveedor (get.php?username=…): se llena todo solo';

  @override
  String get filledFromLink => 'Servidor, usuario y contraseña tomados del enlace';

  @override
  String get combineSuggestion =>
      'Tienes dos proveedores: combínalos para ver todos sus títulos juntos y reproducir desde el otro cuando uno falle';

  @override
  String get accountAlreadyAdded => 'Esa cuenta ya estaba: se actualizó su contraseña';

  @override
  String get surpriseMe => 'Sorpréndeme';

  @override
  String get surpriseQuestion => '¿Qué quieres ver?';

  @override
  String get surpriseGo => 'Elegir una';

  @override
  String get surpriseAnother => 'Otra';

  @override
  String get surpriseNone => 'No queda nada para ese ánimo: prueba otro.';

  @override
  String get userAgentOptional => 'User-Agent (opcional)';

  @override
  String get userAgentHint => 'Solo si tu proveedor pide un reproductor concreto';

  @override
  String get guideTime => 'Hora de la guía';

  @override
  String get guideTimeHint => 'Si la guía muestra los programas antes o después de su hora, corrígela aquí.';

  @override
  String get guideTimeAsSent => 'Como la envía el proveedor';

  @override
  String guideTimeMoved(String hours) {
    return '$hours h';
  }

  @override
  String get diagnostics => 'Diagnóstico';

  @override
  String get diagnosticsCopied => 'Copiado: pégalo en un mensaje a quien te esté ayudando.';

  @override
  String get diagnosticsHint =>
      'Lo que la app anotó últimamente, sin direcciones ni contraseñas, para quien te esté ayudando.';

  @override
  String get surpriseAtRandom => 'Tu lista no indica géneros ni valoraciones: te proponemos uno al azar.';

  @override
  String get surpriseNoInfoKids =>
      'Tu lista no indica géneros ni valoraciones, así que aquí no hay nada que proponer para este perfil.';

  @override
  String get moodLaugh => 'Reír';

  @override
  String get moodAction => 'Acción';

  @override
  String get moodSuspense => 'Suspenso';

  @override
  String get moodFamily => 'En familia';

  @override
  String get moodRomance => 'Romance';

  @override
  String get moodScary => 'Miedo';

  @override
  String get moodDifferent => 'Algo distinto';

  @override
  String get newEpisodesForYou => 'Nuevos episodios de tus series';

  @override
  String get upNextForYou => 'A continuación';

  @override
  String get guideToday => 'Hoy';

  @override
  String get guideYesterday => 'Ayer';

  @override
  String get guideTomorrow => 'Mañana';

  @override
  String get guideEarlier => 'Dos horas antes';

  @override
  String get guideLater => 'Dos horas después';

  @override
  String get rowEarlier => 'Anteriores de esta fila';

  @override
  String get rowLater => 'Siguientes de esta fila';

  @override
  String newEpisodeNote(int season, int number, int more) {
    String _temp0 = intl.Intl.pluralLogic(more, locale: localeName, other: ' y $more más', one: ' y 1 más', zero: '');
    return 'T$season · E$number$_temp0';
  }

  @override
  String get screensaver => 'Protector de pantalla';

  @override
  String minutesIdle(int minutes) {
    return 'A los $minutes min';
  }

  @override
  String get movieNight => 'Noche de pelis';

  @override
  String get nightTitle => '¿Qué vemos esta noche?';

  @override
  String get nightBodyTv =>
      'Cada uno escanea el código con su celular y dice sí o no a cada una. Gana la que tenga más votos.';

  @override
  String get nightYes => '¡Sí!';

  @override
  String get nightNo => 'No';

  @override
  String get nightWinner => 'Ver la ganadora';

  @override
  String nightVoters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Votaron $count celulares',
      one: 'Votó 1 celular',
      zero: 'Nadie ha votado todavía',
    );
    return '$_temp0';
  }

  @override
  String get nightWinnerTitle => 'Esta noche toca';

  @override
  String get nightNotEnough => 'No hay suficientes títulos para ese ánimo: prueba otro.';

  @override
  String get webTabNight => 'Votar';

  @override
  String get webNightBody => 'Sí o no a cada título: la TV cuenta los votos de todos.';

  @override
  String get webNightDone => '¡Listo, votaste!';

  @override
  String webNightDoneBody(String device) {
    return 'Mira $device: ahí sale la ganadora.';
  }

  @override
  String get webNightAgain => 'Cambiar mis votos';

  @override
  String webNightClosed(String device) {
    return 'Ahora no hay una votación abierta en $device.';
  }

  @override
  String webNightProgress(String n, String total) {
    return '$n de $total';
  }

  @override
  String leftOn(String device, String ago) {
    return 'Lo dejaste en $device $ago';
  }

  @override
  String get agoNow => 'hace un momento';

  @override
  String agoMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count minutos',
      one: 'hace 1 minuto',
    );
    return '$_temp0';
  }

  @override
  String agoHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'hace $count horas', one: 'hace 1 hora');
    return '$_temp0';
  }

  @override
  String get goOnHere => 'Seguir aquí';

  @override
  String get notNow => 'Ahora no';

  @override
  String get avatar => 'Avatar';

  @override
  String get avatarInitial => 'Inicial';

  @override
  String get changeAvatar => 'Cambiar avatar';

  @override
  String get playerSettings => 'Ajustes del reproductor';

  @override
  String get settingOff => 'No';

  @override
  String get settingOn => 'Sí';

  @override
  String get sleepTimer => 'Temporizador para dormir';

  @override
  String get sleepWhenItEnds => 'Al terminar';

  @override
  String get sleepDone => 'Pausado por el temporizador';

  @override
  String get sleepDoneHint => 'Que descanses.';

  @override
  String get sleepStillWatching => '¿Sigues viendo?';

  @override
  String sleepStillWatchingHint(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(seconds, locale: localeName, other: '$seconds segundos', one: '1 segundo');
    return 'La reproducción se detendrá en $_temp0.';
  }

  @override
  String get keepWatching => 'Seguir viendo';

  @override
  String get exitPlayer => 'Salir';

  @override
  String get leaveAppQuestion => '¿Salir de Capy TV?';

  @override
  String get leaveApp => 'Salir';

  @override
  String get listUpdatedPlain => 'Lista actualizada.';

  @override
  String get guideLoading => 'Cargando la guía…';

  @override
  String get restartApp => 'Volver a empezar';

  @override
  String serviceEndsSoon(String name, String date) {
    return 'Tu servicio de $name vence el $date: renuévalo con tu proveedor para que siga funcionando.';
  }

  @override
  String get openFailedHint => 'Ábrela para intentarlo de nuevo, o edítala para revisar sus datos.';

  @override
  String get noMoviesInPlaylist => 'Esta lista no tiene películas.';

  @override
  String get noSeriesInPlaylist => 'Esta lista no tiene series.';

  @override
  String get volumeBoost => 'Amplificar volumen';

  @override
  String get streamInfo => 'Información técnica';

  @override
  String get pictureFit => 'Imagen';

  @override
  String get fitContain => 'Ajustar';

  @override
  String get fitCover => 'Llenar';

  @override
  String get fitFill => 'Estirar';

  @override
  String get playerEpisodes => 'Episodios';

  @override
  String get playerChannels => 'Canales';

  @override
  String get lockControls => 'Bloquear la pantalla';

  @override
  String get pipOff => 'Imagen en imagen está desactivada para esta app en los ajustes de Android';

  @override
  String get back10 => 'Atrás 10 segundos';

  @override
  String get reduceMotion => 'Reducir el movimiento';

  @override
  String get trailers => 'Tráileres';

  @override
  String get trailersAlways => 'Siempre';

  @override
  String get trailersWifi => 'Solo con Wi-Fi';

  @override
  String get trailersNever => 'Nunca';

  @override
  String get volumeDown => 'Bajar el volumen';

  @override
  String get volumeUp => 'Subir el volumen';

  @override
  String get previousTitle => 'Anterior';

  @override
  String get nextTitle => 'Siguiente';

  @override
  String get clearSearch => 'Borrar la búsqueda';

  @override
  String ratingOf(String rating) {
    return 'nota $rating';
  }

  @override
  String pinDigits(int count, int total) {
    return '$count de $total dígitos';
  }

  @override
  String get forward10 => 'Adelante 10 segundos';

  @override
  String get mute => 'Activar o quitar el sonido';

  @override
  String get fullScreen => 'Pantalla completa';

  @override
  String timeLeftToday(int n) {
    return 'Quedan $n min por hoy';
  }

  @override
  String get tapToUnlock => 'Toca el candado para desbloquear';

  @override
  String get infoVideo => 'Video';

  @override
  String get infoDecoder => 'Decodificador';

  @override
  String get infoBitrate => 'Tasa de bits';

  @override
  String get infoBuffer => 'Búfer';

  @override
  String get infoDropped => 'Fotogramas perdidos';

  @override
  String get infoCopy => 'Copia';

  @override
  String get decoderHw => 'Hardware';

  @override
  String get decoderSw => 'Software';

  @override
  String get decoderSwAuto => 'Software (el hardware no mostró imagen)';

  @override
  String get channelsMono => 'MONO';

  @override
  String get channelsStereo => 'ESTÉREO';

  @override
  String fpsBadge(int n) {
    return '$n FPS';
  }

  @override
  String nOfTotal(int n, int total) {
    return '$n de $total';
  }

  @override
  String get refreshList => 'Actualizar canales y películas';

  @override
  String get listUpdating => 'Actualizando la lista…';

  @override
  String listUpdated(int movies, int series, int channels) {
    String _temp0 = intl.Intl.pluralLogic(movies, locale: localeName, other: '$movies películas', one: '1 película');
    String _temp1 = intl.Intl.pluralLogic(series, locale: localeName, other: '$series series', one: '1 serie');
    String _temp2 = intl.Intl.pluralLogic(channels, locale: localeName, other: '$channels canales', one: '1 canal');
    return 'Lista actualizada. Nuevo: $_temp0, $_temp1 y $_temp2';
  }

  @override
  String get audioDelay => 'Sincronizar audio';

  @override
  String get subtitleDelay => 'Sincronizar subtítulos';

  @override
  String get delayHint => 'Usa + si llega antes que la imagen';

  @override
  String get subtitleSize => 'Tamaño de los subtítulos';

  @override
  String get subtitleBackground => 'Fondo detrás de los subtítulos';

  @override
  String get playNow => 'Ver ahora';

  @override
  String get skipIntro => 'Saltar intro';

  @override
  String get seriesIntro => 'Intro de la serie';

  @override
  String get introStart => 'Marcar inicio';

  @override
  String get introEnd => 'Marcar fin';

  @override
  String get introClear => 'Borrar';

  @override
  String get introNotMarked => 'Sin marcar';

  @override
  String nextEpisodeIn(int seconds) {
    return 'Siguiente episodio en $seconds s';
  }

  @override
  String get pictureInPicture => 'Imagen en ventana';

  @override
  String get pipBack => 'Volver a la ventana';

  @override
  String get sendTo => 'Enviar a…';

  @override
  String get noOtherDevices => 'Ningún otro dispositivo tiene abierta esta cuenta de sincronización.';

  @override
  String get deviceActive => 'Activo ahora';

  @override
  String sentToDevice(String device) {
    return 'Enviado a $device';
  }

  @override
  String get deviceProfileTitle => 'En este dispositivo';

  @override
  String get deviceProfileBody =>
      'El perfil que se abre al iniciar la app aquí, sin preguntar quién ve (la TV de los niños).';

  @override
  String get deviceProfileAsk => 'Preguntar quién ve';

  @override
  String get profileAudio => 'Idioma del audio';

  @override
  String get profileSubtitles => 'Subtítulos';

  @override
  String get asInSettings => 'Como en Ajustes';

  @override
  String get dailyLimit => 'Tiempo por día';

  @override
  String get dailyLimitHint => 'Se cuenta en cada dispositivo. Al acabarse, el PIN da más tiempo.';

  @override
  String get noLimit => 'Sin límite';

  @override
  String get timeUp => 'Se acabó el tiempo de hoy';

  @override
  String get timeUpHint => 'Mañana hay más. Un adulto puede dar más tiempo con el PIN.';

  @override
  String get moreTime => '30 minutos más';

  @override
  String get moreTimeNeedsPin => 'Para dar más tiempo hace falta un PIN parental: créalo en Perfiles.';

  @override
  String hoursOnly(int h) {
    return '$h h';
  }

  @override
  String get goLive => 'Ir al directo';

  @override
  String updateTitle(String version) {
    return 'Capy TV $version';
  }

  @override
  String get updateBody => 'Hay una versión nueva lista para este dispositivo.';

  @override
  String get updateNow => 'Actualizar';

  @override
  String get updateLater => 'Más tarde';

  @override
  String get updateInBackground => 'Seguir en segundo plano';

  @override
  String get updateDownloading => 'Descargando la actualización…';

  @override
  String get updateAllowTitle => 'Permite la actualización';

  @override
  String get updateAllowBody =>
      'Android lo pide una sola vez: en la pantalla que se abre, permite que Capy TV instale apps y vuelve aquí.';

  @override
  String get updateAllowManual =>
      'En los ajustes de este dispositivo, permite que Capy TV instale apps desconocidas y vuelve aquí.';

  @override
  String get openSettings => 'Abrir ajustes';

  @override
  String get updateFailed => 'La actualización no se completó. Prueba de nuevo en un momento.';

  @override
  String get updateDamaged => 'La descarga llegó dañada y se descartó. Prueba de nuevo.';

  @override
  String updateTo(String version) {
    return 'Actualizar a $version';
  }

  @override
  String appVersion(String version) {
    return 'Versión $version';
  }

  @override
  String get checkUpdates => 'Buscar actualizaciones';

  @override
  String get upToDate => 'Tienes la última versión.';

  @override
  String get backgroundPlay => 'Seguir sonando fuera de la app';

  @override
  String get pause => 'Pausa';

  @override
  String get stopPlaying => 'Detener';

  @override
  String get multiview => 'Multivista';

  @override
  String get multiviewAdd => 'Agregar un canal';

  @override
  String get multiviewChange => 'Cambiar canal';

  @override
  String get multiviewRemove => 'Quitar';

  @override
  String get multiviewFull => 'Pantalla completa';

  @override
  String get record => 'Grabar';

  @override
  String get stopRecording => 'Detener la grabación';

  @override
  String get recordings => 'Grabaciones';

  @override
  String get recordingSaved => 'Guardado en Grabaciones (en Ajustes, o junto a tus listas)';

  @override
  String get recordingFailed => 'No se grabó nada';

  @override
  String get noRecordings => 'Aquí aparecen tus grabaciones: las del reproductor y las programadas desde la guía.';

  @override
  String get deleteRecording => '¿Eliminar esta grabación?';

  @override
  String get recordingNotDeleted => 'No se pudo eliminar esta grabación: puede que otro programa la tenga abierta';

  @override
  String get cancelScheduledQuestion => '¿Cancelar esta grabación programada?';

  @override
  String get stopRecordingQuestion => '¿Detener esta grabación? Lo grabado se guarda.';

  @override
  String get keepIt => 'Mantenerla';

  @override
  String get recordingUntitled => 'Canal';

  @override
  String get recordingStopped => 'La grabación se detuvo: no se pudo seguir guardando (¿falta espacio?)';

  @override
  String get recordingNoRoom => 'No queda espacio suficiente en este dispositivo para grabar';

  @override
  String get recordingStoppedNoRoom =>
      'La grabación se detuvo: este dispositivo se está quedando sin espacio. Lo grabado se guardó.';

  @override
  String get recordingAppClosedNote => 'Android cerró Capy TV mientras tanto. Ábrela para grabar lo que queda.';

  @override
  String get closeWithRecordingsTitle => '¿Cerrar Capy TV?';

  @override
  String get closeWithRecordingsBody => 'Hay algo grabándose o programado. Con la app cerrada no se grabará.';

  @override
  String get closeAnyway => 'Cerrar de todos modos';

  @override
  String get keepOpen => 'Dejarla abierta';

  @override
  String get keepAppOpenToRecord =>
      'En iPhone, deja Capy TV abierta en pantalla hasta que se grabe: iOS la detiene en segundo plano.';

  @override
  String get keepAppOpenToCast =>
      'En iPhone, deja Capy TV abierta: el canal en vivo deja de llegar a la TV cuando la app sale de la pantalla.';

  @override
  String get castNoSubtitles => 'Los subtítulos no llegan a la TV: allí el video se ve sin ellos.';

  @override
  String get castOtherAudio => 'La TV pone el audio propio del video, no el idioma que elegiste aquí.';

  @override
  String get sendToYourDevices => 'Tus dispositivos';

  @override
  String get sendToNearby => 'En esta red';

  @override
  String get castSearching => 'Buscando Chromecast…';

  @override
  String get castNoneFound => 'No se encontró ningún Chromecast en esta red.';

  @override
  String get castByAddress => 'Conectar por dirección…';

  @override
  String get castAddressHint => 'Dirección IP, como 192.168.1.20';

  @override
  String get castAddressInvalid => 'Esa no es la dirección de un dispositivo: escribe su IP, como 192.168.1.20';

  @override
  String get castConnect => 'Conectar';

  @override
  String castConnecting(String device) {
    return 'Conectando con $device…';
  }

  @override
  String castStarting(String device) {
    return 'Iniciando en $device…';
  }

  @override
  String castTrying(int n, int total) {
    return 'Probando otra copia ($n de $total)…';
  }

  @override
  String get castBuffering => 'Cargando…';

  @override
  String get castPaused => 'En pausa';

  @override
  String castLost(String device) {
    return 'Se perdió la conexión con $device. Reconectando…';
  }

  @override
  String get castStopped => 'Se dejó de transmitir.';

  @override
  String castConnectFailed(String device) {
    return 'No se pudo conectar con $device.';
  }

  @override
  String castLaunchFailed(String device) {
    return '$device no abrió su reproductor.';
  }

  @override
  String castCannotPlay(String device) {
    return '$device no puede reproducir esto.';
  }

  @override
  String castRelayUnreachable(String device) {
    return '$device no pudo conectarse a este dispositivo. Revisa que el cortafuegos lo deje entrar y que ambos estén en la misma red.';
  }

  @override
  String castProviderRefused(String device) {
    return 'Tu proveedor no dejó ver esto en $device: puede que tu cuenta no permita otra conexión ahora.';
  }

  @override
  String castTakenOver(String device) {
    return '$device ahora reproduce otra cosa.';
  }

  @override
  String get castFinished => 'Terminó.';

  @override
  String castingTo(String device) {
    return 'Transmitiendo a $device';
  }

  @override
  String castMkvMayFail(String device) {
    return 'Es posible que los MKV no se reproduzcan en $device.';
  }

  @override
  String get castKeepOn => 'Mantén este dispositivo encendido y en la misma Wi-Fi mientras transmites un canal.';

  @override
  String get castPlayHere => 'Ver aquí';

  @override
  String get stopCasting => 'Dejar de transmitir';

  @override
  String get castUnsupportedLive =>
      'El formato de este canal no se puede transmitir. Tus dispositivos sí pueden reproducirlo.';

  @override
  String castUnsupportedFile(String format) {
    return 'El formato de este video ($format) no se puede transmitir.';
  }

  @override
  String get castUnsupportedLocal => 'Las grabaciones y los programas anteriores aún no se pueden enviar a Chromecast.';

  @override
  String get castNoHls => 'Tu proveedor no ofrece este canal en el formato que necesita Chromecast.';

  @override
  String castLostEnded(String device) {
    return 'Se perdió la conexión con $device.';
  }

  @override
  String get recordingEncrypted => 'Este canal no se puede grabar: está cifrado';

  @override
  String get recordingFragmented => 'Este canal no se puede grabar: la app no puede guardar su formato';

  @override
  String get recordingSeparateAudio => 'Este canal no se puede grabar: su sonido llega aparte de la imagen';

  @override
  String get recordingCut => 'La grabación se detuvo porque el canal se cortó. Lo grabado se guardó.';

  @override
  String get cancelRecording => 'Cancelar grabación';

  @override
  String get scheduledRecordings => 'Programadas';

  @override
  String get recordedFiles => 'Grabadas';

  @override
  String get recordingScheduled => 'Grabación programada';

  @override
  String get recordingNow => 'Grabando ahora';

  @override
  String get recordingDone => 'Grabada';

  @override
  String get recordingFailedState => 'No se pudo grabar';

  @override
  String recordingFailedBecause(String why) {
    return 'No se pudo grabar: $why';
  }

  @override
  String recordingPartly(String why) {
    return 'Grabada en parte: $why';
  }

  @override
  String recordingMissedBecause(String why) {
    return 'Perdida: $why';
  }

  @override
  String recordingRetrying(String why) {
    return 'Se reintenta en un momento: $why';
  }

  @override
  String get problemAppClosed => 'la app estaba cerrada';

  @override
  String get problemAsleep => 'el dispositivo estaba suspendido';

  @override
  String get problemNoNetwork => 'no se pudo conectar con el canal';

  @override
  String get problemChannelGone => 'el canal ya no está en la lista';

  @override
  String get problemUnsupported => 'la app no puede guardar este canal en el formato en que llega';

  @override
  String get problemNothingCame => 'el canal no envió nada';

  @override
  String get problemNoSpace => 'no queda espacio en el dispositivo';

  @override
  String get problemWriteFailed => 'no se pudo escribir el archivo';

  @override
  String get scheduleNote =>
      'Se graba mientras la app esté abierta, aunque sea en segundo plano. Si está cerrada a esa hora, la grabación se pierde.';

  @override
  String get recordEarly => 'Empezar antes del programa';

  @override
  String get recordLate => 'Seguir después del programa';

  @override
  String get recordMarginsHint =>
      'Para un partido con prórroga o un canal que va atrasado. Para lo que programes desde ahora.';

  @override
  String recordingStartsAt(String time) {
    return 'Empieza a grabar: $time';
  }

  @override
  String recordingChannel(String channel) {
    return 'Grabando $channel';
  }

  @override
  String recordingChannels(int count) {
    return 'Grabando $count canales';
  }

  @override
  String get removeFromList => 'Quitar';

  @override
  String get recordingPaused => 'Grabaciones en pausa';

  @override
  String get recordingPausedNote =>
      'Android deja que la app grabe en segundo plano unas horas al día. Abre Capy TV y continúan.';

  @override
  String get installOtherDevice => 'Instalar en otro dispositivo';

  @override
  String get installLinkLoading => 'Pidiendo un enlace…';

  @override
  String get installLinkType => 'En Downloader, en el Fire TV, escribe esta dirección';

  @override
  String get installLinkScan => 'En un celular, escanea el código.';

  @override
  String installLinkValid(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Válido durante $minutes minutos',
      one: 'Válido durante 1 minuto',
    );
    return '$_temp0';
  }

  @override
  String get installLinkNoApp =>
      'El servidor de sincronización no tiene una copia de la app para compartir. Quien lo administra puede ponerla.';

  @override
  String get installLinkTooMany => 'Demasiados enlaces en poco tiempo. Prueba más tarde.';

  @override
  String get avatarCredits =>
      'Avatares de los perfiles dibujados con DiceBear (dicebear.com): “Croodles - Doodle your face” de vijay verma y “Fun Emoji Set” de Davis Uche, adaptados para la app, bajo CC BY 4.0 (creativecommons.org/licenses/by/4.0); Notionists de Zoish, Lorelei de Lisa Wischofsky, Open Peeps de Pablo Stanley, y Critters y Voxel Bot de DiceBear, bajo CC0 1.0.';

  @override
  String get titleBarSearch => 'Buscar en esta lista…';

  @override
  String get titleBarSearchShortcut => 'Ctrl K';

  @override
  String get playlistKindM3u => 'M3U';

  @override
  String get playlistKindCombined => 'Combinada';

  @override
  String get windowMinimize => 'Minimizar';

  @override
  String get windowMaximize => 'Maximizar';

  @override
  String get windowRestore => 'Restaurar';

  @override
  String errorExpiredOn(String date) {
    return 'La cuenta venció el $date. Pide a tu proveedor que la renueve.';
  }

  @override
  String deletePlaylistInCombined(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Forma parte de las listas combinadas $names, que seguirán sin ella.',
      one: 'Forma parte de la lista combinada $names, que seguirá sin ella.',
    );
    return '$_temp0';
  }

  @override
  String sleepSoon(int n) {
    return 'El temporizador lo detiene en un minuto. Toca o pulsa cualquier botón para seguir viendo $n minutos más.';
  }

  @override
  String sleepExtended(int n) {
    return 'Temporizador: $n minutos más';
  }

  @override
  String get guideFailed => 'No se pudo descargar la guía.';

  @override
  String rankLabel(int n) {
    return 'Número $n';
  }

  @override
  String watchedPercent(int percent) {
    return '$percent % visto';
  }

  @override
  String get holdOkChannelHint => 'Mantén OK o pulsa Info sobre un canal: lo que viene en él, y Favoritos';

  @override
  String get controlsStay => 'Los controles del reproductor se quedan';

  @override
  String get controlsStayMoment => 'Un momento';

  @override
  String controlsStaySeconds(int n) {
    return '$n segundos';
  }

  @override
  String webNoSecureStorage(String device) {
    return '$device guardó la lista, pero no su contraseña: su almacenamiento seguro no funciona.';
  }

  @override
  String get deviceMode => 'Usar este dispositivo como';

  @override
  String get deviceModeAuto => 'Lo que el dispositivo diga';

  @override
  String get deviceModeTv => 'Una TV, con control remoto';

  @override
  String get deviceModeTouch => 'Un celular o tablet, táctil';

  @override
  String get appliesNextStart => 'Se aplica la próxima vez que abras la app';

  @override
  String get playbackPosition => 'Posición';

  @override
  String get previousChannel => 'Canal anterior';

  @override
  String get subtitleOutline => 'Contorno de los subtítulos';

  @override
  String get subtitleBandDarkness => 'Oscuridad del fondo';

  @override
  String get subtitleLift => 'Altura de los subtítulos';

  @override
  String get subtitleLiftBottom => 'Abajo';

  @override
  String get subtitleLiftHigher => 'Más arriba';

  @override
  String get subtitleLiftHighest => 'Mucho más arriba';

  @override
  String get subtitlePicture => 'imagen';

  @override
  String get subtitlePictureHidden =>
      'Estos subtítulos son imágenes: con el decodificador por hardware no se ven. Elige el decodificador por software en los ajustes del reproductor.';

  @override
  String playingOnDevice(String device) {
    return 'Se está viendo en $device';
  }

  @override
  String get playingOnDeviceHint =>
      'Aquí se detuvo, para que el proveedor vea una sola conexión. Sigue desde el mismo punto.';

  @override
  String get keepWatchingHere => 'Seguir viendo aquí';

  @override
  String get failExpired => 'La cuenta ya no está activa. Pide a tu proveedor que la renueve.';

  @override
  String get failBusy =>
      'Todas las conexiones que permite la cuenta están en uso en otros dispositivos. Detén una y vuelve a intentarlo.';

  @override
  String get failUnsupported =>
      'Este dispositivo no puede reproducir este formato. En los ajustes del reproductor, prueba el otro decodificador de video.';

  @override
  String get failUnsupportedHere => 'Este dispositivo no puede reproducir este formato. Prueba otra copia u otra cosa.';

  @override
  String get textSize => 'Tamaño del texto';

  @override
  String get textSizeDevice => 'Como el del dispositivo';

  @override
  String get watchAgain => 'Ver de nuevo';
}
