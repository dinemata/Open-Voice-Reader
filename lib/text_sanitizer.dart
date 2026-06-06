import 'dart:typed_data';
import 'dart:ui';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'model.dart';

class SanitizerOptions {
  bool readParentheses;
  bool readLinks;
  bool readPageNumbers;

  SanitizerOptions({
    this.readParentheses = true,
    this.readLinks = true,
    this.readPageNumbers = true,
  });
}

class TextSanitizer {
  static const List<String> _czechTitles = [
    'Bc', 'BcA', 'Ing', 'Ing. arch', 'Mgr', 'MgA', 'PhD', 'ThD', 'RNDr', 'PhDr',
    'MUDr', 'MVDr', 'JUDr', 'PaedDr', 'PharmDr', 'ThDr', 'prof', 'doc', 'dr', 'dr. h. c'
  ];

  static const List<String> _englishTitles = [
    'BA', 'BSc', 'MA', 'MSc', 'MPhil', 'PhD', 'EdD', 'DPhil', 'LLM', 'MBA',
    'Dr', 'Prof', 'Assoc. Prof', 'Asst. Prof'
  ];

  static const List<String> _czechAbbreviations = [
    'atd', 'apod', 'napr', 'tzv', 'tj', 'viz', 'str', 'sv', 'st', 'kol', 'př. n. l', 'n. l', 'č'
  ];

  static const List<String> _englishAbbreviations = [
    'etc', 'eg', 'ie', 'ca', 'vs', 'vol', 'pp', 'ch', 'chap', 'fig', 'approx', 'ibid', 'et al', 'BC', 'AD'
  ];

  static String sanitizeText(String input, SanitizerOptions options) {
    if (input.isEmpty) return input;

    String text = input;
    text = _convertQuotes(text);
    text = _maskTitlesAndAbbreviations(text);
    text = _cleanAcademicArtifacts(text, options);
    text = _reconstructParagraphs(text);
    text = _unmaskTitlesAndAbbreviations(text);
    text = _handleSpecialSymbols(text);

    return text.replaceAll(RegExp(r' +'), ' ').trim();
  }

  static bool hasSentenceEnd(String word) {
    String clean = word.trim();
    if (clean.isEmpty) return false;
    if (clean.endsWith('___')) return false;
    return clean.endsWith('.') || clean.endsWith('?') || clean.endsWith('!');
  }

  static List<List<PdfWordGeometry>> splitIntoChunks(List<PdfWordGeometry> words) {
    List<List<PdfWordGeometry>> chunks = [];
    List<PdfWordGeometry> currentChunk = [];
    StringBuffer buffer = StringBuffer();

    for (var word in words) {
      currentChunk.add(word);
      buffer.write(buffer.isEmpty ? word.text : " ${word.text}");

      bool isEnd = hasSentenceEnd(word.text);
      if ((isEnd && buffer.length > 150) || buffer.length > 600) {
        chunks.add(List.from(currentChunk));
        currentChunk.clear();
        buffer.clear();
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }
    return chunks;
  }

  static Stream<double> parsePdfWithProgress({
    required Uint8List bytes,
    required List<PdfChunkMetadata> chunksTarget,
    required SanitizerOptions options,
    required Function onChunkReady,
  }) async* {
    chunksTarget.clear();
    final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
    final sf.PdfTextExtractor extractor = sf.PdfTextExtractor(document);
    final int pageCount = document.pages.count;

    double previousFontSize = 0.0;
    Rect previousBounds = Rect.zero;
    List<PdfWordGeometry> structuralBlockWords = [];

    void flushStructuralBlock(int pageNumber) {
      if (structuralBlockWords.isEmpty) return;
      final splittedChunks = splitIntoChunks(structuralBlockWords);
      for (final chunkWords in splittedChunks) {
        final rawText = chunkWords.map((w) => w.text).join(' ');
        final formattedText = sanitizeText(rawText, options);
        if (formattedText.isNotEmpty) {
          chunksTarget.add(PdfChunkMetadata(
            text: formattedText,
            pageNumber: pageNumber,
            pdfWords: chunkWords,
          ));
        }
      }
      structuralBlockWords.clear();
    }

    for (int pageIdx = 0; pageIdx < pageCount; pageIdx++) {
      final List<sf.TextLine> textLines = extractor.extractTextLines(startPageIndex: pageIdx, endPageIndex: pageIdx);
      StringBuffer reconstructedWordText = StringBuffer();
      Rect? reconstructedWordBounds;

      for (final sf.TextLine line in textLines) {
        if (line.wordCollection.isEmpty) continue;

        double currentFontSize = line.fontSize;
        Rect currentBounds = line.bounds;
        // Pass the first word of this line so digit-start heuristic can fire
        final String firstWord = line.wordCollection.isNotEmpty
            ? line.wordCollection.first.text.trim()
            : '';

        if (shouldStartNewBlock(
          currentFontSize: currentFontSize,
          previousFontSize: previousFontSize,
          currentBounds: currentBounds,
          previousBounds: previousBounds,
          currentLineFirstWord: firstWord,
        )) {
          flushStructuralBlock(pageIdx + 1);
        }

        previousFontSize = currentFontSize;
        previousBounds = currentBounds;

        for (final sf.TextWord word in line.wordCollection) {
          String part = word.text;
          if (reconstructedWordText.isEmpty) {
            reconstructedWordBounds = word.bounds;
          } else if (reconstructedWordBounds != null) {
            reconstructedWordBounds = reconstructedWordBounds.expandToInclude(word.bounds);
          }
          reconstructedWordText.write(part);
          if (part.endsWith(' ') || part == '\n' || part == '\r' || word == line.wordCollection.last) {
            String cleanWord = reconstructedWordText.toString().trim();
            reconstructedWordText.clear();
            if (cleanWord.isEmpty) continue;

            if (!options.readLinks) {
              if (cleanWord.contains(RegExp(r'https?://\S+|www\.\S+'))) continue;
            }
            if (!options.readPageNumbers) {
              if (RegExp(r'^\d+$').hasMatch(cleanWord)) continue;
            }

            if (reconstructedWordBounds != null) {
              structuralBlockWords.add(PdfWordGeometry(bounds: reconstructedWordBounds, text: cleanWord));
            }
          }
        }
      }
      flushStructuralBlock(pageIdx + 1);
      onChunkReady();
      yield (pageIdx + 1) / pageCount;
      await Future.delayed(const Duration(milliseconds: 1));
    }
    document.dispose();
  }

  static String _convertQuotes(String text) {
    return text
        .replaceAll('„', '"')
        .replaceAll('\u201C', '"')
        .replaceAll('\u2018', '"')
        .replaceAll('\u2019', '"')
        .replaceAll('"', '"');
  }

  static String _maskTitlesAndAbbreviations(String text) {
    for (var title in [..._czechTitles, ..._englishTitles]) {
      text = text.replaceAll(RegExp('\\b$title\\.'), '${title}___');
    }
    for (var abbr in [..._czechAbbreviations, ..._englishAbbreviations]) {
      text = text.replaceAll(RegExp('\\b$abbr\\.'), '${abbr}___');
    }
    text = text.replaceAll(RegExp(r'\b(?<=\d)\.\s+(=[a-zžščřžýáíéúůa-z])'), '___ ');
    return text;
  }

  static String _unmaskTitlesAndAbbreviations(String text) {
    for (var title in [..._czechTitles, ..._englishTitles]) {
      text = text.replaceAll('${title}___', '$title.');
    }
    for (var abbr in [..._czechAbbreviations, ..._englishAbbreviations]) {
      text = text.replaceAll('${abbr}___', '$abbr.');
    }
    text = text.replaceAll('___ ', '. ');
    return text;
  }

  static String _cleanAcademicArtifacts(String text, SanitizerOptions options) {
    if (!options.readParentheses) {
      text = text.replaceAll(RegExp(r'\(\s*[A-Za-zČŠŽÝÁÍÉÚŮčšžýáíéúů\s&]+,\s*\d{4}\s*\)'), '');
      text = text.replaceAll(RegExp(r'\[\s*\d+\s*\]'), '');
      text = text.replaceAll(RegExp(r'\([^)]*\)'), '');
    }
    text = text.replaceAll(RegExp(r'(?<=[a-zA-ZČŠŽÝÁÍÉÚŮčšžýáíéúů])\d+\b'), '');
    text = text.replaceAll(RegExp(r'^[•\-\*‣]\s*'), '');
    return text;
  }

  static String _reconstructParagraphs(String text) {
    text = text.replaceAll(RegExp(r'-\s*\n'), '');
    text = text.replaceAll(RegExp(r'(?<!\n)\n(?!\n)'), ' ');
    text = text.replaceAll(RegExp(r'\n{2,}'), ' <PARAGRAPH_PAUSE> ');
    return text;
  }

  static String _handleSpecialSymbols(String text) {
    return text
        .replaceAll('&', ' a ')
        .replaceAll('@', ' zavináč ')
        .replaceAll('/', ' lomítko ');
  }

  /// Returns true if [text] starts with a bullet or numbered-list marker.
  static bool isBulletLine(String text) {
    final t = text.trimLeft();
    if (t.startsWith('• ') || t.startsWith('- ') || t.startsWith('* ')) return true;
    if (RegExp(r'^\d+\.\s').hasMatch(t)) return true;
    return false;
  }

  static bool shouldStartNewBlock({
    required double currentFontSize,
    required double previousFontSize,
    Rect currentBounds = Rect.zero,
    Rect previousBounds = Rect.zero,
    String currentLineFirstWord = '',
  }) {
    // Different font size → always a new block (heading, caption, footnote, etc.)
    if (previousFontSize != 0.0 && (currentFontSize - previousFontSize).abs() > 0.1) {
      return true;
    }
    if (currentBounds != Rect.zero && previousBounds != Rect.zero) {
      final double verticalDistance = currentBounds.top - previousBounds.bottom;
      final double lineHeight = previousBounds.height;
      if (lineHeight > 0) {
        // 1.3× catches paragraph gaps only slightly larger than normal line spacing.
        // The original 1.7× was too conservative and missed many paragraph breaks.
        if (verticalDistance > lineHeight * 1.3) {
          return true;
        }
        // Paragraphs starting with a digit (numbered sections, "1. Úvod") may
        // have the same font size and only a modest gap — force a split at 0.9×.
        if (verticalDistance > lineHeight * 0.9 &&
            currentLineFirstWord.isNotEmpty &&
            RegExp(r'^\d').hasMatch(currentLineFirstWord)) {
          return true;
        }
      }
    }
    return false;
  }
}