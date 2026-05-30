import std/unicode
import std/strutils
import ../fts/multilang

type
  Stemmer2* = proc(word: string): string {.gcsafe.}

# --- English Porter2 ---

const englishVowels = {'a', 'e', 'i', 'o', 'u', 'y'}

proc isVowelEn(c: char): bool = c in englishVowels

proc findR1R2(word: string): (int, int) =
  var r1 = word.len
  var r2 = word.len
  for i in 1..<word.len:
    if not isVowelEn(word[i]) and isVowelEn(word[i - 1]):
      r1 = i + 1
      break
  if r1 < word.len:
    for i in (r1 + 1)..<word.len:
      if not isVowelEn(word[i]) and isVowelEn(word[i - 1]):
        r2 = i + 1
        break
  if word.len >= 5 and word.startsWith("gener"):
    r1 = 5
  elif word.len >= 6 and word.startsWith("commun"):
    r1 = 6
  elif word.len >= 5 and word.startsWith("arsen"):
    r1 = 5
  return (r1, r2)

proc containsVowelEn(s: string): bool =
  for c in s:
    if isVowelEn(c): return true
  return false

proc endsWithDouble(s: string): bool =
  if s.len < 2: return false
  let c = s[^1]
  if s[^2] != c: return false
  return c in {'b', 'd', 'f', 'g', 'm', 'n', 'p', 'r', 't'}

proc endsWithShortSyllable(s: string): bool =
  if s.len >= 3:
    let a = s[^3]
    let b = s[^2]
    let c = s[^1]
    if not isVowelEn(a) and isVowelEn(b) and not isVowelEn(c) and c != 'w' and c != 'x' and c != 'Y':
      return true
  if s.len == 2:
    if isVowelEn(s[0]) and not isVowelEn(s[1]):
      return true
  return false

proc isShortWord(s: string, r1: int): bool =
  endsWithShortSyllable(s) and r1 >= s.len

proc stemEnglish2*(word: string): string =
  if word.len <= 2: return word
  var w = word.toLower()

  if w[0] == '\'': w = w[1..^1]
  if w.len <= 2: return w

  # Set initial Y after vowel to Y
  var buf = ""
  buf.add(w[0])
  for i in 1..<w.len:
    if w[i] == 'y' and isVowelEn(w[i - 1]):
      buf.add('Y')
    else:
      buf.add(w[i])
  w = buf

  let (r1init, r2init) = findR1R2(w)
  var r1 = r1init
  var r2 = r2init

  # Step 0
  if w.endsWith("'s'"): w = w[0..^4]
  elif w.endsWith("'s"): w = w[0..^3]
  elif w.endsWith("'"): w = w[0..^2]

  # Step 1a
  if w.endsWith("sses"):
    w = w[0..^3]
  elif w.endsWith("ied") or w.endsWith("ies"):
    if w.len > 4:
      w = w[0..^3] & "i"
    else:
      w = w[0..^2] & "ie"
  elif w.endsWith("us") or w.endsWith("ss"):
    discard
  elif w.endsWith("s"):
    if w.len > 2 and containsVowelEn(w[0..^3]):
      w = w[0..^2]

  # Step 1b
  var step1bExtra = false
  if w.endsWith("eedly"):
    if w.len - 5 >= r1:
      w = w[0..^4] & "ee"
  elif w.endsWith("eed"):
    if w.len - 3 >= r1:
      w = w[0..^2] & "ee"
  else:
    var found = false
    let suffixes1b = ["ingly", "edly", "ing", "ed"]
    for suf in suffixes1b:
      if w.endsWith(suf):
        let stem = w[0..^(suf.len + 1)]
        if containsVowelEn(stem):
          w = stem
          found = true
        break
    if found:
      if w.endsWith("at") or w.endsWith("bl") or w.endsWith("iz"):
        w = w & "e"
      elif endsWithDouble(w):
        w = w[0..^2]
      elif isShortWord(w, r1):
        w = w & "e"
        step1bExtra = true

  # Step 1c
  if not step1bExtra and w.len > 2:
    let lastChar = w[^1]
    if (lastChar == 'y' or lastChar == 'Y') and not isVowelEn(w[^2]):
      w = w[0..^2] & "i"

  # Step 2
  let step2Pairs = [
    ("ational", "ate"), ("tional", "tion"), ("enci", "ence"),
    ("anci", "ance"), ("abli", "able"), ("entli", "ent"),
    ("ization", "ize"), ("izer", "ize"), ("ation", "ate"),
    ("ator", "ate"), ("alism", "al"), ("aliti", "al"),
    ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"),
    ("ousness", "ous"), ("iveness", "ive"), ("iviti", "ive"),
    ("biliti", "ble"), ("bli", "ble"), ("fulli", "ful"),
    ("lessli", "less"), ("logi", "log"),
  ]
  block step2:
    for (suf, repl) in step2Pairs:
      if w.endsWith(suf):
        if w.len - suf.len >= r1:
          w = w[0..^(suf.len + 1)] & repl
        break step2
    if w.endsWith("li"):
      if w.len >= 3 and w.len - 2 >= r1:
        let preceding = w[^3]
        if preceding in {'c', 'd', 'e', 'g', 'h', 'k', 'm', 'n', 'r', 't'}:
          w = w[0..^3]

  # Recompute R1/R2 after modifications
  let (r1b, r2b) = findR1R2(w)
  r1 = r1b
  r2 = r2b

  # Step 3
  let step3Pairs = [
    ("ational", "ate"), ("tional", "tion"), ("alize", "al"),
    ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"),
    ("ness", ""), ("ful", ""),
  ]
  block step3:
    for (suf, repl) in step3Pairs:
      if w.endsWith(suf):
        if w.len - suf.len >= r1:
          w = w[0..^(suf.len + 1)] & repl
        break step3
    if w.endsWith("ative"):
      if w.len - 5 >= r2:
        w = w[0..^6]

  let (r1c, r2c) = findR1R2(w)
  r1 = r1c
  r2 = r2c

  # Step 4
  let step4Suffixes = [
    "ement", "ance", "ence", "able", "ible", "ment",
    "ant", "ent", "ion", "ism", "ate", "iti",
    "ous", "ive", "ize", "al", "er", "ic",
  ]
  block step4:
    for suf in step4Suffixes:
      if w.endsWith(suf):
        if suf == "ion":
          if w.len - 3 >= r2 and w.len >= 4:
            let preceding = w[^(suf.len + 1)]
            if preceding == 's' or preceding == 't':
              w = w[0..^(suf.len + 1)]
        else:
          if w.len - suf.len >= r2:
            w = w[0..^(suf.len + 1)]
        break step4

  # Step 5
  let (r1d, r2d) = findR1R2(w)
  r1 = r1d
  r2 = r2d

  if w.endsWith("e"):
    if w.len - 1 >= r2:
      w = w[0..^2]
    elif w.len - 1 >= r1 and not endsWithShortSyllable(w[0..^2]):
      w = w[0..^2]
  elif w.endsWith("l"):
    if w.len >= 2 and w[^2] == 'l' and w.len - 1 >= r2:
      w = w[0..^2]

  # Restore any Y back to y
  result = ""
  for c in w:
    if c == 'Y': result.add('y')
    else: result.add(c)

# --- Bulgarian Porter2 ---

proc toRunes(s: string): seq[Rune] =
  result = @[]
  for r in s.runes:
    result.add(r)

proc `$`(runes: seq[Rune]): string =
  result = ""
  for r in runes:
    result.add(r)

proc endsWithRune(word: seq[Rune], suffix: seq[Rune]): bool =
  if suffix.len > word.len: return false
  let offset = word.len - suffix.len
  for i in 0..<suffix.len:
    if word[offset + i] != suffix[i]: return false
  return true

proc removeSuffixRune(word: seq[Rune], sufLen: int): seq[Rune] =
  if sufLen >= word.len: return @[]
  result = word[0..^(sufLen + 1)]

proc stemBulgarian2*(word: string): string =
  let w = word.toLower()
  var runes = toRunes(w)
  if runes.len <= 2: return w

  let verbEndings = [
    ("охме", 4), ("яхме", 4), ("ахте", 4), ("яхте", 4),
    ("ахме", 4),
    ("ах", 2), ("ях", 2),
    ("а", 1), ("я", 1), ("е", 1), ("и", 1), ("у", 1),
  ]

  let adjEndings = [
    ("ият", 3), ("ото", 3), ("ата", 3), ("ите", 3),
    ("ия", 2), ("ен", 2), ("на", 2), ("но", 2), ("ни", 2),
    ("то", 2), ("та", 2), ("те", 2),
  ]

  let nounSuffixes = [
    ("иям", 3), ("ием", 3), ("иях", 3),
    ("ами", 3), ("ями", 3),
    ("ом", 2), ("ем", 2), ("ах", 2),
    ("а", 1), ("я", 1), ("о", 1), ("и", 1), ("е", 1),
    ("у", 1), ("ю", 1), ("ъ", 1),
  ]

  let derivational = [
    ("ища", 3), ("ище", 3), ("ция", 3), ("ние", 3),
    ("ост", 3), ("ски", 3), ("ство", 4),
    ("ент", 3), ("ант", 3), ("ист", 3),
  ]

  for (suf, slen) in derivational:
    let sufRunes = toRunes(suf)
    if runes.endsWithRune(sufRunes) and runes.len > slen + 2:
      runes = removeSuffixRune(runes, slen)
      return $runes

  for (suf, slen) in adjEndings:
    let sufRunes = toRunes(suf)
    if runes.endsWithRune(sufRunes) and runes.len > slen + 2:
      runes = removeSuffixRune(runes, slen)
      return $runes

  for (suf, slen) in verbEndings:
    let sufRunes = toRunes(suf)
    if runes.endsWithRune(sufRunes) and runes.len > slen + 1:
      runes = removeSuffixRune(runes, slen)
      return $runes

  for (suf, slen) in nounSuffixes:
    let sufRunes = toRunes(suf)
    if runes.endsWithRune(sufRunes) and runes.len > slen + 1:
      runes = removeSuffixRune(runes, slen)
      return $runes

  result = $runes

# --- German Porter2 ---

const germanVowels = {'a', 'e', 'i', 'o', 'u', 'y'}

proc isVowelDe(c: char): bool = c in germanVowels

proc findR1R2De(word: string): (int, int) =
  var r1 = word.len
  var r2 = word.len
  for i in 1..<word.len:
    if not isVowelDe(word[i]) and isVowelDe(word[i - 1]):
      r1 = i + 1
      break
  if r1 < 3: r1 = 3
  if r1 < word.len:
    for i in (r1 + 1)..<word.len:
      if not isVowelDe(word[i]) and isVowelDe(word[i - 1]):
        r2 = i + 1
        break
  return (r1, r2)

proc isValidSEnding(c: char): bool =
  c in {'b', 'd', 'f', 'g', 'h', 'k', 'l', 'm', 'n', 'r', 't'}

proc isValidStEnding(c: char): bool =
  c in {'b', 'd', 'f', 'g', 'h', 'k', 'l', 'm', 'n', 'r', 't'}

proc stemGerman2*(word: string): string =
  if word.len <= 2: return word
  var w = word.toLower()

  # Normalize umlauts
  var buf = ""
  for r in w.runes:
    case r
    of Rune(0x00E4): buf.add('a')   # ä
    of Rune(0x00F6): buf.add('o')   # ö
    of Rune(0x00FC): buf.add('u')   # ü
    of Rune(0x00DF): buf.add("ss")  # ß
    else: buf.add(r)
  w = buf

  # Replace U after vowel with u, Y after vowel with y
  var buf2 = ""
  buf2.add(w[0])
  for i in 1..<w.len:
    if w[i] == 'u' and isVowelDe(w[i - 1]):
      buf2.add('U')
    elif w[i] == 'y' and isVowelDe(w[i - 1]):
      buf2.add('Y')
    else:
      buf2.add(w[i])
  w = buf2

  let (r1init, r2init) = findR1R2De(w)
  var r1 = r1init
  var r2 = r2init

  # Step 1
  if w.endsWith("ern") and w.len - 3 >= r1:
    w = w[0..^4]
  elif w.endsWith("em") and w.len - 2 >= r1:
    w = w[0..^3]
  elif w.endsWith("er") and w.len - 2 >= r1:
    w = w[0..^3]
  elif w.endsWith("e") and w.len - 1 >= r1:
    w = w[0..^2]
  elif w.endsWith("en") and w.len - 2 >= r1:
    w = w[0..^3]
  elif w.endsWith("es") and w.len - 2 >= r1:
    w = w[0..^3]
  elif w.endsWith("s"):
    if w.len >= 3 and w.len - 1 >= r1 and isValidSEnding(w[^2]):
      w = w[0..^2]

  let (r1b, r2b) = findR1R2De(w)
  r1 = r1b
  r2 = r2b

  # Step 2
  if w.endsWith("est") and w.len - 3 >= r1:
    w = w[0..^4]
  elif w.endsWith("en") and w.len - 2 >= r1:
    w = w[0..^3]
  elif w.endsWith("er") and w.len - 2 >= r1:
    w = w[0..^3]
  elif w.endsWith("st"):
    if w.len >= 4 and w.len - 2 >= r1 and isValidStEnding(w[^3]):
      w = w[0..^3]

  let (r1c, r2c) = findR1R2De(w)
  r1 = r1c
  r2 = r2c

  # Step 3
  block step3:
    if w.endsWith("keit") and w.len - 4 >= r2:
      w = w[0..^5]
      break step3
    if w.endsWith("heit") and w.len - 4 >= r2:
      w = w[0..^5]
      break step3
    if w.endsWith("lich") and w.len - 4 >= r2:
      w = w[0..^5]
      break step3
    if w.endsWith("isch") and w.len - 4 >= r2:
      w = w[0..^5]
      break step3
    if w.endsWith("ung") and w.len - 3 >= r2:
      w = w[0..^4]
      break step3
    if w.endsWith("end") and w.len - 3 >= r2:
      w = w[0..^4]
      break step3
    if w.endsWith("ig") and w.len - 2 >= r2:
      w = w[0..^3]
      break step3
    if w.endsWith("ik") and w.len - 2 >= r2:
      w = w[0..^3]
      break step3

  # Restore U/Y
  result = ""
  for c in w:
    if c == 'U': result.add('u')
    elif c == 'Y': result.add('y')
    else: result.add(c)

# --- French Porter2 ---

const frenchVowels = {'a', 'e', 'i', 'o', 'u', 'y'}

proc isVowelFr(c: char): bool = c in frenchVowels

proc findR1R2Fr(word: string): (int, int) =
  var r1 = word.len
  var r2 = word.len
  for i in 1..<word.len:
    if not isVowelFr(word[i]) and isVowelFr(word[i - 1]):
      r1 = i + 1
      break
  if r1 < word.len:
    for i in (r1 + 1)..<word.len:
      if not isVowelFr(word[i]) and isVowelFr(word[i - 1]):
        r2 = i + 1
        break
  return (r1, r2)

proc containsVowelFr(s: string): bool =
  for c in s:
    if isVowelFr(c): return true
  return false

proc stemFrench2*(word: string): string =
  if word.len <= 2: return word
  var w = word.toLower()

  # Normalize accented characters to base + track positions
  var buf = ""
  for r in w.runes:
    case r
    of Rune(0x00E9), Rune(0x00E8), Rune(0x00EA), Rune(0x00EB):
      buf.add('e')
    of Rune(0x00E0), Rune(0x00E2):
      buf.add('a')
    of Rune(0x00F9), Rune(0x00FB):
      buf.add('u')
    of Rune(0x00EE), Rune(0x00EF):
      buf.add('i')
    of Rune(0x00F4):
      buf.add('o')
    of Rune(0x00E7):
      buf.add('c')
    of Rune(0x00E6):
      buf.add("ae")
    of Rune(0x0153):
      buf.add("oe")
    else:
      buf.add(r)
  w = buf

  let (r1init, r2init) = findR1R2Fr(w)
  var r1 = r1init
  var r2 = r2init

  # Step 1: Remove standard suffixes
  block step1:
    # -issement / -issant
    if w.endsWith("issement"):
      if w.len - 8 >= r1 and containsVowelFr(w[0..^(8 + 1)]):
        w = w[0..^9]
      break step1
    if w.endsWith("issant"):
      if w.len - 6 >= r1 and containsVowelFr(w[0..^(6 + 1)]):
        w = w[0..^7]
      break step1

    # -ation / -ateur / -ateurs
    if w.endsWith("ateurs") and w.len - 6 >= r2:
      w = w[0..^7]
      break step1
    if w.endsWith("ateur") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("ations") and w.len - 6 >= r2:
      w = w[0..^7]
      break step1
    if w.endsWith("ation") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1

    # -ement / -ements
    if w.endsWith("ements") and w.len - 6 >= r1:
      w = w[0..^7]
      break step1
    if w.endsWith("ement") and w.len - 5 >= r1:
      w = w[0..^6]
      break step1

    # -ment
    if w.endsWith("ment") and w.len - 4 >= r1:
      let stem = w[0..^(4 + 1)]
      if stem.len > 0 and isVowelFr(stem[^1]):
        w = stem
      break step1

    # -ité / -ités
    if w.endsWith("ites") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1
    if w.endsWith("ite") and w.len - 3 >= r2:
      w = w[0..^4]
      break step1

    # -ible / -ibles
    if w.endsWith("ibles") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("ible") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1

    # -iste / -isme
    if w.endsWith("istes") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("iste") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1
    if w.endsWith("ismes") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("isme") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1

    # -eux
    if w.endsWith("eux") and w.len - 3 >= r1:
      w = w[0..^4]
      break step1

    # -if / -ive / -ifs / -ives
    if w.endsWith("ives") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1
    if w.endsWith("ive") and w.len - 3 >= r2:
      w = w[0..^4]
      break step1
    if w.endsWith("ifs") and w.len - 3 >= r2:
      w = w[0..^4]
      break step1
    if w.endsWith("if") and w.len - 2 >= r2:
      w = w[0..^3]
      break step1

    # -ance / -ence
    if w.endsWith("ances") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("ance") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1
    if w.endsWith("ences") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("ence") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1

    # -eur / -euse
    if w.endsWith("euses") and w.len - 5 >= r2:
      w = w[0..^6]
      break step1
    if w.endsWith("euse") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1
    if w.endsWith("eurs") and w.len - 4 >= r2:
      w = w[0..^5]
      break step1
    if w.endsWith("eur") and w.len - 3 >= r2:
      w = w[0..^4]
      break step1

    # -er / -ier
    if w.endsWith("iers") and w.len - 4 >= r1:
      w = w[0..^5]
      break step1
    if w.endsWith("ier") and w.len - 3 >= r1:
      w = w[0..^4]
      break step1
    if w.endsWith("er") and w.len - 2 >= r1:
      w = w[0..^3]
      break step1

    # -es / -e / -s
    if w.endsWith("es") and w.len - 2 >= r1:
      w = w[0..^3]
      break step1
    if w.endsWith("e") and w.len - 1 >= r1:
      w = w[0..^2]
      break step1

  let (r1b, r2b) = findR1R2Fr(w)
  r1 = r1b
  r2 = r2b

  # Step 2a: Residual suffix cleanup
  if w.endsWith("ier"):
    w = w[0..^3] & "i"
  elif w.endsWith("i"):
    discard

  result = w

# --- Russian Porter2 ---

const
  ruVowelCodes = [
    Rune(0x0430),  # а
    Rune(0x0435),  # е
    Rune(0x0438),  # и
    Rune(0x043E),  # о
    Rune(0x0443),  # у
    Rune(0x044B),  # ы
    Rune(0x044D),  # э
    Rune(0x044E),  # ю
    Rune(0x044F),  # я
  ]

proc isVowelRu(r: Rune): bool =
  for v in ruVowelCodes:
    if r == v: return true
  return false

proc findR1R2Ru(runes: seq[Rune]): (int, int) =
  var r1 = runes.len
  var r2 = runes.len
  for i in 1..<runes.len:
    if not isVowelRu(runes[i]) and isVowelRu(runes[i - 1]):
      r1 = i + 1
      break
  if r1 < runes.len:
    for i in (r1 + 1)..<runes.len:
      if not isVowelRu(runes[i]) and isVowelRu(runes[i - 1]):
        r2 = i + 1
        break
  return (r1, r2)

proc ruEndsWith(word: seq[Rune], suffix: string): bool =
  let sufRunes = toRunes(suffix)
  if sufRunes.len > word.len: return false
  let offset = word.len - sufRunes.len
  for i in 0..<sufRunes.len:
    if word[offset + i] != sufRunes[i]: return false
  return true

proc ruRemove(word: seq[Rune], sufLen: int): seq[Rune] =
  if sufLen >= word.len: return @[]
  result = word[0..^(sufLen + 1)]

proc stemRussian2*(word: string): string =
  let w = word.toLower()
  var runes = toRunes(w)
  if runes.len <= 2: return w

  let (r1init, r2init) = findR1R2Ru(runes)
  var r1 = r1init
  var r2 = r2init

  # PERFECTIVE GERUND group 1 (requires а/я before): -в, -вши, -вшись
  # PERFECTIVE GERUND group 2 (no requirement): -ив, -ивши, -ившись, -ыв, -ывши, -ывшись
  let perfG2 = ["ившись", "ывшись", "ивши", "ывши", "ив", "ыв"]
  let perfG1 = ["вшись", "вши", "в"]

  block perfGerund:
    for suf in perfG2:
      let sufRunes = toRunes(suf)
      if runes.ruEndsWith(suf):
        let pos = runes.len - sufRunes.len
        if pos >= r1:
          runes = ruRemove(runes, sufRunes.len)
          break perfGerund

    for suf in perfG1:
      let sufRunes = toRunes(suf)
      if runes.ruEndsWith(suf):
        let pos = runes.len - sufRunes.len
        if pos >= r1 and pos > 0:
          let prevRune = runes[pos - 1]
          if prevRune == Rune(0x0430) or prevRune == Rune(0x044F):  # а or я
            runes = ruRemove(runes, sufRunes.len)
            break perfGerund

  # REFLEXIVE: -ся, -сь
  block reflexive:
    for suf in ["ся", "сь"]:
      let sufRunes = toRunes(suf)
      if runes.ruEndsWith(suf):
        runes = ruRemove(runes, sufRunes.len)
        break reflexive

  # ADJECTIVE endings (try longest first)
  let adjEndings = [
    "ими", "ыми", "его", "ого", "ему", "ому",
    "их", "ых", "ую", "юю", "ая", "яя",
    "ое", "ее", "ие", "ые",
  ]

  var foundAdj = false
  block adjBlock:
    for suf in adjEndings:
      let sufRunes = toRunes(suf)
      if runes.ruEndsWith(suf):
        let pos = runes.len - sufRunes.len
        if pos >= r1:
          runes = ruRemove(runes, sufRunes.len)
          foundAdj = true
          break adjBlock

  # PARTICIPLE endings (if adjective was found, also remove participle)
  if foundAdj:
    let partG2 = ["ивш", "ывш", "ующ", "ющ"]
    let partG1 = ["вш", "ем", "нн", "т", "ш"]
    block participle:
      for suf in partG2:
        let sufRunes = toRunes(suf)
        if runes.ruEndsWith(suf):
          let pos = runes.len - sufRunes.len
          if pos >= r1:
            runes = ruRemove(runes, sufRunes.len)
            break participle
      for suf in partG1:
        let sufRunes = toRunes(suf)
        if runes.ruEndsWith(suf):
          let pos = runes.len - sufRunes.len
          if pos >= r1 and pos > 0:
            let prevRune = runes[pos - 1]
            if prevRune == Rune(0x0430) or prevRune == Rune(0x044F):
              runes = ruRemove(runes, sufRunes.len)
              break participle
  else:
    # VERB endings
    let verbG2 = ["ить", "ыть", "ить"]
    let verbG1 = ["ала", "яла", "ана", "ена", "ите", "или", "ыли",
                  "ует", "уют", "ит", "ыт", "ат", "ят", "ут",
                  "ила", "ыла", "ат", "ят", "ан", "ен",
                  "ай", "ей", "уй", "ла", "на", "ли",
                  "ем", "ло", "но", "ет", "ют",
                  "а", "я", "и", "у", "ю", "ь"]

    block verbBlock:
      for suf in verbG2:
        let sufRunes = toRunes(suf)
        if runes.ruEndsWith(suf):
          let pos = runes.len - sufRunes.len
          if pos >= r1:
            runes = ruRemove(runes, sufRunes.len)
            break verbBlock
      for suf in verbG1:
        let sufRunes = toRunes(suf)
        if runes.ruEndsWith(suf):
          let pos = runes.len - sufRunes.len
          if pos >= r1 and pos > 0:
            let prevRune = runes[pos - 1]
            if prevRune == Rune(0x0430) or prevRune == Rune(0x044F):
              runes = ruRemove(runes, sufRunes.len)
              break verbBlock

      # NOUN endings (only if no verb matched)
      let nounEndings = [
        "иям", "ием", "иях", "ами", "ями",
        "ия", "ие", "ий", "ом", "ем", "ах",
        "а", "я", "о", "и", "е", "у", "ю", "ы", "ь",
      ]
      block nounBlock:
        for suf in nounEndings:
          let sufRunes = toRunes(suf)
          if runes.ruEndsWith(suf):
            let pos = runes.len - sufRunes.len
            if pos >= r1:
              runes = ruRemove(runes, sufRunes.len)
              break nounBlock

  # Remove superlative suffixes: -ейш, -ейше
  block superlative:
    for suf in ["ейше", "ейш"]:
      let sufRunes = toRunes(suf)
      if runes.ruEndsWith(suf):
        let pos = runes.len - sufRunes.len
        if pos >= r1:
          runes = ruRemove(runes, sufRunes.len)
          break superlative

  # Remove derivational suffixes: -ост, -ость
  block derivational:
    for suf in ["ость", "ост"]:
      let sufRunes = toRunes(suf)
      if runes.ruEndsWith(suf):
        let pos = runes.len - sufRunes.len
        if pos >= r2:
          runes = ruRemove(runes, sufRunes.len)
          break derivational

  # Remove trailing нн -> н
  if runes.len >= 2:
    if runes[^1] == Rune(0x043D) and runes[^2] == Rune(0x043D):  # нн
      runes = runes[0..^2]

  result = $runes

# --- Unified interface ---

proc getStemmer2*(lang: Language): Stemmer2 =
  case lang
  of langEnglish: return stemEnglish2
  of langBulgarian: return stemBulgarian2
  of langGerman: return stemGerman2
  of langFrench: return stemFrench2
  of langRussian: return stemRussian2
  else: return stemEnglish2
