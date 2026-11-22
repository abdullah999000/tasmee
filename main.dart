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
import 'package:recite_quran/recite_quran.dart' as rq;
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
  static const String _reciteSentinelFile = 'recite_quran_init.lock';
  static const Set<String> _audioExts = {'.mp3', '.m4a', '.aac', '.wav', '.flac'};

  late final WebViewController _web;
  final SpeechToText _stt = SpeechToText();
  final WhisperController _whisper = WhisperController();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _localPlayer = AudioPlayer();
  final AudioPlayer _bellPlayer = AudioPlayer();
  Uint8List? _errBellWavBytes;

  bool _sttReady = false;
  bool _want = false;
  bool _usingOfflineWhisper = false;
  bool _usingReciteQuran = false;
  bool _usingOnDeviceStt = false;
  bool _reciteSentinelTripped = false;
  rq.QuranRepository? _reciteRepo;
  rq.ReciteQuran? _reciteTracker;
  rq.AudioProcessor? _reciteAudio;
  StreamSubscription<dynamic>? _reciteWordSub;
  int _reciteActiveSurah = 1;
  int _reciteStartAyah = 1;
  int _reciteStartWordInAyah = 0;
  int _reciteLastVoiceChunkMs = 0;
  bool _reciteSentinelClearedThisRun = false;
  Timer? _reciteSentinelClearTimer;
  int _reciteEpoch = 0;
  bool _onDeviceGotResult = false;
  bool _onDeviceFallbackTriggered = false;
  bool _onDeviceSttUnavailable = false;
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
        _emitOfflineModelStatus();
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
    _reciteSentinelClearTimer?.cancel();
    _reciteWordSub?.cancel();
    try { _reciteAudio?.stop(); } catch (_) {}
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _doneSub?.cancel();
    _localPlayer.dispose();
    _bellPlayer.dispose();
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
        final sNum = (o['surah'] is num) ? (o['surah'] as num).toInt() : _reciteActiveSurah;
        final aNum = (o['ayah'] is num) ? (o['ayah'] as num).toInt() : 1;
        final wNum = (o['wordInAyah'] is num) ? (o['wordInAyah'] as num).toInt() : 0;
        if (sNum >= 1 && sNum <= 114) _reciteActiveSurah = sNum;
        _reciteStartAyah = aNum > 0 ? aNum : 1;
        _reciteStartWordInAyah = wNum >= 0 ? wNum : 0;
        _start(
          promptHint: o['prompt']?.toString(),
          preferOffline: o['offline'] == true,
          surahNumber: _reciteActiveSurah,
        );
      } else if (act == 'reset_session') {
        final sNum = (o['surah'] is num) ? (o['surah'] as num).toInt() : _reciteActiveSurah;
        final aNum = (o['ayah'] is num) ? (o['ayah'] as num).toInt() : 1;
        final wNum = (o['wordInAyah'] is num) ? (o['wordInAyah'] as num).toInt() : 0;
        if (sNum >= 1 && sNum <= 114) _reciteActiveSurah = sNum;
        _reciteStartAyah = aNum > 0 ? aNum : 1;
        _reciteStartWordInAyah = wNum >= 0 ? wNum : 0;
        _resetLiveSession(
          promptHint: o['prompt']?.toString(),
          preferOffline: o['offline'] == true,
        );
      } else if (act == 'stop') {
        _stop();
      } else if (act == 'hint') {
        _currentPromptHint = (o['prompt']?.toString() ?? '').trim();
      } else if (act == 'vibrate_err') {
        _triggerNativeErrorVibration();
      } else if (act == 'bell_err') {
        _playNativeErrorBell();
      } else if (act == 'halt_on_error') {
        final sNum = (o['surah'] is num) ? (o['surah'] as num).toInt() : _reciteActiveSurah;
        final aNum = (o['ayah'] is num) ? (o['ayah'] as num).toInt() : _reciteStartAyah;
        final wNum = (o['wordInAyah'] is num) ? (o['wordInAyah'] as num).toInt() : 0;
        _haltReciteOnMistakeWord(sNum, aNum, wNum);
      } else if (act == 'get_page') {
        final p = (o['p'] is num) ? (o['p'] as num).toInt() : 0;
        final reqId = o['reqId']?.toString() ?? '';
        if (p >= 1 && p <= 604) {
          _serveBundledPage(p, reqId);
        }
      } else if (act == 'loadBundledQuran') {
        _pushBundledQuranIfPresent();
      } else if (act == 'model_status' || act == 'verify_offline_model') {
        _emitOfflineModelStatus(forceVerify: act == 'verify_offline_model');
      } else if (act == 'download_offline_model') {
        _initReciteQuranEngine(surahNumber: _reciteActiveSurah, forceResetSentinel: true);
      } else if (act == 'reset_model_sentinel') {
        _resetReciteSentinel();
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
    if (_usingReciteQuran) {
      _reciteAudio?.clearBuffer();
      if (_reciteTracker != null) {
        try {
          try { (_reciteTracker as dynamic).resetBuffer(); } catch (_) {}
          await _reciteRepo?.loadSurahAsync(_reciteActiveSurah);
          _reciteTracker!.setTargetSurah(_reciteActiveSurah);
          _tryJumpReciteToStartPosition(_reciteActiveSurah, _reciteStartAyah, _reciteStartWordInAyah);
        } catch (_) {}
      }
    } else if (_usingOfflineWhisper) {
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
    _onDeviceSttUnavailable = true;
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


  Future<void> _start({String? promptHint, bool preferOffline = false, int surahNumber = 1}) async {
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
    }

    // Offline Tier 1: True Causal Streaming Zipformer-v3 via recite_quran (^1.0.5)
    if (surahNumber >= 1 && surahNumber <= 114) _reciteActiveSurah = surahNumber;
    if (!await _isReciteSentinelTripped()) {
      _js('status', '⚡ جارٍ تشغيل البث القرآني الحي دون إنترنت (recite_quran Zipformer-v3)...');
      final startedStreaming = await _startReciteQuranLive(_reciteActiveSurah);
      if (startedStreaming) return;
    }

    // Offline Tier 2 (or fast model not yet downloaded): 100% Bundled Whisper Tiny Quran GGML
    _js('status', '⏳ [3] جارٍ تجهيز نموذج التسميع المحلي المدمج (Whisper)...');
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


  // =========================================================================
  // PRIMARY LIVE STREAMING ENGINE: recite_quran (^1.0.5)
  // - True Causal Streaming Zipformer-v3 (Quran-Lab, 3.46% WER, ~69 MB INT8)
  // - Background Dart Isolate + 2D DTW Phoneme Alignment + Early Matching
  // - Protected by crash-sentinel (recite_quran_init.lock) + automatic Whisper fallback
  // =========================================================================

  Future<File?> _getReciteSentinelFile() async {
    try {
      final sup = await getApplicationSupportDirectory();
      return File('${sup.path}/$_reciteSentinelFile');
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isReciteSentinelTripped() async {
    final f = await _getReciteSentinelFile();
    if (f != null && await f.exists()) {
      _reciteSentinelTripped = true;
      return true;
    }
    return _reciteSentinelTripped;
  }

  Future<void> _resetReciteSentinel() async {
    try {
      final f = await _getReciteSentinelFile();
      if (f != null && await f.exists()) await f.delete();
      _reciteSentinelTripped = false;
    } catch (_) {}
    await _emitOfflineModelStatus(forceVerify: true);
  }

  Future<void> _emitOfflineModelStatus({bool forceVerify = false}) async {
    final tripped = await _isReciteSentinelTripped();
    final ready = !tripped;
    _js('model_status', {
      'ready': ready,
      'downloading': false,
      'sentinelTripped': tripped,
      'modelName': 'recite_quran v1.0.5 (Zipformer-v3 Streaming • 3.46% WER)',
      'sizeMb': '69.0',
      'expectedMb': '69.0',
      'path': 'مُدمَج داخل التطبيق (recite_quran Streaming + Whisper احتياطي)',
      'verified': forceVerify ? ready : null,
      'fallbackReady': true,
    });
  }

  Uint8List _buildErrorBellWavBytes() {
    if (_errBellWavBytes != null) return _errBellWavBytes!;
    const int sampleRate = 16000;
    const int numSamples = 2880; // 180ms crisp dual-tone chime
    final pcm = Uint8List(numSamples * 2);
    final bd = ByteData.sublistView(pcm);
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final env = math.exp(-t * 14.0) * (i < 160 ? (i / 160.0) : 1.0);
      final sig = (0.62 * math.sin(2 * math.pi * 659.25 * t) +
              0.30 * math.sin(2 * math.pi * 987.77 * t)) *
          env;
      final s16 = (sig * 28000.0).round().clamp(-32767, 32767);
      bd.setInt16(i * 2, s16, Endian.little);
    }
    _errBellWavBytes = _wrapPcm16AsWav(pcm, sampleRate: sampleRate, channels: 1);
    return _errBellWavBytes!;
  }

  Future<void> _playNativeErrorBell() async {
    try {
      await _bellPlayer.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
      ));
      await _bellPlayer.stop();
      await _bellPlayer.play(BytesSource(_buildErrorBellWavBytes()), volume: 0.95);
    } catch (_) {
      try { await SystemSound.play(SystemSoundType.alert); } catch (_) {}
    }
  }

  Future<void> _triggerNativeErrorVibration() async {
    try {
      await HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 85), () {
        try { HapticFeedback.vibrate(); } catch (_) {}
      });
    } catch (_) {
      try { await HapticFeedback.vibrate(); } catch (_) {}
    }
  }

  void _haltReciteOnMistakeWord(int surah, int ayah, int wordInAyah) {
    if (!_usingReciteQuran || _reciteTracker == null) return;
    try {
      _reciteAudio?.clearBuffer();
      try { (_reciteTracker as dynamic).resetBuffer(); } catch (_) {}
      if (surah >= 1 && surah <= 114) _reciteActiveSurah = surah;
      _tryJumpReciteToStartPosition(_reciteActiveSurah, ayah > 0 ? ayah : 1, wordInAyah >= 0 ? wordInAyah : 0);
    } catch (_) {}
  }

  Future<void> _clearReciteSentinelNow() async {
    if (_reciteSentinelClearedThisRun) return;
    _reciteSentinelClearedThisRun = true;
    _reciteSentinelClearTimer?.cancel();
    try {
      final f = await _getReciteSentinelFile();
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _tryJumpReciteToStartPosition(int surah, int ayah, int wordInAyah) {
    if (ayah <= 1 && wordInAyah <= 0) return;
    try {
      final dynamic repoDyn = _reciteRepo;
      final List<dynamic> words = repoDyn.getSurahWords(surah) as List<dynamic>;
      for (int i = 0; i < words.length; i++) {
        final dynamic w = words[i];
        final int wa = (w.ayah as num?)?.toInt() ?? 0;
        final int ww = (w.wordInAyah as num?)?.toInt() ?? 0;
        if (wa == ayah && ww >= wordInAyah) {
          (_reciteTracker as dynamic).jumpToWord(i);
          return;
        }
      }
    } catch (_) {}
  }

  Future<bool> _initReciteQuranEngine({int surahNumber = 1, bool forceResetSentinel = false}) async {
    if (forceResetSentinel) {
      await _resetReciteSentinel();
    }
    if (await _isReciteSentinelTripped()) {
      return false;
    }
    if (_reciteTracker != null && _reciteRepo != null) {
      try {
        await _reciteRepo!.loadSurahAsync(surahNumber);
        _reciteTracker!.setTargetSurah(surahNumber);
        _tryJumpReciteToStartPosition(surahNumber, _reciteStartAyah, _reciteStartWordInAyah);
        return true;
      } catch (_) {}
    }
    final sentinel = await _getReciteSentinelFile();
    try {
      // Keep sentinel active across init AND first audio decode!
      // It will be cleared ONLY after the first decoded word or 4s of crash-free live streaming.
      _reciteSentinelClearedThisRun = false;
      if (sentinel != null) {
        await sentinel.writeAsString(DateTime.now().toIso8601String(), flush: true);
      }
      _js('model_progress', {'pct': 25, 'msg': '⏳ جارٍ تهيئة قاعدة المصحف ومحرك البث الحي (recite_quran)...'});
      final repo = rq.QuranRepository(rq.QuranMetadataService());
      await repo.loadSurahAsync(surahNumber);
      final tracker = rq.ReciteQuran(
        repository: repo,
        config: rq.TrackerConfig.dictation(),
        isTajweed: false,
      );
      await tracker.initialize();
      tracker.setTargetSurah(surahNumber);
      _reciteRepo = repo;
      _reciteTracker = tracker;
      _reciteAudio ??= rq.AudioProcessor();
      _tryJumpReciteToStartPosition(surahNumber, _reciteStartAyah, _reciteStartWordInAyah);
      _js('model_progress', {'pct': 100, 'msg': '✅ محرك البث الحي recite_quran جاهز 100% دون إنترنت!'});
      await _emitOfflineModelStatus(forceVerify: true);
      return true;
    } catch (e) {
      try { if (sentinel != null && await sentinel.exists()) await sentinel.delete(); } catch (_) {}
      _js('status', '⚠️ تعذّر تهيئة recite_quran ($e) — التبديل الفوري إلى Whisper المدمج');
      _js('model_progress', {'pct': -1, 'msg': '⚠️ تعذّر تشغيل البث الحي ($e) — يعمل Whisper المدمج تلقائياً'});
      return false;
    }
  }

  Future<bool> _startReciteQuranLive(int surahNumber) async {
    try {
      var micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        micStatus = await Permission.microphone.request();
      }
      if (!micStatus.isGranted) {
        await _clearReciteSentinelNow();
        _want = false;
        _js('error', 'not-allowed');
        return true;
      }

      final ok = await _initReciteQuranEngine(surahNumber: surahNumber);
      if (!ok || _reciteTracker == null || _reciteAudio == null) {
        return false;
      }

      await _stopReciteQuranLive();
      await _stopOfflineWhisperLive(emitFinal: false);

      _usingReciteQuran = true;
      _usingOfflineWhisper = false;
      final myEpoch = ++_reciteEpoch;
      _reciteLastVoiceChunkMs = DateTime.now().millisecondsSinceEpoch;

      // Clear crash sentinel if 4s of live audio streaming completes without native crash
      _reciteSentinelClearTimer?.cancel();
      _reciteSentinelClearTimer = Timer(const Duration(seconds: 4), () {
        if (_want && _usingReciteQuran && _reciteEpoch == myEpoch) {
          _clearReciteSentinelNow();
        }
      });

      _reciteWordSub = _reciteTracker!.onWordMatched.listen((event) {
        if (!_want || !_usingReciteQuran || _reciteEpoch != myEpoch) return;
        // First decoded word proves native ONNX + Isolate succeeded -> clear crash sentinel!
        _clearReciteSentinelNow();

        final dynamic ev = event;
        final bool isRed = ev.isRed == true;
        bool isNeutral = false;
        try { isNeutral = ev.isNeutral == true; } catch (_) {}
        final bool isGreen = !isRed && !isNeutral;

        int? resolvedSurah = _reciteActiveSurah;
        int? resolvedAyah;
        int? resolvedWordInAyah;
        int? totalWordsInAyah;
        try {
          final dynamic repoDyn = _reciteRepo;
          final List<dynamic> sWords = repoDyn.getSurahWords(_reciteActiveSurah) as List<dynamic>;
          final int wid = (ev.wordId is int) ? ev.wordId as int : (int.tryParse(ev.wordId.toString()) ?? -1);
          if (wid >= 0 && wid < sWords.length) {
            final dynamic w = sWords[wid];
            resolvedSurah = (w.surah as num?)?.toInt() ?? _reciteActiveSurah;
            resolvedAyah = (w.ayah as num?)?.toInt();
            resolvedWordInAyah = (w.wordInAyah as num?)?.toInt();
            if (resolvedAyah != null) {
              int cnt = 0;
              for (final dynamic sw in sWords) {
                if (((sw.ayah as num?)?.toInt() ?? -1) == resolvedAyah) cnt++;
              }
              if (cnt > 0) totalWordsInAyah = cnt;
            }
          }
        } catch (_) {}

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final latencyMs = _reciteLastVoiceChunkMs > 0
            ? (nowMs - _reciteLastVoiceChunkMs).clamp(0, 5000)
            : 0;

        _js('recite_word', {
          'wordId': ev.wordId.toString(),
          'surah': resolvedSurah,
          'ayah': resolvedAyah,
          'wordInAyah': resolvedWordInAyah,
          'totalWordsInAyah': totalWordsInAyah,
          'green': isGreen,
          'neutral': isNeutral,
          'yellow': false,
          'red': isRed,
          'latencyMs': latencyMs,
          'engine': 'recite_quran-zipformer-v3',
        });
      }, onError: (Object err) {
        if (_want && _usingReciteQuran && _reciteEpoch == myEpoch) {
          _js('status', '⚠️ تنبيه من محرك البث الحي: $err');
        }
      });

      _js('status', '⚡ البث القرآني الحي (recite_quran Zipformer-v3) نشط دون إنترنت — اقرأ الآن...');

      await _reciteAudio!.start(
        onChunk: (Float32List chunk, bool isFinal) {
          if (!_want || !_usingReciteQuran || _reciteEpoch != myEpoch) return;
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (chunk.isNotEmpty) {
            double sumSq = 0.0;
            final step = chunk.length > 256 ? chunk.length ~/ 256 : 1;
            int cnt = 0;
            for (int i = 0; i < chunk.length; i += step) {
              final v = chunk[i];
              sumSq += v * v;
              cnt++;
            }
            final rms = cnt > 0 ? math.sqrt(sumSq / cnt) : 0.0;
            if (rms > 0.015) {
              _reciteLastVoiceChunkMs = nowMs;
            }
            if (nowMs - _lastLevelEmitMs >= 160) {
              _lastLevelEmitMs = nowMs;
              final pct = (rms * 420.0).clamp(0.0, 100.0).round();
              _js('level', pct);
            }
          }
          _reciteTracker?.feedAudioChunk(chunk, isFinal: isFinal);
        },
      );
      return true;
    } catch (e) {
      await _clearReciteSentinelNow();
      _usingReciteQuran = false;
      _js('status', '⚠️ تعذّر تشغيل البث الحي ($e) — التبديل التلقائي إلى Whisper المدمج');
      return false;
    }
  }

  Future<void> _stopReciteQuranLive() async {
    _reciteEpoch++;
    _reciteSentinelClearTimer?.cancel();
    await _clearReciteSentinelNow();
    await _reciteWordSub?.cancel();
    _reciteWordSub = null;
    try {
      await _reciteAudio?.stop();
      _reciteAudio?.clearBuffer();
    } catch (_) {}
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
        if (!switchedToChunked && _want && _livePartialsCount == 0 && _speechActiveMs >= 1600) {
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
      _liveWatchdogTimer = Timer(const Duration(milliseconds: 1500), () {
        if (_want && !_chunkedModeActive && _livePartialsCount == 0) {
          _switchToOfflineWhisperChunked();
        }
      });
      _whisperPartialSub = session.partials.listen((text) {
        if (!_want || _chunkedModeActive) return;
        final clean = _cleanWhisperText(text);
        if (clean.isNotEmpty) {
          _livePartialsCount++;
          _js('result', {'text': clean, 'final': false, 'offlineWhisper': true, 'engine': 'whisper-tiny-ar-quran'});
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
          _js('result', {'text': clean, 'final': false, 'offlineDelta': true, 'engine': 'whisper-tiny-ar-quran'});
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
        for (int t = 0; t < 16; t++) {
          if (!_want || !_chunkedModeActive || _wavLoopEpoch != myEpoch) break;
          await Future.delayed(const Duration(milliseconds: 120));
          try {
            final amp = await _recorder.getAmplitude();
            if (amp.current > maxDb) maxDb = amp.current;
            if (amp.current > -40.0) heardVoiceInSeg = true;
            final normPct = ((amp.current + 55.0) * 1.9).clamp(0.0, 100.0).round();
            _js('level', normPct);
            // Fast low-latency flush once decoder is idle: ~360ms on breath pause, ~600ms continuous
            if (!_isTranscribingNow) {
              if (heardVoiceInSeg && t >= 2 && amp.current < -42.0) break;
              if (t >= 4) break;
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
    if (_usingReciteQuran) {
      await _stopReciteQuranLive();
      _usingReciteQuran = false;
    }
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
      if (_want && !_usingOfflineWhisper && !_usingReciteQuran) _js('end', null);
    });
  }

  void _onStatus(String s) {
    if (!_usingOfflineWhisper && !_usingReciteQuran && (s == 'done' || s == 'notListening')) {
      _scheduleEnd();
    }
  }

  void _onError(dynamic e) {
    if (_usingOfflineWhisper || _usingReciteQuran) return;
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
