import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main() {
  // Nutné pro inicializaci pluginů (path_provider) před spuštěním aplikace
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inicializace vazeb na nativní knihovnu
  sherpa.initBindings();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const SpeechTestScreen(),
    );
  }
}

class SpeechTestScreen extends StatefulWidget {
  const SpeechTestScreen({super.key});

  @override
  State<SpeechTestScreen> createState() => _SpeechTestScreenState();
}

class _SpeechTestScreenState extends State<SpeechTestScreen> {
  sherpa.OfflineTts? _tts;
  bool _isReady = false;
  String? _error;
  String _currentLang = 'cs'; // 'cs' nebo 'en'

  final Map<String, String> _testTexts = {
    'cs': 'Ahoj! Já jsem Jirka a tohle je test přirozené češtiny přímo v tvém mobilu. Doufám, že se ti moje aplikace líbí.',
    'en': 'Hello! This is a test of the Kokoro voice model. It sounds very natural, just like Speechify, but it runs completely offline.',
  };

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  // Funkce pro přípravu souboru z assetů do dočasné paměti telefonu
  Future<String> _getAssetPath(String assetName) async {
    try {
      final byteData = await rootBundle.load(assetName);
      final directory = await getApplicationSupportDirectory();
      final fileName = assetName.split('/').last;
      final file = File('${directory.path}/$fileName');
      
      await file.create(recursive: true);
      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (e) {
      throw Exception("Chyba při kopírování assetu $assetName: $e. Máte soubor v pubspec.yaml?");
    }
  }

  Future<void> _initEngine() async {
    setState(() {
      _isReady = false;
      _error = null;
    });

    try {
      // 1. NEJDŮLEŽITĚJŠÍ: Načtení tokens.txt (Bez něj engine selže)
      final tokensPath = await _getAssetPath('assets/models/tokens.txt');
      
      String modelPath;
      String extraPath; // Pro Piper (CZ) je to .json, pro Kokoro (EN) je to voices.bin

      if (_currentLang == 'cs') {
        modelPath = await _getAssetPath('assets/models/cs_CZ-jirka-medium.onnx');
        extraPath = await _getAssetPath('assets/models/cs_CZ-jirka-medium.onnx.json');
      } else {
        modelPath = await _getAssetPath('assets/models/kokoro-v1.0.onnx');
        extraPath = await _getAssetPath('assets/models/voices-v1.0.bin');
      }

      // 2. Předání tokensPath do konfigurace modelů
      final vits = _currentLang == 'cs'
          ? sherpa.OfflineTtsVitsModelConfig(model: modelPath, lexicon: "", tokens: tokensPath)
          : const sherpa.OfflineTtsVitsModelConfig();

      final kokoro = _currentLang == 'en'
          ? sherpa.OfflineTtsKokoroModelConfig(model: modelPath, voices: extraPath, tokens: tokensPath)
          : const sherpa.OfflineTtsKokoroModelConfig();

      // Konfigurace Sherpa-ONNX
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: vits,
          kokoro: kokoro,
          numThreads: 4,
          debug: true,
        ),
      );

      _tts?.free(); // Uvolníme starý, pokud existuje
      _tts = sherpa.OfflineTts(config);
      
      if (mounted) {
        setState(() => _isReady = true);
      }
    } catch (e) {
      debugPrint("CHYBA inicializace TTS: $e");
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isReady = false;
        });
      }
    }
  }

  void _speak() {
    if (_tts == null) return;
    try {
      final text = _testTexts[_currentLang]!;
      final audio = _tts!.generate(text: text);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hlas vygenerován pro: $_currentLang (Vzorků: ${audio.samples.length})')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Chyba při mluvení: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Voice Test 2026')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'cs', label: Text('Čeština (Jirka)')),
                ButtonSegment(value: 'en', label: Text('English (Kokoro)')),
              ],
              selected: {_currentLang},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() => _currentLang = newSelection.first);
                _initEngine(); // Přenačtení modelu pro jiný jazyk
              },
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Chyba: $_error',
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                _testTexts[_currentLang]!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isReady ? _speak : null,
              icon: _isReady ? const Icon(Icons.play_arrow) : const CircularProgressIndicator(strokeWidth: 2),
              label: Text(_isReady ? 'Přečíst text' : 'Načítám AI model...'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20)),
            ),
          ],
        ),
      ),
    );
  }
}
