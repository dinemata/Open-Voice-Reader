import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:audioplayers/audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isReady = false;
  String? _error;
  String _currentLang = 'cs'; 
  String _appSupportDir = "";

  final Map<String, String> _testTexts = {
    'cs': 'Ahoj! Já jsem Jirka a tohle je test přirozené češtiny přímo v tvém mobilu. Doufám, že mě teď slyšíš!',
    'en': 'Hello! This is a test of the Kokoro voice model. You should be able to hear me clearly now.',
  };

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _tts?.free();
    super.dispose();
  }

  // Robustní funkce pro kopírování souborů
  Future<String> _prepareFile(String assetPath, {String? targetPath}) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      final directory = await getApplicationSupportDirectory();
      
      final finalPath = targetPath ?? assetPath;
      final file = File('${directory.path}/$finalPath');
      
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      final buffer = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      await file.writeAsBytes(buffer, flush: true);
      return file.path;
    } catch (e) {
      debugPrint("Asset $assetPath chybí, přeskakuji...");
      return "";
    }
  }

  Future<void> _initEngine() async {
    setState(() {
      _isReady = false;
      _error = null;
    });

    try {
      final dir = await getApplicationSupportDirectory();
      _appSupportDir = dir.path;
      
      // CESTY K SLOŽKÁM
      final kokoroBaseAsset = 'assets/models/kokoro-en-v0_19';
      final jirkaBaseAsset = 'assets/models/vits-piper-cs_CZ-jirka-medium';
      
      // 1. PŘÍPRAVA SDÍLENÉ SLOŽKY ESPEAK-NG (Sjednocení dat)
      const espeakDirName = 'shared-espeak-ng-data';
      
      // Kopírujeme CORE soubory (z Kokoro balíčku, protože je kompletnější)
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/phontab', targetPath: '$espeakDirName/phontab');
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/phondata', targetPath: '$espeakDirName/phondata');
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/phondata-manifest', targetPath: '$espeakDirName/phondata-manifest');
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/phonindex', targetPath: '$espeakDirName/phonindex');
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/intonations', targetPath: '$espeakDirName/intonations');
      
      // Slovníky
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/en_dict', targetPath: '$espeakDirName/en_dict');
      await _prepareFile('$jirkaBaseAsset/espeak-ng-data/cs_dict', targetPath: '$espeakDirName/cs_dict');
      
      // Jazyková pravidla (přesně podle pubspec.yaml)
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/lang/gmw/en', targetPath: '$espeakDirName/lang/gmw/en');
      await _prepareFile('$kokoroBaseAsset/espeak-ng-data/lang/gmw/en-US', targetPath: '$espeakDirName/lang/gmw/en-US');

      // 2. VYTVOŘENÍ HLASŮ
      final voicesDir = Directory('$_appSupportDir/$espeakDirName/voices');
      if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
      
      // Mapujeme cs na cs, en-us na en-US pravidla
      await File('${voicesDir.path}/cs').writeAsString("name cs\nlanguage cs\n");
      await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en-US\n");

      sherpa.OfflineTtsModelConfig modelConfig;

      if (_currentLang == 'cs') {
        final modelPath = await _prepareFile('$jirkaBaseAsset/cs_CZ-jirka-medium.onnx');
        final tokensPath = await _prepareFile('$jirkaBaseAsset/tokens.txt');

        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: modelPath, 
            tokens: tokensPath, 
            dataDir: '$_appSupportDir/$espeakDirName'
          ),
          numThreads: 4,
          debug: true,
        );
      } else {
        final modelPath = await _prepareFile('$kokoroBaseAsset/model.onnx');
        final voicesPath = await _prepareFile('$kokoroBaseAsset/voices.bin');
        final tokensPath = await _prepareFile('$kokoroBaseAsset/tokens.txt');

        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: modelPath, 
            voices: voicesPath, 
            tokens: tokensPath,
            dataDir: '$_appSupportDir/$espeakDirName',
          ),
          numThreads: 4,
          debug: true,
        );
      }

      _tts?.free();
      _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig, maxNumSenetences: 1));
      
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint("CHYBA inicializace: $e");
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isReady = false;
        });
      }
    }
  }

  void _speak() async {
    if (_tts == null) return;
    try {
      final text = _testTexts[_currentLang]!;
      // SID 9 je George pro Kokoro, 0 pro Piper
      final sid = (_currentLang == 'en') ? 9 : 0;
      
      final audio = _tts!.generate(text: text, sid: sid);
      
      final tempDir = await getTemporaryDirectory();
      final wavPath = '${tempDir.path}/output.wav';
      
      final success = sherpa.writeWave(
        filename: wavPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      if (success) {
        await _audioPlayer.play(DeviceFileSource(wavPath));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Přehrávám...')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
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
                ButtonSegment(value: 'cs', label: Text('CZ (Jirka)')),
                ButtonSegment(value: 'en', label: Text('EN (Kokoro)')),
              ],
              selected: {_currentLang},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() => _currentLang = newSelection.first);
                _initEngine();
              },
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Chyba: $_error', style: const TextStyle(color: Colors.red, fontSize: 10), textAlign: TextAlign.center),
              ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(_testTexts[_currentLang]!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isReady ? _speak : null,
              icon: _isReady ? const Icon(Icons.volume_up) : const CircularProgressIndicator(strokeWidth: 2),
              label: Text(_isReady ? 'Přečíst text' : 'Načítám AI model...'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20)),
            ),
          ],
        ),
      ),
    );
  }
}
