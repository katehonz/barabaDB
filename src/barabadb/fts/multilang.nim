## Multi-Language FTS — tokenizers for different languages
import std/tables
import std/unicode
import std/strutils
import std/sets

type
  Language* = enum
    langEnglish = "en"
    langSpanish = "es"
    langFrench = "fr"
    langGerman = "de"
    langRussian = "ru"
    langBulgarian = "bg"
    langChinese = "zh"
    langJapanese = "ja"
    langArabic = "ar"
    langAuto = "auto"

  Stemmer* = proc(word: string): string {.gcsafe.}
  StopWords* = HashSet[string]

  LanguageConfig* = object
    language*: Language
    stemmer*: Stemmer
    stopWords*: StopWords
    tokenizer*: proc(text: string): seq[string] {.gcsafe.}

const
  stopWordsEn* = [
    "a", "an", "the", "is", "it", "in", "on", "at", "to", "for",
    "of", "with", "by", "from", "as", "into", "through", "during",
    "and", "or", "not", "but", "if", "then", "else", "when",
    "be", "was", "were", "been", "being", "have", "has", "had",
    "do", "does", "did", "will", "would", "could", "should", "may",
    "this", "that", "these", "those", "i", "you", "he", "she", "we", "they",
  ]

  stopWordsBg* = [
    "и", "в", "на", "за", "от", "да", "се", "е", "са", "по",
    "не", "че", "с", "към", "но", "или", "ако", "при", "до",
    "как", "какво", "кой", "коя", "кое", "кои", "този", "тази",
    "това", "тези", "със", "между", "след", "преди", "без",
    "още", "вече", "само", "може", "трябва", "има", "няма",
  ]

  stopWordsDe* = [
    "der", "die", "das", "ein", "eine", "und", "oder", "aber", "nicht",
    "ist", "sind", "war", "hat", "haben", "werden", "wird", "kann",
    "mit", "von", "für", "auf", "in", "an", "zu", "bei", "nach",
    "über", "unter", "vor", "zwischen", "durch", "gegen", "ohne",
  ]

  stopWordsFr* = [
    "le", "la", "les", "un", "une", "des", "et", "ou", "mais", "pas",
    "est", "sont", "était", "a", "ont", "sera", "peut", "avec",
    "de", "du", "pour", "sur", "dans", "par", "entre", "sous", "chez",
    "je", "tu", "il", "elle", "nous", "vous", "ils", "elles",
  ]

  stopWordsRu* = [
    "и", "в", "на", "не", "что", "он", "я", "с", "а", "как",
    "это", "по", "но", "они", "мы", "за", "от", "из", "у", "к",
    "бы", "ты", "его", "её", "их", "её", "мой", "твой", "наш",
    "ваш", "свой", "который", "этот", "тот", "такой", "каждый",
  ]

proc stemEnglish*(word: string): string =
  if word.len <= 3: return word
  if word.endsWith("ing"): return word[0..^4]
  if word.endsWith("tion"): return word[0..^5]
  if word.endsWith("ness"): return word[0..^5]
  if word.endsWith("ment"): return word[0..^5]
  if word.endsWith("able"): return word[0..^5]
  if word.endsWith("ies"): return word[0..^4] & "y"
  if word.endsWith("es") and word.len > 4: return word[0..^3]
  if word.endsWith("ed") and word.len > 4: return word[0..^3]
  if word.endsWith("ly") and word.len > 4: return word[0..^3]
  if word.endsWith("s") and not word.endsWith("ss") and word.len > 3: return word[0..^2]
  return word

proc stemBulgarian*(word: string): string =
  if word.len <= 3: return word
  # Bulgarian suffixes (all Cyrillic chars are 2 bytes)
  # 3 Cyrillic chars = 6 bytes -> ^7
  if word.endsWith("ища"): return word[0..^7]
  if word.endsWith("ище"): return word[0..^7]
  if word.endsWith("ция"): return word[0..^7]
  if word.endsWith("ние"): return word[0..^7]
  if word.endsWith("ост"): return word[0..^7]
  if word.endsWith("ски"): return word[0..^7]
  # 4 Cyrillic chars = 8 bytes -> ^9
  if word.endsWith("ство"): return word[0..^9]
  # 2 Cyrillic chars = 4 bytes -> ^5
  if word.endsWith("на"): return word[0..^5]
  if word.endsWith("та"): return word[0..^5]
  return word

proc stemGerman*(word: string): string =
  if word.len <= 3: return word
  if word.endsWith("ung"): return word[0..^4]
  if word.endsWith("heit"): return word[0..^5]
  if word.endsWith("keit"): return word[0..^5]
  if word.endsWith("lich"): return word[0..^5]
  if word.endsWith("isch"): return word[0..^5]
  if word.endsWith("chen"): return word[0..^5]
  if word.endsWith("schaft"): return word[0..^7]
  if word.endsWith("en"): return word[0..^3]
  if word.endsWith("er"): return word[0..^3]
  if word.endsWith("es"): return word[0..^3]
  return word

proc stemFrench*(word: string): string =
  if word.len <= 3: return word
  if word.endsWith("ement"): return word[0..^6]
  if word.endsWith("ment"): return word[0..^5]
  if word.endsWith("tion"): return word[0..^5]
  if word.endsWith("eur"): return word[0..^4]
  if word.endsWith("euse"): return word[0..^5]
  if word.endsWith("ique"): return word[0..^5]
  if word.endsWith("esse"): return word[0..^5]
  if word.endsWith("eux"): return word[0..^4]
  if word.endsWith("er"): return word[0..^3]
  if word.endsWith("es"): return word[0..^3]
  return word

proc stemRussian*(word: string): string =
  if word.len <= 3: return word
  # Russian suffixes (all Cyrillic chars are 2 bytes)
  # 4 Cyrillic chars = 8 bytes -> ^9
  if word.endsWith("ость"): return word[0..^9]
  if word.endsWith("ение"): return word[0..^9]
  if word.endsWith("ание"): return word[0..^9]
  if word.endsWith("тель"): return word[0..^9]
  if word.endsWith("ский"): return word[0..^9]
  # 3 Cyrillic chars = 6 bytes -> ^7
  if word.endsWith("ция"): return word[0..^7]
  if word.endsWith("ние"): return word[0..^7]
  if word.endsWith("ать"): return word[0..^7]
  if word.endsWith("ить"): return word[0..^7]
  if word.endsWith("ыть"): return word[0..^7]
  return word

proc getLanguageConfig*(lang: Language): LanguageConfig =
  case lang
  of langEnglish:
    LanguageConfig(language: lang, stemmer: stemEnglish,
                   stopWords: stopWordsEn.toHashSet())
  of langBulgarian:
    LanguageConfig(language: lang, stemmer: stemBulgarian,
                   stopWords: stopWordsBg.toHashSet())
  of langGerman:
    LanguageConfig(language: lang, stemmer: stemGerman,
                   stopWords: stopWordsDe.toHashSet())
  of langFrench:
    LanguageConfig(language: lang, stemmer: stemFrench,
                   stopWords: stopWordsFr.toHashSet())
  of langRussian:
    LanguageConfig(language: lang, stemmer: stemRussian,
                   stopWords: stopWordsRu.toHashSet())
  else:
    LanguageConfig(language: lang, stemmer: stemEnglish,
                   stopWords: stopWordsEn.toHashSet())

proc tokenize*(text: string, config: LanguageConfig): seq[string] =
  result = @[]
  var word = ""
  for ch in text:
    let cp = ord(ch)
    # Accept ASCII alphanumeric, Cyrillic, CJK, Arabic, and common separators
    if (cp >= 0x30 and cp <= 0x39) or  # digits
       (cp >= 0x41 and cp <= 0x5A) or  # A-Z
       (cp >= 0x61 and cp <= 0x7A) or  # a-z
       (cp >= 0xC0 and cp <= 0xFF) or  # Latin Extended + Cyrillic start
       (cp >= 0x400 and cp <= 0x4FF) or # Cyrillic
       ch == '_' or ch == '-':
      word &= ch
    else:
      if word.len > 0:
        var token = word.toLower()
        if config.stemmer != nil:
          token = config.stemmer(token)
        if token.len >= 2 and token notin config.stopWords:
          result.add(token)
        word = ""
  if word.len > 0:
    var token = word.toLower()
    if config.stemmer != nil:
      token = config.stemmer(token)
    if token.len >= 2 and token notin config.stopWords:
      result.add(token)

proc detectLanguage*(text: string): Language =
  # Simple heuristic based on byte patterns
  # UTF-8 Cyrillic: bytes 0xD0-0xD1 followed by 0x80-0xBF
  var cyrillicCount = 0
  var latinCount = 0
  var i = 0
  let bytes = cast[seq[byte]](text)
  while i < bytes.len:
    let b = bytes[i]
    if b >= 0xD0'u8 and b <= 0xD1'u8 and i + 1 < bytes.len and bytes[i+1] >= 0x80'u8:
      inc cyrillicCount
      i += 2
    elif b >= 0x41'u8 and b <= 0x7A'u8:
      inc latinCount
      i += 1
    else:
      i += 1

  if cyrillicCount > latinCount:
    return langRussian  # Could be BG or RU — default to RU
  return langEnglish
