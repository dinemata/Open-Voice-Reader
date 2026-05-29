import 'package:flutter/material.dart';

class ModelConfig {
  final String id;
  final String name;
  final String langCode;
  final String assetDir;
  final String modelFile;
  final String configFile;
  final int sid;
  final int cpuLoad;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.langCode,
    required this.assetDir,
    required this.modelFile,
    required this.configFile,
    required this.sid,
    required this.cpuLoad,
  });
}

const List<ModelConfig> availableModels = [
  ModelConfig(
    id: 'cs_jirka',
    name: 'Piper (Jirka)',
    langCode: 'cs',
    assetDir: 'assets/models/vits-piper-cs_CZ-jirka-medium',
    modelFile: 'cs_CZ-jirka-medium.onnx',
    configFile: 'cs_CZ-jirka-medium.onnx.json',
    sid: 0,
    cpuLoad: 2,
  ),
  ModelConfig(
    id: 'en_alan',
    name: 'Piper (Alan)',
    langCode: 'en',
    assetDir: 'assets/models/vits-piper-en_GB-alan-medium',
    modelFile: 'en_GB-alan-medium.onnx',
    configFile: 'en_GB-alan-medium.onnx.json',
    sid: 0,
    cpuLoad: 2,
  ),
  ModelConfig(
    id: 'en_kokoro',
    name: 'Kokoro',
    langCode: 'en',
    assetDir: 'assets/models/kokoro-en-v0_19',
    modelFile: 'model.onnx',
    configFile: 'voices.bin',
    sid: 9,
    cpuLoad: 3,
  ),
];

class BookModel {
  final String id;
  String filePath;
  String title;
  int lastChunkIndex;
  final int totalChunks;
  final int totalWords;
  String? coverPath;
  String? lastModelId;

  BookModel({
    required this.id,
    required this.filePath,
    required this.title,
    this.lastChunkIndex = 0,
    required this.totalChunks,
    required this.totalWords,
    this.coverPath,
    this.lastModelId,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'filePath': filePath,
    'title': title,
    'lastChunkIndex': lastChunkIndex,
    'totalChunks': totalChunks,
    'totalWords': totalWords,
    'coverPath': coverPath,
    'lastModelId': lastModelId,
  };

  factory BookModel.fromMap(Map<String, dynamic> map) => BookModel(
    id: map['id'],
    filePath: map['filePath'],
    title: map['title'],
    lastChunkIndex: map['lastChunkIndex'] ?? 0,
    totalChunks: map['totalChunks'],
    totalWords: map['totalWords'],
    coverPath: map['coverPath'],
    lastModelId: map['lastModelId'],
  );
}

class PdfWordGeometry {
  final Rect bounds;
  final String text;
  PdfWordGeometry({required this.bounds, required this.text});

  Map<String, dynamic> toMap() => {
    'text': text,
    'left': bounds.left,
    'top': bounds.top,
    'width': bounds.width,
    'height': bounds.height,
  };

  factory PdfWordGeometry.fromMap(Map<String, dynamic> map) => PdfWordGeometry(
    text: map['text'],
    bounds: Rect.fromLTWH(map['left'], map['top'], map['width'], map['height']),
  );
}

class PdfChunkMetadata {
  final String text;
  final int pageNumber;
  final List<PdfWordGeometry> pdfWords;
  PdfChunkMetadata({required this.text, required this.pageNumber, required this.pdfWords});

  Map<String, dynamic> toMap() => {
    'text': text,
    'pageNumber': pageNumber,
    'pdfWords': pdfWords.map((w) => w.toMap()).toList(),
  };

  factory PdfChunkMetadata.fromMap(Map<String, dynamic> map) => PdfChunkMetadata(
    text: map['text'],
    pageNumber: map['pageNumber'],
    pdfWords: (map['pdfWords'] as List).map((w) => PdfWordGeometry.fromMap(w)).toList(),
  );
}

class HighlightData {
  final List<Rect> sentenceRects;
  final Rect? wordRect;
  HighlightData({required this.sentenceRects, this.wordRect});
}

class PdfHighlightPainter extends CustomPainter {
  final List<Rect> sentenceRects;
  final Rect? wordRect;
  final Color primaryColor;
  PdfHighlightPainter({required this.sentenceRects, required this.wordRect, required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final sentencePaint = Paint()..color = primaryColor.withOpacity(0.15)..style = PaintingStyle.fill;
    for (final rect in sentenceRects) { canvas.drawRect(rect, sentencePaint); }
    if (wordRect != null) {
      final wordPaint = Paint()..color = primaryColor.withOpacity(0.35)..style = PaintingStyle.fill;
      canvas.drawRect(wordRect!, wordPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PdfHighlightPainter oldDelegate) =>
      oldDelegate.sentenceRects != sentenceRects || oldDelegate.wordRect != wordRect;
}