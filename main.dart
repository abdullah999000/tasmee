import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const TasmeeApp());
}

class TasmeeApp extends StatelessWidget {
  const TasmeeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مُسمِّع',
      home: Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  static const String _bundledModelAsset = 'assets/models/ggml-tiny-ar-quran.bin';
  static const String _bundledQuranAsset = 'assets/data/quran_full_604.json';
  static const String _audioFolderName = 'Quran App Audio';
  static const Set<String> _audioExts = {'.mp3', '.m4a', '.aac', '.wav', '.flac'};

  late final WebViewController _web;
  final SpeechToText _stt = SpeechToText();
  final WhisperController _whisper = WhisperController();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _localPlayer = AudioPlayer();

  bool _sttReady = false;
  bool _want = false;
  bool _usingOfflineWhisper = false;
  bool _usingOnDeviceStt = false;
  bool _onDeviceGotResult = false;
  bool _onDeviceFallbackTriggered = false;
  String? _extractedModelPath;
  Future<String?>? _modelExtractFuture;
  Map<int, List<Map<String, dynamic>>>? _bundledPages;
  Future<Map<int, List<Map<String, dynamic>>>>? _bundledPagesFuture;
  int _lastLevelEmitMs = 0;
  int _lastDiagStatusMs = 0;
  int _livePartialsCount = 0;
  int _speechActiveMs = 0;
  bool _chunkedModeActive = false;
  bool _chunkTranscribing = false;
  StreamSubscription<Uint8List>? _chunkPcmSub;
  final BytesBuilder _chunkBuffer = BytesBuilder(copy: false);
  String _chunkAccumulatedText = '';
  int _chunkLastFlushMs = 0;
  Timer? _liveWatchdogTimer;
  int _wavLoopEpoch = 0;
  int _pendingTranscribeJobs = 0;
  bool _offlineHeardAny = false;
  bool _isTranscribingNow = false;
  String _currentPromptHint = '';
  WhisperLiveSession? _whisperSession;
  StreamSubscription<String>? _whisperPartialSub;
  String? _locale;
  Timer? _endTimer;
  Timer? _themeTimer;
  String? _lastInsets;
  double _top = 0, _bottom = 0, _left = 0, _right = 0;
  bool _dark = true;
  DateTime? _lastBackPress;

  // External audio player state
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _doneSub;
  String? _activeAudioPath;
  Directory? _externalAudioDir;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('Tasmee', onMessageReceived: _onMessage)
      ..addJavaScriptChannel('TasmeeLocalAudio', onMessageReceived: _onLocalAudioMessage)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        _lastInsets = null;
        _applyInsets();
        _checkTheme();
        _pushBundledQuranIfPresent();
      }));

    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform.setTextZoom(100);
    }

    _initLocalAudioListeners();
    _prepareExternalAudioDirectory();
    _prepareBundledWhisperModel();
    _load();
    _applyBars();
    _themeTimer = Timer.periodic(const Duration(seconds: 1), (_) => _checkTheme());
  }

  void _initLocalAudioListeners() {
    _posSub = _localPlayer.onPositionChanged.listen((d) {
      _audioJs('position', {'ms': d.inMilliseconds, 'path': _activeAudioPath});
    });
    _durSub = _localPlayer.onDurationChanged.listen((d) {
      _audioJs('duration', {'ms': d.inMilliseconds, 'path': _activeAudioPath});
    });
    _stateSub = _localPlayer.onPlayerStateChanged.listen((st) {
      _audioJs('state', {
        'playing': st == PlayerState.playing,
        'paused': st == PlayerState.paused,
        'stopped': st == PlayerState.stopped || st == PlayerState.completed,
        'path': _activeAudioPath,
      });
    });
    _doneSub = _localPlayer.onPlayerComplete.listen((_) {
      _audioJs('completed', {'path': _activeAudioPath});
    });
  }

  // Extract bundled GGML Whisper model from APK/IPA assets once into app support storage
  // so 100% offline on-device Quran recitation works from the very first launch in Airplane Mode.
  Future<String?> _prepareBundledWhisperModel() {
    if (_extractedModelPath != null && File(_extractedModelPath!).existsSync()) {
      return Future.value(_extractedModelPath);
    }
    _modelExtractFuture ??= _extractBundledWhisperModelOnce();
    return _modelExtractFuture!;
  }

  Future<String?> _extractBundledWhisperModelOnce() async {
    try {
      final targetPath = await _whisper.getPath(WhisperModel.tiny);
      final outFile = File(targetPath);
      // Fast path: if valid >20MB model is already extracted on disk, DO NOT reload 60MB asset into RAM!
      if (await outFile.exists() && await outFile.length() > 15 * 1024 * 1024) {
        _extractedModelPath = outFile.path;
        return _extractedModelPath;
      }
      await outFile.parent.create(recursive: true);
      final tmpFile = File('${targetPath}.tmp');
      final data = await rootBundle.load(_bundledModelAsset);
      final expectedBytes = data.lengthInBytes;
      if (expectedBytes > 15 * 1024 * 1024) {
        await tmpFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, expectedBytes),
          flush: true,
        );
        if (await outFile.exists()) {
          await outFile.delete();
        }
        await tmpFile.rename(outFile.path);
        _extractedModelPath = outFile.path;
        return _extractedModelPath;
      }
    } catch (e) {
      _modelExtractFuture = null;
      _js('status', '⚠️ [3] تعذّر استخراج نموذج التسميع المحلي: $e');
    }
    _modelExtractFuture = null;
    return null;
  }

  Future<Map<int, List<Map<String, dynamic>>>> _ensureBundledQuranIndex() {
    if (_bundledPages != null) return Future.value(_bundledPages!);
    _bundledPagesFuture ??= _loadBundledQuranIndexOnce();
    return _bundledPagesFuture!;
  }

  Future<Map<int, List<Map<String, dynamic>>>> _loadBundledQuranIndexOnce() async {
    final map = <int, List<Map<String, dynamic>>>{};
    try {
      final raw = await rootBundle.loadString(_bundledQuranAsset);
      if (raw.length > 1000) {
        final decoded = jsonDecode(raw);
        final data = (decoded is Map) ? decoded['data'] : null;
        final surahs = (data is Map && data['surahs'] is List) ? data['surahs'] as List : const [];
        for (final sObj in surahs) {
          if (sObj is! Map) continue;
          final sNum = (sObj['number'] is num) ? (sObj['number'] as num).toInt() : 0;
          final ayahs = (sObj['ayahs'] is List) ? sObj['ayahs'] as List : const [];
          for (final aObj in ayahs) {
            if (aObj is! Map) continue;
            final pNum = (aObj['page'] is num) ? (aObj['page'] as num).toInt() : 0;
            final aNum = (aObj['numberInSurah'] is num) ? (aObj['numberInSurah'] as num).toInt() : 0;
            final txt = aObj['text']?.toString() ?? '';
            if (pNum >= 1 && pNum <= 604 && txt.isNotEmpty) {
              (map[pNum] ??= <Map<String, dynamic>>[]).add({
                's': sNum,
                'a': aNum,
                'p': pNum,
                't': txt,
              });
            }
          }
        }
      }
    } catch (_) {}
    _bundledPages = map;
    return map;
  }

  Future<void> _pushBundledQuranIfPresent() async {
    // Pre-index all 604 pages in Dart memory (never dump 1.6 MB across Android WebView Binder IPC!)
    await _ensureBundledQuranIndex();
  }

  Future<void> _serveBundledPage(int pageNumber, String reqId) async {
    final idx = await _ensureBundledQuranIndex();
    final verses = idx[pageNumber] ?? const <Map<String, dynamic>>[];
    await _web.runJavaScript(
      'window.__onNativePageLoaded&&window.__onNativePageLoaded(${jsonEncode(reqId)},$pageNumber,${jsonEncode(verses)})',
    );
  }

  // Resolve and create the user-visible external audio folder ("Quran App Audio"):
  // - Android: /storage/emulated/0/Music/Quran App Audio (or Android/media/com.tasmee.tasmee/Quran App Audio)
  // - iOS: <AppDocuments>/Quran App Audio (exposed in Apple Files app via UIFileSharingEnabled)
  Future<Directory?> _prepareExternalAudioDirectory() async {
    if (_externalAudioDir != null && await _externalAudioDir!.exists()) {
      return _externalAudioDir;
    }
    try {
      if (Platform.isAndroid) {
        final candidates = <String>[
          '/storage/emulated/0/Music/$_audioFolderName',
          '/storage/emulated/0/Android/media/com.tasmee.tasmee/$_audioFolderName',
        ];
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          candidates.add('${ext.path}/$_audioFolderName');
        }
        for (final p in candidates) {
          try {
            final dir = Directory(p);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            if (await dir.exists()) {
              _externalAudioDir = dir;
              return dir;
            }
          } catch (_) {}
        }
      } else if (Platform.isIOS) {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/$_audioFolderName');
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        _externalAudioDir = dir;
        return dir;
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/$_audioFolderName');
        if (!await dir.exists()) await dir.create(recursive: true);
        _externalAudioDir = dir;
        return dir;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _requestAudioStoragePermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      if (!await Permission.audio.isGranted) {
        await Permission.audio.request();
      }
      if (!await Permission.storage.isGranted) {
        await Permission.storage.request();
      }
    } catch (_) {}
  }

  Future<void> _listExternalAudioFiles() async {
    await _requestAudioStoragePermissionIfNeeded();
    final dir = await _prepareExternalAudioDirectory();
    if (dir == null) {
      _audioJs('list', {'path': '', 'files': [], 'error': 'تعذّر الوصول إلى مجلد الصوتيات الخارجي'});
      return;
    }
    final files = <Map<String, dynamic>>[];
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: false, followLinks: false)) {
          if (entity is File) {
            final name = entity.uri.pathSegments.isNotEmpty ? entity.uri.pathSegments.last : entity.path.split('/').last;
            final dot = name.lastIndexOf('.');
            final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
            if (_audioExts.contains(ext)) {
              final stat = await entity.stat();
              files.add({
                'name': name,
                'path': entity.path,
                'size': stat.size,
                'ext': ext.replaceFirst('.', '').toUpperCase(),
              });
            }
          }
        }
        files.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      }
    } catch (_) {}
    final displayPath = Platform.isIOS
        ? 'الملفات (Files) ← على الـ iPhone ← مُسمِّع ← $_audioFolderName'
        : dir.path.replaceFirst('/storage/emulated/0/', 'التخزين الداخلي/');
    _audioJs('list', {'path': displayPath, 'rawPath': dir.path, 'files': files});
  }

  Future<void> _onLocalAudioMessage(JavaScriptMessage m) async {
    try {
      final o = jsonDecode(m.message) as Map<String, dynamic>;
      final act = o['a']?.toString() ?? '';
      if (act == 'list') {
        await _listExternalAudioFiles();
      } else if (act == 'play') {
        final p = o['path']?.toString() ?? '';
        if (p.isNotEmpty && File(p).existsSync()) {
          _activeAudioPath = p;
          await _localPlayer.play(DeviceFileSource(p));
          final startMs = (o['seekMs'] is num) ? (o['seekMs'] as num).toInt() : 0;
          if (startMs > 0) {
            await _localPlayer.seek(Duration(milliseconds: startMs));
          }
        } else {
          _audioJs('error', {'msg': 'الملف الصوتي غير موجود أو تم نقله'});
          await _listExternalAudioFiles();
        }
      } else if (act == 'pause') {
        await _localPlayer.pause();
      } else if (act == 'resume') {
        await _localPlayer.resume();
      } else if (act == 'stop') {
        await _localPlayer.stop();
      } else if (act == 'seek') {
        final ms = (o['ms'] is num) ? (o['ms'] as num).toInt() : 0;
        await _localPlayer.seek(Duration(milliseconds: ms));
      } else if (act == 'volume') {
        final v = (o['v'] is num) ? (o['v'] as num).toDouble().clamp(0.0, 1.0) : 1.0;
        await _localPlayer.setVolume(v);
      }
    } catch (e) {
      _audioJs('error', {'msg': e.toString()});
    }
  }

  void _audioJs(String type, Object? data) {
    _web.runJavaScript(
        'window.__localAudioEvent&&window.__localAudioEvent(${jsonEncode(type)},${jsonEncode(data)})');
  }

  Future<void> _checkTheme() async {
    try {
      final r = await _web.runJavaScriptReturningResult(
          "document.documentElement.getAttribute('data-theme')||''");
      final dark = r.toString().contains('dark');
      if (dark != _dark) {
        setState(() => _dark = dark);
        _applyBars();
      }
    } catch (_) {}
  }

  void _applyBars() {
    final icons = _dark ? Brightness.light : Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: icons,
      systemNavigationBarIconBrightness: icons,
    ));
  }

  Future<void> _load() async {
    final html = await rootBundle.loadString('assets/index.html');
    await _web.loadHtmlString(html, baseUrl: 'https://tasmee.app/');
  }

  void _applyInsets() {
    final key = '$_top/$_bottom/$_left/$_right';
    if (key == _lastInsets) return;
    _lastInsets = key;
    final css = ':root{--safe-top:${_top}px!important;--safe-bottom:${_bottom}px!important;'
        '--safe-left:${_left}px!important;--safe-right:${_right}px!important}'
        '.top-bar{padding-top:calc(10px + ${_top}px)!important}'
        '@media(max-width:360px){.top-bar{padding-top:calc(8px + ${_top}px)!important}}'
        '@media(max-height:500px){.top-bar{padding-top:calc(4px + ${_top}px)!important}}';
    _web.runJavaScript("(function(){var s=document.getElementById('__ins');"
        "if(!s){s=document.createElement('style');s.id='__ins';document.head.appendChild(s)}"
        's.textContent=${jsonEncode(css)}})()');
  }

  @override
  void dispose() {
    _endTimer?.cancel();
    _liveWatchdogTimer?.cancel();
    _themeTimer?.cancel();
    _whisperPartialSub?.cancel();
    _chunkPcmSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _doneSub?.cancel();
    _localPlayer.dispose();
    _recorder.dispose();
    try { _whisper.releaseModel(); } catch (_) {}
    WakelockPlus.disable();
    super.dispose();
  }

  void _js(String type, Object? data) {
    _web.runJavaScript(
        'window.__srEvent&&window.__srEvent(${jsonEncode(type)},${jsonEncode(data)})');
  }

  void _onMessage(JavaScriptMessage m) {
    try {
      final o = jsonDecode(m.message) as Map<String, dynamic>;
      final act = o['a']?.toString() ?? '';
      if (act == 'start') {
        _start(
          promptHint: o['prompt']?.toString(),
          preferOffline: o['offline'] == true,
        );
      } else if (act == 'reset_session') {
        _resetLiveSession(
          promptHint: o['prompt']?.toString(),
          preferOffline: o['offline'] == true,
        );
      } else if (act == 'stop') {
        _stop();
      } else if (act == 'hint') {
        _currentPromptHint = (o['prompt']?.toString() ?? '').trim();
      } else if (act == 'vibrate_err') {
        HapticFeedback.mediumImpact();
      } else if (act == 'get_page') {
        final p = (o['p'] is num) ? (o['p'] as num).toInt() : 0;
        final reqId = o['reqId']?.toString() ?? '';
        if (p >= 1 && p <= 604) {
          _serveBundledPage(p, reqId);
        }
      } else if (act == 'loadBundledQuran') {
        _pushBundledQuranIfPresent();
      }
    } catch (_) {}
  }

  Future<bool> _hasInternetConnection() async {
    try {
      final res = await InternetAddress.lookup('dns.google')
          .timeout(const Duration(milliseconds: 700));
      return res.isNotEmpty && res.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _resetLiveSession({String? promptHint, bool preferOffline = false}) async {
    if (!_want) return;
    _chunkAccumulatedText = '';
    _offlineHeardAny = false;
    _pendingTranscribeJobs = 0;
    _chunkBuffer.clear();
    if (_usingOfflineWhisper) {
      final modelPath = await _prepareBundledWhisperModel();
      if (modelPath != null) {
        await _startOfflineWhisperLive(modelPath, promptHint);
      }
    } else {
      try { await _stt.stop(); } catch (_) {}
      await _listenStt(onDevice: _usingOnDeviceStt);
    }
  }

  Future<bool> _ensureSttInitialized() async {
    if (!_sttReady) {
      _sttReady = await _stt.initialize(onStatus: _onStatus, onError: _onError);
      if (_sttReady) {
        try {
          final locales = await _stt.locales();
          for (final l in locales) {
            if (l.localeId.toLowerCase().replaceAll('-', '_') == 'ar_sa') {
              _locale = l.localeId;
              break;
            }
          }
          _locale ??= locales
              .where((l) => l.localeId.toLowerCase().startsWith('ar'))
              .map((l) => l.localeId)
              .firstOrNull;
        } catch (_) {}
        _locale ??= 'ar_SA';
      }
    }
    return _sttReady;
  }

  Future<void> _fallbackFromOnDeviceToWhisper(String? promptHint) async {
    if (!_want || _onDeviceFallbackTriggered) return;
    _onDeviceFallbackTriggered = true;
    _usingOnDeviceStt = false;
    _endTimer?.cancel();
    try { await _stt.stop(); } catch (_) {}
    _js('status', '🎙️ التبديل التلقائي لمحرك Whisper المحلي (للسرعة اللحظية ثبّت حزمة العربية الأوفلاين من إعدادات Google)');
    final modelPath = await _prepareBundledWhisperModel();
    if (modelPath != null && _want) {
      final started = await _startOfflineWhisperLive(modelPath, promptHint);
      if (started) return;
    }
    if (_want) {
      _want = false;
      _js('error', 'not-allowed');
    }
  }

  Future<void> _start({String? promptHint, bool preferOffline = false}) async {
    _want = true;
    _currentPromptHint = (promptHint ?? '').trim();
    _onDeviceFallbackTriggered = false;
    _onDeviceGotResult = false;
    _js('status', '⏳ [2] جارٍ فحص الاتصال وتجهيز المحرك...');
    final online = !preferOffline && await _hasInternetConnection();

    // Unified ASR Routing:
    // - Online: fast OS/Cloud SpeechRecognition (with automatic fallback to local Whisper if unavailable)
    // - Offline Tier 1: True <250ms On-Device OS Streaming ASR (onDevice: true) when offline Arabic pack is installed
    // - Offline Tier 2: 100% Standalone Bundled Whisper Tiny Quran GGML automatic fallback
    if (online) {
      _usingOfflineWhisper = false;
      _usingOnDeviceStt = false;
      if (await _ensureSttInitialized()) {
        _js('status', '🌐 التسميع المتصل يعمل — اقرأ من أي موضع في الصفحة');
        await _listenStt(onDevice: false);
        return;
      }
    } else {
      // Offline Tier 1: Try instant hardware-accelerated On-Device OS Streaming first (~150-250ms)
      if (await _ensureSttInitialized()) {
        _usingOfflineWhisper = false;
        _usingOnDeviceStt = true;
        _js('status', '⚡ التسميع المحلي الفوري (نواة الجهاز) نشط بدون إنترنت — اقرأ الآن');
        final ok = await _listenStt(onDevice: true);
        if (ok) return;
        _usingOnDeviceStt = false;
      }
    }

    // Offline Tier 2 (or OS STT unavailable): 100% On-Device Bundled Whisper Tiny Quran GGML
    _js('status', '⏳ [3] جارٍ تجهيز نموذج التسميع المحلي...');
    final modelPath = await _prepareBundledWhisperModel();
    if (modelPath != null) {
      final started = await _startOfflineWhisperLive(modelPath, promptHint);
      if (started) return;
    } else {
      _js('status', '⚠️ [3] ملف النموذج المحلي غير موجود داخل التطبيق');
    }

    _want = false;
    _js('error', 'not-allowed');
  }

  String _cleanWhisperText(String raw) {
    return raw
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  double _computePcm16Rms(Uint8List chunk) {
    if (chunk.length < 2) return 0.0;
    final sampleCount = chunk.length ~/ 2;
    final bd = ByteData.sublistView(chunk);
    double sumSq = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sumSq += v * v;
    }
    return math.sqrt(sumSq / sampleCount);
  }

  Uint8List _wrapPcm16AsWav(Uint8List pcmBytes, {int sampleRate = 16000, int channels = 1}) {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final dataSize = pcmBytes.length;
    final header = ByteData(44);
    // RIFF header
    header.setUint8(0, 0x52); header.setUint8(1, 0x49); header.setUint8(2, 0x46); header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8, 0x57); header.setUint8(9, 0x41); header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // fmt chunk
    header.setUint8(12, 0x66); header.setUint8(13, 0x6d); header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little); // bits per sample
    // data chunk
    header.setUint8(36, 0x64); header.setUint8(37, 0x61); header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);
    final out = Uint8List(44 + dataSize);
    out.setRange(0, 44, header.buffer.asUint8List());
    out.setRange(44, 44 + dataSize, pcmBytes);
    return out;
  }

  Future<bool> _startOfflineWhisperLive(String modelPath, String? promptHint) async {
    try {
      var micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        micStatus = await Permission.microphone.request();
      }
      final hasPerm = micStatus.isGranted || await _recorder.hasPermission();
      if (!hasPerm) {
        _want = false;
        _js('error', 'not-allowed');
        return true;
      }
      _js('status', '⏳ جارٍ تشغيل محرك التسميع المحلي دون إنترنت...');
      await _stopOfflineWhisperLive(emitFinal: false);

      _livePartialsCount = 0;
      _speechActiveMs = 0;
      _chunkedModeActive = false;
    _wavLoopEpoch++;
    _liveWatchdogTimer?.cancel();

      final rawPcmStream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        echoCancel: false,
        noiseSuppress: false,
      ));

      bool switchedToChunked = false;
      final pcmStream = rawPcmStream.map<Uint8List>((chunk) {
        final rms = _computePcm16Rms(chunk);
        final chunkMs = (chunk.length ~/ 32); // 16kHz * 2 bytes = 32 bytes/ms
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final levelPct = (rms * 420.0).clamp(0.0, 100.0).round();
        if (nowMs - _lastLevelEmitMs >= 220) {
          _lastLevelEmitMs = nowMs;
          _js('level', levelPct);
        }
        if (rms > 0.005) {
          _speechActiveMs += chunkMs;
        }
        if (_livePartialsCount == 0 && nowMs - _lastDiagStatusMs >= 900) {
          _lastDiagStatusMs = nowMs;
          _js('status', '🎙️ التسميع المحلي يستمع (مستوى الصوت: $levelPct%) — اقرأ الآن...');
        }
        // Self-healing watchdog: if 3.5s of real voice produced 0 live partials (e.g. strict native gate),
        // seamlessly switch to deterministic Chunked-WAV local transcription!
        if (!switchedToChunked && _want && _livePartialsCount == 0 && _speechActiveMs >= 3500) {
          switchedToChunked = true;
          Future.microtask(() => _switchToOfflineWhisperChunked());
        }
        return chunk;
      });

      final session = await _whisper.transcribeLive(
        model: WhisperModel.tiny,
        pcm16Stream: pcmStream,
        lang: 'ar',
        initialPrompt: null,
        suppressNonSpeechTokens: false,
        keepModelLoaded: true,
        gateRmsMin: 0.0005,
        gateVoiceRatio: 1.05,
        gateNoiseFloorCap: 0.02,
      );
      _usingOfflineWhisper = true;
      _whisperSession = session;
      _js('status', '🎙️ التسميع المحلي جاهز بدون إنترنت — اقرأ من أي موضع في الصفحة');
      _liveWatchdogTimer?.cancel();
      _liveWatchdogTimer = Timer(const Duration(milliseconds: 3000), () {
        if (_want && !_chunkedModeActive && _livePartialsCount == 0) {
          _switchToOfflineWhisperChunked();
        }
      });
      _whisperPartialSub = session.partials.listen((text) {
        if (!_want || _chunkedModeActive) return;
        final clean = _cleanWhisperText(text);
        if (clean.isNotEmpty) {
          _livePartialsCount++;
          _js('result', {'text': clean, 'final': false, 'offlineWhisper': true});
        }
      }, onError: (Object err) {
        if (_want && !_chunkedModeActive) {
          _switchToOfflineWhisperChunked();
        }
      });
      return true;
    } catch (e) {
      // If transcribeLive fails to start on this device, fall back immediately to Chunked-WAV local Whisper!
      return await _switchToOfflineWhisperChunked();
    }
  }

  Future<bool> _startOfflineWhisperDirectWav(String modelPath) async {
    try {
      _js('status', '⏳ [4] فحص صلاحية الميكروفون...');
      var micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        micStatus = await Permission.microphone.request();
      }
      final hasPerm = micStatus.isGranted || await _recorder.hasPermission();
      if (!hasPerm) {
        _want = false;
        _js('error', 'not-allowed');
        return true;
      }
      await _stopOfflineWhisperLive(emitFinal: false);
      return await _switchToOfflineWhisperChunked();
    } catch (e) {
      _js('status', '⚠️ [4] خطأ في تهيئة الميكروفون: $e');
      return false;
    }
  }

  Future<bool> _switchToOfflineWhisperChunked() async {
    if (!_want || _chunkedModeActive) return true;
    _chunkedModeActive = true;
    _usingOfflineWhisper = true;
    _liveWatchdogTimer?.cancel();
    _chunkAccumulatedText = '';
    _offlineHeardAny = false;
    _pendingTranscribeJobs = 0;
    _chunkBuffer.clear();
    final myEpoch = ++_wavLoopEpoch;
    try {
      await _whisperPartialSub?.cancel();
      _whisperPartialSub = null;
      final oldSess = _whisperSession;
      _whisperSession = null;
      try { if (await _recorder.isRecording()) await _recorder.stop(); } catch (_) {}
      try { await oldSess?.stop(); } catch (_) {}

      _js('status', '🎙️ التسميع المحلي (وضع ملفات WAV المباشر) نشط — اقرأ الآن...');
      _runOfflineWavLoop(myEpoch);
      return true;
    } catch (e) {
      _chunkedModeActive = false;
      _js('status', '⚠️ تعذّر تشغيل التسميع المحلي: $e');
      return false;
    }
  }

  Future<void> _transcribeWavSegmentAsync(String recordedPath, int myEpoch, double maxDb) async {
    _isTranscribingNow = true;
    try {
      final f = File(recordedPath);
      if (!f.existsSync()) return;
      final sz = await f.length();
      if (sz <= 4000) {
        _js('status', '⚠️ [5] ملف التسجيل فارغ ($sz bytes) — تأكد من إذن الميكروفون');
        return;
      }
      // Skip pure silence segments (< -45 dBFS) to save CPU & avoid Whisper silence hallucinations
      if (maxDb < -45.0) {
        if (!_offlineHeardAny) {
          _js('status', '🎙️ [5] التسميع المحلي يستمع الآن — ابدأ القراءة...');
        }
        return;
      }
      if (!_offlineHeardAny) {
        _js('status', '⚙️ [5] جارٍ تحليل المقطع الصوتي (${sz ~/ 1024} KB) محليًا...');
      }
      final hint = _currentPromptHint.isNotEmpty ? _currentPromptHint : null;
      final res = await _whisper.transcribe(
        model: WhisperModel.tiny,
        audioPath: recordedPath,
        lang: 'ar',
        initialPrompt: hint,
        suppressNonSpeechTokens: false,
        keepModelLoaded: true,
        noContext: true,
        maxContext: 0,
      );
      final clean = _cleanWhisperText(res?.transcription.text ?? '');
      if (_want && _chunkedModeActive && _wavLoopEpoch == myEpoch) {
        if (clean.isNotEmpty) {
          _offlineHeardAny = true;
          // Emit bounded delta chunk directly (O(1) size even after 60+ minutes — zero accumulation lag!)
          _js('result', {'text': clean, 'final': false, 'offlineDelta': true});
        } else if (!_offlineHeardAny) {
          _js('status', '🎙️ [6] التسميع المحلي نشط (${sz ~/ 1024} KB) — اقرأ بصوت أوضح...');
        }
      }
    } catch (e) {
      if (_want && _chunkedModeActive && _wavLoopEpoch == myEpoch) {
        _js('status', '⚠️ [6] خطأ في تحويل الصوت المحلي: $e');
      }
    } finally {
      _isTranscribingNow = false;
      if (_pendingTranscribeJobs > 0) _pendingTranscribeJobs--;
    }
  }

  Future<void> _runOfflineWavLoop(int myEpoch) async {
    final tmpDir = await getTemporaryDirectory();
    int idx = 0;
    Future<void> prevTranscribe = Future.value();
    while (_want && _chunkedModeActive && _wavLoopEpoch == myEpoch) {
      // Rotate 4 filenames so pipelined recording NEVER overwrites a file still being transcribed!
      final wavPath = '${tmpDir.path}/tasmee_seg_${idx++ % 4}.wav';
      double maxDb = -160.0;
      try {
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: wavPath,
        );
        // Self-throttling zero-drop adaptive segment:
        // - Minimum ~1.35s so Whisper has clean acoustic context (avoids garbled short-clip words)
        // - Flushes early at ~0.95s on a breath pause if decoder is already idle
        // - If previous decode is still busy, keeps recording smoothly (up to 2.5s) instead of DROPPING audio!
        bool heardVoiceInSeg = false;
        for (int t = 0; t < 14; t++) {
          if (!_want || !_chunkedModeActive || _wavLoopEpoch != myEpoch) break;
          await Future.delayed(const Duration(milliseconds: 180));
          try {
            final amp = await _recorder.getAmplitude();
            if (amp.current > maxDb) maxDb = amp.current;
            if (amp.current > -40.0) heardVoiceInSeg = true;
            final normPct = ((amp.current + 55.0) * 1.9).clamp(0.0, 100.0).round();
            _js('level', normPct);
            // Once decoder is idle: flush at ~0.90s on breath pause, or at ~1.44s continuously
            if (!_isTranscribingNow) {
              if (heardVoiceInSeg && t >= 3 && amp.current < -42.0) break;
              if (t >= 5) break;
            }
          } catch (_) {}
        }
        final recordedPath = await _recorder.stop();
        if (!_want || !_chunkedModeActive || _wavLoopEpoch != myEpoch) break;
        if (recordedPath != null) {
          final segDb = maxDb;
          _pendingTranscribeJobs++;
          // Zero-drop sequential pipeline: EVERY recorded segment is decoded in order with ZERO dropped words!
          prevTranscribe = prevTranscribe.then((_) {
            if (_want && _chunkedModeActive && _wavLoopEpoch == myEpoch) {
              return _transcribeWavSegmentAsync(recordedPath, myEpoch, segDb);
            } else {
              if (_pendingTranscribeJobs > 0) _pendingTranscribeJobs--;
            }
          });
        }
      } catch (e) {
        _js('status', '⚠️ [5] خطأ في التسجيل المحلي: $e');
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }
  }

  Future<void> _stopOfflineWhisperLive({bool emitFinal = true}) async {
    _chunkedModeActive = false;
    await _chunkPcmSub?.cancel();
    _chunkPcmSub = null;
    _chunkBuffer.clear();
    await _whisperPartialSub?.cancel();
    _whisperPartialSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
    final sess = _whisperSession;
    _whisperSession = null;
    if (sess != null) {
      try {
        final finalText = await sess.stop();
        final cleanFinal = _cleanWhisperText(finalText);
        if (emitFinal && cleanFinal.isNotEmpty) {
          _js('result', {'text': cleanFinal, 'final': true});
        }
      } catch (_) {}
    }
  }

  Future<bool> _listenStt({bool onDevice = false}) async {
    if (!_want) return false;
    if (_stt.isListening) return true;
    try {
      await _stt.listen(
        onResult: (r) {
          if (onDevice && r.recognizedWords.trim().isNotEmpty) {
            _onDeviceGotResult = true;
          }
          _js('result', {
            'text': r.recognizedWords,
            'final': r.finalResult,
            'alts': r.alternates.map((a) => a.recognizedWords).toList(),
            'onDeviceStt': onDevice,
          });
        },
        onSoundLevelChange: (lvl) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastLevelEmitMs >= 180) {
            _lastLevelEmitMs = nowMs;
            final pct = ((lvl + 2.0) * 10.0).clamp(0.0, 100.0).round();
            _js('level', pct);
          }
        },
        localeId: _locale,
        listenFor: const Duration(minutes: 10),
        pauseFor: const Duration(seconds: 10),
        listenOptions: SpeechListenOptions(
          onDevice: onDevice,
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
      );
      return true;
    } catch (_) {
      if (onDevice && !_onDeviceFallbackTriggered) {
        Future.microtask(() => _fallbackFromOnDeviceToWhisper(_currentPromptHint));
        return false;
      }
      _scheduleEnd();
      return false;
    }
  }

  Future<void> _stop() async {
    _want = false;
    _usingOnDeviceStt = false;
    _onDeviceFallbackTriggered = false;
    _endTimer?.cancel();
    if (_usingOfflineWhisper || _whisperSession != null) {
      await _stopOfflineWhisperLive(emitFinal: false);
      _usingOfflineWhisper = false;
    }
    try {
      await _stt.stop();
    } catch (_) {}
  }

  void _scheduleEnd() {
    _endTimer?.cancel();
    _endTimer = Timer(const Duration(milliseconds: 350), () {
      if (_want && !_usingOfflineWhisper) _js('end', null);
    });
  }

  void _onStatus(String s) {
    if (!_usingOfflineWhisper && (s == 'done' || s == 'notListening')) {
      _scheduleEnd();
    }
  }

  void _onError(dynamic e) {
    if (_usingOfflineWhisper) return;
    final msg = (e.errorMsg ?? '').toString().toLowerCase();
    if (msg.contains('permission')) {
      _want = false;
      _js('error', 'not-allowed');
    } else if (_usingOnDeviceStt &&
        (msg.contains('network') ||
            msg.contains('language') ||
            msg.contains('unavailable') ||
            msg.contains('client') ||
            msg.contains('server') ||
            msg.contains('busy') ||
            msg.contains('not_available'))) {
      // Offline Arabic pack not installed or on-device recognizer unavailable -> seamless Whisper fallback!
      Future.microtask(() => _fallbackFromOnDeviceToWhisper(_currentPromptHint));
    } else if (msg.contains('language')) {
      _want = false;
      _js('error', 'language-not-supported');
    } else {
      _scheduleEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = mq.viewPadding.top;
    final left = mq.viewPadding.left, right = mq.viewPadding.right;
    final bottom = (mq.viewPadding.bottom - mq.viewInsets.bottom).clamp(0.0, 200.0).toDouble();
    if (top != _top || bottom != _bottom || left != _left || right != _right) {
      _top = top;
      _bottom = bottom;
      _left = left;
      _right = right;
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyInsets());
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        await _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: _dark ? const Color(0xFF0C0D10) : const Color(0xFFFBF8F0),
        resizeToAvoidBottomInset: true,
        body: SizedBox.expand(child: WebViewWidget(controller: _web)),
      ),
    );
  }

  Future<void> _handleBackPress() async {
    try {
      final res = await _web.runJavaScriptReturningResult(
          "window.__tasmeeHandleBack ? window.__tasmeeHandleBack() : 'home'");
      if (res.toString().contains('handled')) {
        _lastBackPress = null;
        return;
      }
    } catch (_) {}
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) <= const Duration(seconds: 2)) {
      await _stop();
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    try {
      await _web.runJavaScript(
          "window.__tasmeeShowExitToast && window.__tasmeeShowExitToast('اضغط مرة أخرى للخروج')");
    } catch (_) {}
  }
}
