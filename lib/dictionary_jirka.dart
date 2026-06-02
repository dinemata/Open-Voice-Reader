// TTS pronunciation dictionary for model: cs_jirka (Piper Czech)
// Format: each entry is a RegExp pattern → replacement string.
// Patterns are applied in order by sanitizeText via _applyModelDictionary().
// To add words: add a new MapEntry below.
// The key is a Dart RegExp string (no surrounding slashes).
// Use \\b for word boundaries. Use (?i) flag via caseSensitive: false.

class DictionaryJirka {
  /// Returns a list of (pattern, replacement) pairs applied at TTS speak-time.
  static List<(RegExp, String)> get entries => _entries;

  static final List<(RegExp, String)> _entries = [
    // ── Numbered list items ──────────────────────────────────────────────
    (RegExp(r'\b1\.\s'), 'zaprvé '),
    (RegExp(r'\b2\.\s'), 'zadruhé '),
    (RegExp(r'\b3\.\s'), 'zatřetí '),
    (RegExp(r'\b4\.\s'), 'začtvrté '),
    (RegExp(r'\b5\.\s'), 'zapáté '),

    // ── Czech abbreviations ───────────────────────────────────────────────
    (RegExp(r'\bnapr\.\s', caseSensitive: false), 'například '),
    (RegExp(r'\bnapř\.\s', caseSensitive: false), 'například '),
    (RegExp(r'\btzv\.\s', caseSensitive: false), 'takzvaný '),
    (RegExp(r'\btj\.\s', caseSensitive: false), 'to jest '),
    (RegExp(r'\batd\.\s', caseSensitive: false), 'a tak dále '),
    (RegExp(r'\bapod\.\s', caseSensitive: false), 'a podobně '),
    (RegExp(r'\btzv\.\s', caseSensitive: false), 'takzvaně '),
    (RegExp(r'\bstr\.\s', caseSensitive: false), 'strana '),
    (RegExp(r'\bkap\.\s', caseSensitive: false), 'kapitola '),
    (RegExp(r'\bdr\.\s', caseSensitive: false), 'doktor '),
    (RegExp(r'\bprof\.\s', caseSensitive: false), 'profesor '),
    (RegExp(r'\bing\.\s', caseSensitive: false), 'inženýr '),
    (RegExp(r'\bmgr\.\s', caseSensitive: false), 'magistr '),
    (RegExp(r'\bbc\.\s', caseSensitive: false), 'bakalář '),
    (RegExp(r'\bphd\.\s', caseSensitive: false), 'doktor věd '),
    (RegExp(r'\bmudr\.\s', caseSensitive: false), 'doktor medicíny '),

    // ── English abbreviations (for mixed-language texts) ─────────────────
    (RegExp(r'\beg\.\s', caseSensitive: false), 'například '),
    (RegExp(r'\bie\.\s', caseSensitive: false), 'to jest '),
    (RegExp(r'\betc\.\s', caseSensitive: false), 'a tak dále '),
    (RegExp(r'\bvs\.\s', caseSensitive: false), 'versus '),
    (RegExp(r'\bviz\.\s', caseSensitive: false), 'viz '),

    // ── Tech / design vocabulary ──────────────────────────────────────────
    (RegExp(r'\bdesign\b', caseSensitive: false), 'dyzajn'),
    (RegExp(r'\bdesigner\b', caseSensitive: false), 'dyzajnér'),
    (RegExp(r'\bdesigners\b', caseSensitive: false), 'dyzajnéři'),
    (RegExp(r'\bdesigning\b', caseSensitive: false), 'dyzajnování'),
    (RegExp(r'\bdesigns\b', caseSensitive: false), 'dyzajny'),
    (RegExp(r'\bdesigned\b', caseSensitive: false), 'dyzajnované'),
    (RegExp(r'\bui\b'), 'jůáj'),
    (RegExp(r'\bux\b'), 'jůeks'),
    (RegExp(r'\bcss\b', caseSensitive: false), 'sísíes'),
    (RegExp(r'\bhtml\b', caseSensitive: false), 'héčtéémél'),
    (RegExp(r'\bjson\b', caseSensitive: false), 'džejson'),
    (RegExp(r'\bapi\b'), 'éjpíáj'),
    (RegExp(r'\bgpt\b', caseSensitive: false), 'džípítí'),

    // ── Numbers with units ────────────────────────────────────────────────
    (RegExp(r'(\d+)\s*%'), r'\1 procent'),
    (RegExp(r'(\d+)\s*°C'), r'\1 stupňů Celsia'),
    (RegExp(r'(\d+)\s*km/h'), r'\1 kilometrů za hodinu'),
    (RegExp(r'(\d+)\s*m/s'), r'\1 metrů za sekundu'),

    // ── Punctuation pauses: bullet-point sentences ────────────────────────
    // A sentence starting with a dash/bullet that is NOT mid-sentence
    // gets a short pause marker inserted (will be handled by chunk splitting).
    // Note: actual pause is added via sentence splitting in text_sanitizer.
  ];

  /// Apply all dictionary entries to [text].
  static String apply(String text) {
    for (final (pattern, replacement) in _entries) {
      text = text.replaceAllMapped(pattern, (m) {
        // Preserve backreferences (\1 etc.)
        String r = replacement;
        for (int i = 1; i <= m.groupCount; i++) {
          r = r.replaceAll('\\$i', m.group(i) ?? '');
        }
        return r;
      });
    }
    return text;
  }
}