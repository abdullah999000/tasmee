import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
  late final WebViewController _web;
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;
  bool _want = false;
  String? _locale;
  Timer? _endTimer;
  Timer? _themeTimer;
  String? _lastInsets;
  double _top = 0, _bottom = 0;
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // keep the screen on while reciting
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('Tasmee', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        _lastInsets = null;
        _applyInsets();
      }));
    _load();
    _applyBars();
    // follow the page theme (day / night) so status-bar icons stay visible
    _themeTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final r = await _web.runJavaScriptReturningResult(
            "document.documentElement.getAttribute('data-theme')||''");
        final dark = r.toString().contains('dark');
        if (dark != _dark) {
          _dark = dark;
          _applyBars();
        }
      } catch (_) {}
    });
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
    // a real https origin so localStorage / fetch behave like a normal site
    await _web.loadHtmlString(html, baseUrl: 'https://tasmee.app/');
  }

  // The page fills the whole screen (under the status bar and the gesture bar).
  // We pad its content by the system bar sizes so nothing is hidden behind them.
  void _applyInsets() {
    final key = '$_top/$_bottom';
    if (key == _lastInsets) return;
    _lastInsets = key;
    final css = 'html{padding-top:${_top}px!important;min-height:100%}'
        'body{min-height:100vh;padding-bottom:calc(84px + ${_bottom}px)!important}'
        '#fb{padding-bottom:calc(8px + ${_bottom}px)!important}'
        '#modal .box{padding-bottom:calc(20px + ${_bottom}px)!important}';
    _web.runJavaScript("(function(){var s=document.getElementById('__ins');"
        "if(!s){s=document.createElement('style');s.id='__ins';document.head.appendChild(s)}"
        's.textContent=${jsonEncode(css)}})()');
  }

  @override
  void dispose() {
    _endTimer?.cancel();
    _themeTimer?.cancel();
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
      if (o['a'] == 'start') {
        _start();
      } else if (o['a'] == 'stop') {
        _stop();
      }
    } catch (_) {}
  }

  Future<void> _start() async {
    _want = true;
    if (!_ready) {
      _ready = await _stt.initialize(onStatus: _onStatus, onError: _onError);
      if (!_ready) {
        _want = false;
        _js('error', 'not-allowed');
        return;
      }
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
    }
    await _listen();
  }

  Future<void> _listen() async {
    if (!_want || _stt.isListening) return;
    try {
      await _stt.listen(
        onResult: (r) =>
            _js('result', {'text': r.recognizedWords, 'final': r.finalResult}),
        localeId: _locale,
        listenFor: const Duration(minutes: 10),
        pauseFor: const Duration(seconds: 10),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (_) {
      _scheduleEnd();
    }
  }

  Future<void> _stop() async {
    _want = false;
    _endTimer?.cancel();
    try {
      await _stt.stop();
    } catch (_) {}
  }

  // Android ends each recognition session after a pause: tell the page,
  // which restarts listening exactly like the browser version does.
  void _scheduleEnd() {
    _endTimer?.cancel();
    _endTimer = Timer(const Duration(milliseconds: 350), () {
      if (_want) _js('end', null);
    });
  }

  void _onStatus(String s) {
    if (s == 'done' || s == 'notListening') _scheduleEnd();
  }

  void _onError(dynamic e) {
    final msg = (e.errorMsg ?? '').toString();
    if (msg.contains('permission')) {
      _want = false;
      _js('error', 'not-allowed');
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
    final top = mq.viewPadding.top, bottom = mq.viewPadding.bottom;
    if (top != _top || bottom != _bottom) {
      _top = top;
      _bottom = bottom;
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyInsets());
    }
    // no SafeArea: the web page itself covers the entire screen
    return Scaffold(
      backgroundColor: _dark ? Colors.black : const Color(0xFFF6F1E7),
      resizeToAvoidBottomInset: false,
      body: SizedBox.expand(child: WebViewWidget(controller: _web)),
    );
  }
}
