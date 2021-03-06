import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

public struct FileCheckOptions: OptionSet {
  public let rawValue: UInt64

  /// Convert from a value of `RawValue`, succeeding unconditionally.
  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  /// Do not treat all horizontal whitespace as equivalent.
  public static let strictWhitespace = FileCheckOptions(rawValue: 1 << 0)
  /// Allow the input file to be empty. This is useful when making checks that
  /// some error message does not occur, for example.
  public static let allowEmptyInput = FileCheckOptions(rawValue: 1 << 1)
  /// Require all positive matches to cover an entire input line.  Allows
  /// leading and trailing whitespace if `.strictWhitespace` is not also
  /// passed.
  public static let matchFullLines = FileCheckOptions(rawValue: 1 << 2)
  /// Disable colored diagnostics.
  public static let disableColors = FileCheckOptions(rawValue: 1 << 3)
}

/// `FileCheckFD` represents the standard output streams `FileCheck` is capable
/// of overriding to gather output.
public enum FileCheckFD {
  /// Standard output.
  case stdout
  /// Standard error.
  case stderr
  /// A custom output stream.
  case custom(fileno: Int32, ptr: UnsafeMutablePointer<FILE>)

  /// Retrieve the file descriptor for this output stream.
  var fileno : Int32 {
    switch self {
    case .stdout:
      return STDOUT_FILENO
    case .stderr:
      return STDERR_FILENO
    case let .custom(fileno: fd, ptr: _):
      return fd
    }
  }

  /// Retrieve the FILE pointer for this stream.
  var filePtr : UnsafeMutablePointer<FILE>! {
    switch self {
    case .stdout:
      #if os(Linux)
        return Glibc.stdout
      #else
        return Darwin.stdout
      #endif
    case .stderr:
      #if os(Linux)
        return Glibc.stderr
      #else
        return Darwin.stderr
      #endif
    case let .custom(fileno: _, ptr: ptr):
      return ptr
    }
  }
}

/// Reads from the given output stream and runs a file verification procedure
/// by comparing the output to a specified result.
///
/// FileCheck requires total access to whatever input stream is being used.  As
/// such it will override printing to said stream until the given block has
/// finished executing.
///
/// - parameter FD: The file descriptor to override and read from.
/// - parameter prefixes: Specifies one or more prefixes to match. By default
///   these patterns are prefixed with "CHECK".
/// - parameter checkNot: Specifies zero or more prefixes to implicitly reject
///   in the output stream.  This can be used to implement LLVM-verifier-like 
///   checks.
/// - parameter file: The file to check against.  Defaults to the file that
///   contains the call to `fileCheckOutput`.
/// - parameter options: Optional arguments to modify the behavior of the check.
/// - parameter block: The block in which output will be emitted to the given
///   file descriptor.
///
/// - returns: Whether or not FileCheck succeeded in verifying the file.
public func fileCheckOutput(of FD : FileCheckFD = .stdout, withPrefixes prefixes : [String] = ["CHECK"], checkNot : [String] = [], against file : String = #file, options: FileCheckOptions = [], block : () -> ()) -> Bool {
  guard let validPrefixes = validateCheckPrefixes(prefixes) else {
    print("Supplied check-prefix is invalid! Prefixes must be unique and ",
          "start with a letter and contain only alphanumeric characters, ",
          "hyphens and underscores")
    return false
  }
  guard let prefixRE = try? NSRegularExpression(pattern: validPrefixes.joined(separator: "|"), options: []) else {
    print("Unable to combine check-prefix strings into a prefix regular ",
          "expression! This is likely a bug in FileCheck's verification of ",
          "the check-prefix strings. Regular expression parsing failed.")
    return false
  }

  let input = overrideFDAndCollectOutput(file: FD, of: block)
  if (input.isEmpty && !options.contains(.allowEmptyInput)) {
    print("FileCheck error: input from file descriptor \(FD) is empty.\n")
    return false
  }

  guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
    return false
  }
  let buf = contents.cString(using: .utf8)?.withUnsafeBufferPointer { buffer in
    return readCheckStrings(in: buffer, withPrefixes: validPrefixes, checkNot: checkNot, options: options, prefixRE)
  }
  guard let checkStrings = buf else {
    return false
  }
  return check(input: input, against: checkStrings, options: options)
}

private func overrideFDAndCollectOutput(file : FileCheckFD, of block : () -> ()) -> String {
  fflush(file.filePtr)
  let oldFd = dup(file.fileno)

  let template = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("output.XXXXXX")
  return template.withUnsafeFileSystemRepresentation { buffer in
    guard let buffer = buffer else {
      return ""
    }

   	let newFd = mkstemp(UnsafeMutablePointer(mutating: buffer))
    guard newFd != -1 else {
      return ""
    }

    dup2(newFd, file.fileno)

    block()

    close(newFd)
    fflush(file.filePtr)


    dup2(oldFd, file.fileno)
    close(oldFd)

    let url = URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: false, relativeTo: nil)
    guard let s = try? String(contentsOf: url, encoding: .utf8) else {
      return ""
    }
    return s
  }
}

func validateCheckPrefixes(_ prefixes : [String]) -> [String]? {
  let validator = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]*$", options: [])

  for prefix in prefixes {
    // Reject empty prefixes.
    if prefix.isEmpty {
      return nil
    }

    let range = NSRange(
      location: 0,
      length: prefix.distance(from: prefix.startIndex, to: prefix.endIndex)
    )
    if validator.matches(in: prefix, options: [], range: range).isEmpty {
      return nil
    }
  }

  return [String](Set<String>(prefixes))
}

extension CChar {
  fileprivate var isPartOfWord : Bool {
    return isalnum(Int32(self)) != 0 || self == ("-" as Character).utf8CodePoint || self == ("_" as Character).utf8CodePoint
  }
}

extension Character {
  var utf8CodePoint : CChar {
    return String(self).cString(using: .utf8)!.first!
  }

  fileprivate var isPartOfWord : Bool {
    let utf8Value = self.utf8CodePoint
    return isalnum(Int32(utf8Value)) != 0 || self == "-" || self == "_"
  }
}

private func findCheckType(in buf : UnsafeBufferPointer<CChar>, with prefix : String) -> CheckType {
  let nextChar = buf[prefix.utf8.count]

  // Verify that the : is present after the prefix.
  if nextChar == (":" as Character).utf8CodePoint {
    return .plain
  }
  if nextChar != ("-" as Character).utf8CodePoint {
    return .none
  }

  let rest = String(
    bytesNoCopy: UnsafeMutableRawPointer(
      mutating: buf.baseAddress!.advanced(by: prefix.utf8.count + 1)
    ),
    length: buf.count - (prefix.utf8.count + 1),
    encoding: .utf8,
    freeWhenDone: false
  )!
  if rest.hasPrefix("NEXT:") {
    return .next
  }

  if rest.hasPrefix("SAME:") {
    return .same
  }

  if rest.hasPrefix("NOT:") {
    return .not
  }

  if rest.hasPrefix("DAG:") {
    return .dag
  }

  if rest.hasPrefix("LABEL:") {
    return .label
  }

  // You can't combine -NOT with another suffix.
  let badNotPrefixes = [
    "DAG-NOT:",
    "NOT-DAG:",
    "NEXT-NOT:",
    "NOT-NEXT:",
    "SAME-NOT:",
    "NOT-SAME:",
  ]
  if badNotPrefixes.reduce(false, { (acc, s) in acc || rest.hasPrefix(s) }) {
    return .badNot
  }

  return .none
}

extension UnsafeBufferPointer {
  fileprivate func substr(_ start : Int, _ size : Int) -> UnsafeBufferPointer<Element> {
    return UnsafeBufferPointer<Element>(start: self.baseAddress!.advanced(by: start), count: size)
  }

  fileprivate func dropFront(_ n : Int) -> UnsafeBufferPointer<Element> {
    precondition(n < self.count)
    return UnsafeBufferPointer<Element>(start: self.baseAddress!.advanced(by: n), count: self.count - n)
  }
}

func substring(in buffer : UnsafeBufferPointer<CChar>, with range : NSRange) -> String {
  precondition(range.location + range.length <= buffer.count)
  let ptr = buffer.substr(range.location, range.length)
  return String(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), length: range.length, encoding: .utf8, freeWhenDone: false)!
}

private func findFirstMatch(in inbuffer : UnsafeBufferPointer<CChar>, among prefixes : [String], with RE : NSRegularExpression, startingAt startLine: Int) -> (String, CheckType, Int, UnsafeBufferPointer<CChar>) {
  var lineNumber = startLine
  var buffer = inbuffer

  while !buffer.isEmpty {
    let str = String(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), length: buffer.count, encoding: .utf8, freeWhenDone: false)!
    let match = RE.firstMatch(in: str, options: [], range: NSRange(location: 0, length: str.distance(from: str.startIndex, to: str.endIndex)))
    guard let prefix = match else {
      return ("", .none, lineNumber, buffer)
    }
    let skippedPrefix = substring(in: buffer, with: NSMakeRange(0, prefix.range.location))
    let prefixStr = str.substring(
      with: Range(
        uncheckedBounds: (
          str.index(str.startIndex, offsetBy: prefix.range.location),
          str.index(str.startIndex, offsetBy: NSMaxRange(prefix.range))
        )
      )
    )

    // HACK: Conversion between the buffer and `String` causes index
    // mismatches when searching for strings.  We're instead going to do
    // something terribly inefficient here: Use the regular expression to
    // look for check prefixes, then use Foundation's Data to find their
    // actual locations in the buffer.
    let bd = Data(buffer: buffer)
    let range = bd.range(of: prefixStr.data(using: .utf8)!)!
    buffer = buffer.dropFront(range.lowerBound)
    lineNumber += skippedPrefix.characters.filter({ c in c == "\n" }).count
    // Check that the matched prefix isn't a suffix of some other check-like
    // word.
    // FIXME: This is a very ad-hoc check. it would be better handled in some
    // other way. Among other things it seems hard to distinguish between
    // intentional and unintentional uses of this feature.
    if skippedPrefix.isEmpty || !skippedPrefix.characters.last!.isPartOfWord {
      // Now extract the type.
      let checkTy = findCheckType(in: buffer, with: prefixStr)


      // If we've found a valid check type for this prefix, we're done.
      if checkTy != .none {
        return (prefixStr, checkTy, lineNumber, buffer)
      }
    }
    // If we didn't successfully find a prefix, we need to skip this invalid
    // prefix and continue scanning. We directly skip the prefix that was
    // matched and any additional parts of that check-like word.
    // From the given position, find the next character after the word.
    var loc = prefix.range.length
    while loc < buffer.count && buffer[loc].isPartOfWord {
      loc += 1
    }
    buffer = buffer.dropFront(loc)
  }
  
  return ("", .none, lineNumber, buffer)
}

private func readCheckStrings(in buf : UnsafeBufferPointer<CChar>, withPrefixes prefixes : [String], checkNot : [String], options: FileCheckOptions, _ RE : NSRegularExpression) -> [CheckString] {
  // Keeps track of the line on which CheckPrefix instances are found.
  var lineNumber = 1
  var implicitNegativeChecks = [Pattern]()
  for notPattern in checkNot {
    if notPattern.isEmpty {
      continue
    }

    notPattern.utf8CString.withUnsafeBufferPointer { buf in
      let patBuf = UnsafeBufferPointer<CChar>(start: buf.baseAddress, count: buf.count - 1)
      let pat = Pattern(checking: .not, in: buf, pattern: patBuf, withPrefix: "IMPLICIT-CHECK", at: 0, options: options)!
      // Compute the message from this buffer now for diagnostics later.
      let msg = CheckLoc.inBuffer(buf.baseAddress!, buf).message
      implicitNegativeChecks.append(Pattern(copying: pat, at: .string("IMPLICIT-CHECK-NOT: " + msg)))
    }
  }
  var dagNotMatches = implicitNegativeChecks
  var contents = [CheckString]()

  var buffer = buf
  while true {
    // See if a prefix occurs in the memory buffer.
    let (usedPrefix, checkTy, ln, newBuffer) = findFirstMatch(in: buffer, among: prefixes, with: RE, startingAt: lineNumber)
    if usedPrefix.isEmpty {
      break
    }
    lineNumber = ln

    // Skip the buffer to the end.
    buffer = newBuffer.dropFront(usedPrefix.utf8.count + checkTy.size)

    // Complain about useful-looking but unsupported suffixes.
    if checkTy == .badNot {
      let loc = CheckLoc.inBuffer(buffer.baseAddress!, buf)
      diagnose(.error, at: loc, with: "unsupported -NOT combo on prefix '\(usedPrefix)'", options: options)
      return []
    }

    // Okay, we found the prefix, yay. Remember the rest of the line, but
    // ignore leading whitespace.
    if !options.contains(.strictWhitespace) || !options.contains(.matchFullLines) {
      guard let idx = buffer.index(where: { c in c != (" " as Character).utf8CodePoint && c != ("\t" as Character).utf8CodePoint }) else {
        return []
      }
      buffer = buffer.dropFront(idx)
    }

    // Scan ahead to the end of line.
    let EOL : Int = buffer.index(of: ("\n" as Character).utf8CodePoint) ?? buffer.index(of: ("\r" as Character).utf8CodePoint)!

    // Remember the location of the start of the pattern, for diagnostics.
    let patternLoc = CheckLoc.inBuffer(buffer.baseAddress!, buf)

    // Parse the pattern.
    let subBuffer = UnsafeBufferPointer<CChar>(start: buffer.baseAddress, count: EOL)
    guard let pat = Pattern(checking: checkTy, in: buf, pattern: subBuffer, withPrefix: usedPrefix, at: lineNumber, options: options) else {
      return []
    }

    // Verify that CHECK-LABEL lines do not define or use variables
    if (checkTy == .label) && pat.hasVariable {
      diagnose(.error, at: patternLoc, with: "found '\(usedPrefix)-LABEL:' with variable definition or use", options: options)
      return []
    }

    // Verify that CHECK-NEXT lines have at least one CHECK line before them.
    if (checkTy == .next || checkTy == .same) && contents.isEmpty {
      let type = (checkTy == .next) ? "NEXT" : "SAME"
      let loc = CheckLoc.inBuffer(buffer.baseAddress!, buf)
      diagnose(.error, at: loc, with: "found '\(usedPrefix)-\(type)' without previous '\(usedPrefix): line", options: options)
      return []
    }

    buffer = UnsafeBufferPointer<CChar>(
      start: buffer.baseAddress!.advanced(by: EOL),
      count: buffer.count - EOL
    )

    // Handle CHECK-DAG/-NOT.
    if checkTy == .dag || checkTy == .not {
      dagNotMatches.append(pat)
      continue
    }

    // Okay, add the string we captured to the output vector and move on.
    let cs = CheckString(
      pattern: pat,
      prefix: usedPrefix,
      loc: .string(patternLoc.message),
      dagNotStrings: dagNotMatches
    )
    contents.append(cs)
    dagNotMatches = implicitNegativeChecks
  }

  // Add an EOF pattern for any trailing CHECK-DAG/-NOTs, and use the first
  // prefix as a filler for the error message.
	if !dagNotMatches.isEmpty {
    let cs = CheckString(
      pattern: Pattern(withType: .EOF),
      prefix: prefixes.first!,
      loc: dagNotMatches.last!.patternLoc,
      dagNotStrings: dagNotMatches
    )
    contents.append(cs)
	}

  if contents.isEmpty {
    print("error: no check strings found with prefix\(contents.count == 1 ? " " : "es ")")
    for prefix in prefixes {
      print("\(prefix):")
    }
    return []
  }

  return contents
}

private final class BoxedTable {
  var table : [String:String] = [:]

  init() {}

  subscript(_ i : String) -> String? {
    set {
      self.table[i] = newValue!
    }
    get {
       return self.table[i]
    }
  }
}

/// Check the input to FileCheck provided in the buffer against the check 
/// strings read from the check file.
///
/// Returns `false` if the input fails to satisfy the checks.
private func check(input b : String, against checkStrings : [CheckString], options: FileCheckOptions) -> Bool {
  var buffer = b
  var failedChecks = false

  // This holds all the current filecheck variables.
  var variableTable = BoxedTable()

  var i = 0
  var j = 0
  while true {
    var checkRegion : String
    if j == checkStrings.count {
      checkRegion = buffer
    } else {
      let checkStr = checkStrings[j]
      if checkStr.pattern.type != .label {
        j += 1
        continue
      }

      // Scan to next CHECK-LABEL match, ignoring CHECK-NOT and CHECK-DAG
      guard let range = checkStr.check(buffer, true, variableTable, options) else {
        // Immediately bail of CHECK-LABEL fails, nothing else we can do.
        return false
      }

      checkRegion = buffer.substring(to: buffer.index(buffer.startIndex, offsetBy: NSMaxRange(range)))
      buffer = buffer.substring(from: buffer.index(buffer.startIndex, offsetBy: NSMaxRange(range)))
      j += 1
    }

    while i != j {
      defer { i += 1 }

      // Check each string within the scanned region, including a second check
      // of any final CHECK-LABEL (to verify CHECK-NOT and CHECK-DAG)
      guard let range = checkStrings[i].check(checkRegion, false, variableTable, options) else {
        failedChecks = true
        i = j
        break
      }

      checkRegion = checkRegion.substring(from: checkRegion.index(checkRegion.startIndex, offsetBy: NSMaxRange(range)))
    }

    if j == checkStrings.count {
      break
    }
  }

  // Success if no checks failed.
  return !failedChecks
}


private enum CheckLoc {
  case inBuffer(UnsafePointer<CChar>, UnsafeBufferPointer<CChar>)
  case string(String)

  var message : String {
    switch self {
    case let .inBuffer(ptr, buf):
      var startPtr = ptr
      while startPtr != buf.baseAddress! && startPtr.predecessor().pointee != ("\n" as Character).utf8CodePoint {
        startPtr = startPtr.predecessor()
      }

      var endPtr = ptr
      while endPtr != buf.baseAddress!.advanced(by: buf.endIndex) && endPtr.successor().pointee != ("\n" as Character).utf8CodePoint {
        endPtr = endPtr.successor()
      }
      // One more for good measure.
      if endPtr != buf.baseAddress!.advanced(by: buf.endIndex) {
        endPtr = endPtr.successor()
      }
      return substring(in: buf, with: NSMakeRange(buf.baseAddress!.distance(to: startPtr), startPtr.distance(to: endPtr)))
    case let .string(s):
      return s
    }
  }
}

enum CheckType {
  case none
  case plain
  case next
  case same
  case not
  case dag
  case label
  case badNot

  /// MatchEOF - When set, this pattern only matches the end of file. This is
  /// used for trailing CHECK-NOTs.
  case EOF

  // Get the size of the prefix extension.
  var size : Int {
    switch (self) {
    case .none:
      return 0
    case .badNot:
      return 0
    case .plain:
      return ":".utf8.count
    case .next:
      return "-NEXT:".utf8.count
    case .same:
      return "-SAME:".utf8.count
    case .not:
      return "-NOT:".utf8.count
    case .dag:
      return "-DAG:".utf8.count
    case .label:
      return "-LABEL:".utf8.count
    case .EOF:
      fatalError("Should not be using EOF size")
    }
  }
}

private class Pattern {
  let patternLoc : CheckLoc

  let type : CheckType

  /// If non-empty, this pattern is a fixed string match with the specified
  /// fixed string.
  let fixedString : String

  /// If non-empty, this is a regex pattern.
  var regExPattern : String = ""

  /// Contains the number of line this pattern is in.
  let lineNumber : Int

  /// Entries in this vector map to uses of a variable in the pattern, e.g.
  /// "foo[[bar]]baz".  In this case, the regExPattern will contain "foobaz"
  /// and we'll get an entry in this vector that tells us to insert the value
  /// of bar at offset 3.
  var variableUses : Array<(String, Int)> = []

  /// Maps definitions of variables to their parenthesized capture numbers.
  /// E.g. for the pattern "foo[[bar:.*]]baz", VariableDefs will map "bar" to 1.
  var variableDefs : Dictionary<String, Int> = [:]

  let options : FileCheckOptions

  var hasVariable : Bool {
    return !(variableUses.isEmpty && self.variableDefs.isEmpty)
  }

  init(copying other: Pattern, at loc: CheckLoc) {
    self.patternLoc = loc
    self.type = other.type
    self.fixedString = other.fixedString
    self.regExPattern = other.regExPattern
    self.lineNumber = other.lineNumber
    self.variableUses = other.variableUses
    self.variableDefs = other.variableDefs
    self.options = other.options
  }

  init(withType ty: CheckType) {
    self.type = ty
    self.patternLoc = .string("")
    self.lineNumber = -1
    self.fixedString = ""
    self.options = []
  }

  init?(checking ty : CheckType, in buf : UnsafeBufferPointer<CChar>, pattern : UnsafeBufferPointer<CChar>, withPrefix prefix : String, at lineNumber : Int, options: FileCheckOptions) {
    func mino(_ l : String.Index?, _ r : String.Index?) -> String.Index? {
      if l == nil && r == nil {
        return nil
      } else if l == nil && r != nil {
        return r
      } else if l != nil && r == nil {
        return l
      }
      return min(l!, r!)
    }

    self.type = ty
    self.lineNumber = lineNumber
    var patternStr = substring(in: pattern, with: NSRange(location: 0, length: pattern.count))
    self.patternLoc = CheckLoc.inBuffer(pattern.baseAddress!, buf)
    self.options = options

    // Check that there is something on the line.
    if patternStr.isEmpty {
      diagnose(.warning, at: self.patternLoc, with: "found empty check string with prefix '\(prefix):'", options: options)
      return nil
    }

    // Check to see if this is a fixed string, or if it has regex pieces.
    if !options.contains(.matchFullLines) &&
      (patternStr.utf8.count < 2 ||
        (patternStr.range(of: "{{") == nil
          &&
          patternStr.range(of: "[[") == nil))
    {
      self.fixedString = patternStr
      return
    } else {
      self.fixedString = ""
    }

    if options.contains(.matchFullLines) {
      regExPattern += "^"
      if !options.contains(.strictWhitespace) {
        regExPattern += " *"
      }
    }

    // Paren value #0 is for the fully matched string.  Any new
    // parenthesized values add from there.
    var curParen = 1

    // Otherwise, there is at least one regex piece.  Build up the regex pattern
    // by escaping scary characters in fixed strings, building up one big regex.
    while !patternStr.isEmpty {
      // RegEx matches.
      if patternStr.range(of: "{{")?.lowerBound == patternStr.startIndex {
        // This is the start of a regex match.  Scan for the }}.
        patternStr = patternStr.substring(from: patternStr.index(patternStr.startIndex, offsetBy: 2))
        guard let end = self.findRegexVarEnd(patternStr, brackets: (open: "{", close: "}"), terminator: "}}") else {
          let loc = CheckLoc.inBuffer(pattern.baseAddress!, buf)
          diagnose(.error, at: loc, with: "found start of regex string with no end '}}'", options: options)
          return nil
        }

        // Enclose {{}} patterns in parens just like [[]] even though we're not
        // capturing the result for any purpose.  This is required in case the
        // expression contains an alternation like: CHECK:  abc{{x|z}}def.  We
        // want this to turn into: "abc(x|z)def" not "abcx|zdef".
        regExPattern += "("
        curParen += 1

        let substr = patternStr.substring(to: end)
        let (res, paren) = self.addRegExToRegEx(substr, curParen)
        curParen = paren
        if res {
          return nil
        }
        regExPattern += ")"

        patternStr = patternStr.substring(from: patternStr.index(end, offsetBy: 2))
        continue
      }

      // Named RegEx matches.  These are of two forms: [[foo:.*]] which matches .*
      // (or some other regex) and assigns it to the FileCheck variable 'foo'. The
      // second form is [[foo]] which is a reference to foo.  The variable name
      // itself must be of the form "[a-zA-Z_][0-9a-zA-Z_]*", otherwise we reject
      // it.  This is to catch some common errors.
      if patternStr.hasPrefix("[[") {
        // Find the closing bracket pair ending the match.  End is going to be an
        // offset relative to the beginning of the match string.
        let regVar = patternStr.substring(from: patternStr.index(patternStr.startIndex, offsetBy: 2))
        guard let end = self.findRegexVarEnd(regVar, brackets: (open: "[", close: "]"), terminator: "]]") else {
          let loc = CheckLoc.inBuffer(pattern.baseAddress!, buf)
          diagnose(.error, at: loc, with: "invalid named regex reference, no ]] found", options: options)
          return nil
        }

        let matchStr = regVar.substring(to: end)
        patternStr = patternStr.substring(from: patternStr.index(end, offsetBy: 4))

        // Get the regex name (e.g. "foo").
        let nameEnd = matchStr.range(of: ":")
        let name : String
        if let end = nameEnd?.lowerBound {
          name = matchStr.substring(to: end)
        } else {
          name = matchStr
        }

        if name.isEmpty {
          let loc = CheckLoc.inBuffer(pattern.baseAddress!, buf)
          diagnose(.error, at: loc, with: "invalid name in named regex: empty name", options: options)
          return nil
        }

        // Verify that the name/expression is well formed. FileCheck currently
        // supports @LINE, @LINE+number, @LINE-number expressions. The check here
        // is relaxed, more strict check is performed in \c EvaluateExpression.
        var isExpression = false
        let diagLoc = CheckLoc.inBuffer(pattern.baseAddress!, buf)
        for (i, c) in name.characters.enumerated() {
          if i == 0 && c == "@" {
            if nameEnd == nil {
              diagnose(.error, at: diagLoc, with: "invalid name in named regex definition", options: options)
              return nil
            }
            isExpression = true
            continue
          }
          if c != "_" && isalnum(Int32(c.utf8CodePoint)) == 0 && (!isExpression || (c != "+" && c != "-")) {
            diagnose(.error, at: diagLoc, with: "invalid name in named regex", options: options)
            return nil
          }
        }

        // Name can't start with a digit.
        if isdigit(Int32(name.utf8.first!)) != 0 {
          diagnose(.error, at: diagLoc, with: "invalid name in named regex", options: options)
          return nil
        }

        // Handle [[foo]].
        guard let ne = nameEnd else {
          // Handle variables that were defined earlier on the same line by
          // emitting a backreference.
          if let varParenNum = self.variableDefs[name] {
            if varParenNum < 1 || varParenNum > 9 {
              diagnose(.error, at: diagLoc, with: "Can't back-reference more than 9 variables", options: options)
              return nil
            }
            self.addBackrefToRegEx(varParenNum)
          } else {
            variableUses.append((name, regExPattern.characters.count))
          }
          continue
        }

        // Handle [[foo:.*]].
        self.variableDefs[name] = curParen
        regExPattern += "("
        curParen += 1

        let (res, paren) = self.addRegExToRegEx(matchStr.substring(from: matchStr.index(after: ne.lowerBound)), curParen)
        curParen = paren
        if res {
          return nil
        }

        regExPattern += ")"
      }

      // Handle fixed string matches.
      // Find the end, which is the start of the next regex.
      if let fixedMatchEnd = mino(patternStr.range(of: "{{")?.lowerBound, patternStr.range(of: "[[")?.lowerBound) {
        self.regExPattern += NSRegularExpression.escapedPattern(for: patternStr.substring(to: fixedMatchEnd))
        patternStr = patternStr.substring(from: fixedMatchEnd)
      } else {
        // No more matches, time to quit.
        break
      }
    }

    if options.contains(.matchFullLines) {
      if !options.contains(.strictWhitespace) {
        regExPattern += " *"
        regExPattern += "$"
      }
    }
  }

  private func addBackrefToRegEx(_ backRef : Int) {
    assert(backRef >= 1 && backRef <= 9, "Invalid backref number")
    let Backref = "\\\(backRef)"
    self.regExPattern += Backref
  }

  /// - returns: Returns a value on success or nil on a syntax error.
  private func evaluateExpression(_ e : String) -> String? {
    var expr = e
    // The only supported expression is @LINE([\+-]\d+)?
    if !expr.hasPrefix("@LINE") {
      return nil
    }
    expr = expr.substring(from: expr.index(expr.startIndex, offsetBy: "@LINE".utf8.count))
    guard let firstC = expr.characters.first else {
      return "\(self.lineNumber)"
    }

    if firstC == "+" {
      expr = expr.substring(from: expr.index(after: expr.startIndex))
    } else if firstC != "-" {
      return nil
    }

    guard let offset = Int(expr, radix: 10) else {
      return nil
    }
    return "\(self.lineNumber + offset)"
  }

  /// Matches the pattern string against the input buffer.
  ///
  /// This returns the position that is matched or npos if there is no match. If
  /// there is a match, the range of the match is returned.
  ///
  /// The variable table provides the current values of filecheck variables and 
  /// is updated if this match defines new values.
  func match(_ buffer : String, _ variableTable : BoxedTable) -> NSRange? {
    // If this is the EOF pattern, match it immediately.
    if self.type == .EOF {
      return NSRange(location: buffer.utf8.count, length: 0)
    }

    // If this is a fixed string pattern, just match it now.
    if !self.fixedString.isEmpty {
      if let b = buffer.range(of: self.fixedString)?.lowerBound {
        return NSRange(location: buffer.distance(from: buffer.startIndex, to: b), length: self.fixedString.utf8.count)
      }
      return nil
    }

    // Regex match.

    // If there are variable uses, we need to create a temporary string with the
    // actual value.
    var regExToMatch = self.regExPattern
    if !self.variableUses.isEmpty {
      var insertOffset = 0
      for (v, offset) in self.variableUses {
        var value : String = ""

        if let c = v.characters.first, c == "@" {
          guard let v = self.evaluateExpression(v) else {
            return nil
          }
          value = v
        } else {
          guard let val = variableTable[v] else {
            return nil
          }

          // Look up the value and escape it so that we can put it into the regex.
          value += NSRegularExpression.escapedPattern(for: val)
        }

        // Plop it into the regex at the adjusted offset.
        regExToMatch.insert(contentsOf: value.characters, at: regExToMatch.index(regExToMatch.startIndex, offsetBy: offset + insertOffset))
        insertOffset += value.utf8.count
      }
    }

    // Match the newly constructed regex.
    guard let r = try? NSRegularExpression(pattern: regExToMatch, options: []) else {
      return nil
    }
    let matchInfo = r.matches(in: buffer, options: [], range: NSRange(location: 0, length: buffer.utf8.count))

    // Successful regex match.
    guard let fullMatch = matchInfo.first else {
      return nil
    }

    // If this defines any variables, remember their values.
    for (v, index) in self.variableDefs {
      assert(index < fullMatch.numberOfRanges, "Internal paren error")
    #if os(macOS)
      let r = fullMatch.rangeAt(index)
    #else
      let r = fullMatch.range(at: index)
    #endif
      variableTable[v] = buffer.substring(
        with: Range<String.Index>(
          uncheckedBounds: (
            buffer.index(buffer.startIndex, offsetBy: r.location),
            buffer.index(buffer.startIndex, offsetBy: NSMaxRange(r))
          )
        )
      )
    }

    return fullMatch.range
  }

  /// Finds the closing sequence of a regex variable usage or definition.
  ///
  /// The given string has to start in the beginning of the definition 
  /// (right after the opening sequence). Returns the offset of the closing 
  /// sequence within the string, or nil if it was not found.
  private func findRegexVarEnd(_ regVar : String, brackets: (open: Character, close: Character), terminator: String) -> String.Index? {
    var string = regVar
    // Offset keeps track of the current offset within the input Str
    var offset = regVar.startIndex
    // [...] Nesting depth
    var bracketDepth = 0

    while let firstChar = string.characters.first {
      if string.hasPrefix(terminator) && bracketDepth == 0 {
        return offset
      }
      if firstChar == "\\" {
        // Backslash escapes the next char within regexes, so skip them both.
        string = string.substring(from: string.index(string.startIndex, offsetBy: 2))
        offset = regVar.index(offset, offsetBy: 2)
      } else {
        switch firstChar {
        case brackets.open:
          bracketDepth += 1
        case brackets.close:
          if bracketDepth == 0 {
            diagnose(.error,
              at: .string(regVar),
              with: "missing closing \"\(brackets.close)\" for regex variable",
              options: self.options
            )
            return nil
          }
          bracketDepth -= 1
        default:
          break
        }
        string = string.substring(from: string.index(after: string.startIndex))
        offset = regVar.index(after: offset)
      }
    }

    return nil
  }

  private func addRegExToRegEx(_ RS : String, _ cur : Int) -> (Bool, Int) {
    do {
      let r = try NSRegularExpression(pattern: RS, options: [])
      self.regExPattern += RS
      return (false, cur + r.numberOfCaptureGroups)
    } catch let e {
      diagnose(.error, at: self.patternLoc, with: "invalid regex: \(e)", options: self.options)
      return (true, cur)
    }
  }
}

/// Count the number of newlines in the specified range.
func countNumNewlinesBetween(_ r : String) -> (Int, String.Index?) {
  var range = r
  var NumNewLines = 0
  var firstNewLine : String.Index? = nil
  while true {
    // Scan for newline.
    guard let EOL = range.range(of: "\n")?.lowerBound ?? range.range(of: "\r")?.lowerBound else {
      return (NumNewLines, firstNewLine)
    }
    range = range.substring(from: EOL)
    if range.isEmpty {
      return (NumNewLines, firstNewLine)
    }

    NumNewLines += 1

    // Handle \n\r and \r\n as a single newline.
    //		if Range.utf8.count > 1 && (Range.utf8[1] == '\n' || Range[1] == '\r') && (Range[0] != Range[1]) {
    //			Range = Range.substr(1)
    //		}
    range = range.substring(from: range.index(after: range.startIndex))

    if NumNewLines == 1 {
      firstNewLine = range.startIndex
    }
  }
}

/// CheckString - This is a check that we found in the input file.
private struct CheckString {
  /// The pattern to match.
  let pattern : Pattern

  /// Which prefix name this check matched.
  let prefix : String

  /// The location in the match file that the check string was specified.
  let loc : CheckLoc

  /// These are all of the strings that are disallowed from occurring between 
  /// this match string and the previous one (or start of file).
  var dagNotStrings : Array<Pattern>

  /// Match check string and its "not strings" and/or "dag strings".
  func check(_ buffer : String, _ isLabelScanMode : Bool,  _ variableTable : BoxedTable, _ options: FileCheckOptions) -> NSRange? {
    // This condition is true when we are scanning forward to find CHECK-LABEL
    // bounds we have not processed variable definitions within the bounded block
    // yet so cannot handle any final CHECK-DAG yet this is handled when going
    // over the block again (including the last CHECK-LABEL) in normal mode.
    let lastPos : Int
    let notStrings : [Pattern]
    if !isLabelScanMode {
      // Match "dag strings" (with mixed "not strings" if any).
      guard let (lp, ns) = self.checkDAG(buffer, variableTable, options) else {
        return nil
      }
      lastPos = lp
      notStrings = ns
    } else {
      lastPos = 0
      notStrings = []
    }

    // Match itself from the last position after matching CHECK-DAG.
    let matchBuffer = buffer.substring(from: buffer.index(buffer.startIndex, offsetBy: lastPos))
    guard let range = self.pattern.match(matchBuffer, variableTable) else {
      if self.pattern.fixedString.isEmpty {
        diagnose(.error,
          at: self.loc,
          with: self.prefix + ": could not find a match for regex '\(self.pattern.regExPattern)' in input",
          options: options
        )
      } else if self.pattern.regExPattern.isEmpty {
        diagnose(.error,
          at: self.loc,
          with: self.prefix + ": could not find '\(self.pattern.fixedString)' in input",
          options: options
        )
      } else {
        diagnose(.error,
          at: self.loc,
          with: self.prefix + ": could not find '\(self.pattern.fixedString)' (with regex '\(self.pattern.regExPattern)') in input",
          options: options
        )
      }
      return nil
    }
    let (matchPos, matchLen) = (range.location, range.length)

    // Similar to the above, in "label-scan mode" we can't yet handle CHECK-NEXT
    // or CHECK-NOT
    if !isLabelScanMode {
      let skippedRegion = buffer.substring(
        with: Range<String.Index>(
          uncheckedBounds: (
            buffer.index(buffer.startIndex, offsetBy: lastPos),
            buffer.index(buffer.startIndex, offsetBy: matchPos)
          )
        )
      )
      let rest = buffer.substring(from: buffer.index(buffer.startIndex, offsetBy: matchPos))

      // If this check is a "CHECK-NEXT", verify that the previous match was on
      // the previous line (i.e. that there is one newline between them).
      if self.checkNext(skippedRegion, rest, options) {
        return nil
      }

      // If this check is a "CHECK-SAME", verify that the previous match was on
      // the same line (i.e. that there is no newline between them).
      if self.checkSame(skippedRegion, rest, options) {
        return nil
      }

      // If this match had "not strings", verify that they don't exist in the
      // skipped region.
      if self.checkNot(skippedRegion, notStrings, variableTable, options) {
        return nil
      }
    }

    return NSRange(location: lastPos + matchPos, length: matchLen)
  }

  /// Verify there is no newline in the given buffer.
  private func checkSame(_ buffer : String, _ rest : String, _ options: FileCheckOptions) -> Bool {
    if self.pattern.type != .same {
      return false
    }

    // Count the number of newlines between the previous match and this one.
    //	  assert(Buffer.data() !=
    //				 SM.getMemoryBuffer(SM.FindBufferContainingLoc(
    //										SMLoc::getFromPointer(Buffer.data())))
    //					 ->getBufferStart() &&
    //			 "CHECK-SAME can't be the first check in a file")

    let (numNewLines, _ /*firstNewLine*/) = countNumNewlinesBetween(buffer)
    if numNewLines != 0 {
      diagnose(.error,
        at: self.loc,
        with: self.prefix + "-SAME: is not on the same line as the previous match",
        options: options
      )
      rest.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!, buf)
        diagnose(.note, at: loc, with: "'next' match was here", options: options)
      }
      buffer.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!, buf)
        diagnose(.note, at: loc, with: "previous match ended here", options: options)
      }
      return true
    }

    return false
  }

  /// Verify there is a single line in the given buffer.
  private func checkNext(_ buffer : String, _ rest : String, _ options: FileCheckOptions) -> Bool {
    if self.pattern.type != .next {
      return false
    }

    // Count the number of newlines between the previous match and this one.
    //	  assert(Buffer.data() !=
    //				 SM.getMemoryBuffer(SM.FindBufferContainingLoc(
    //										SMLoc::getFromPointer(Buffer.data())))
    //					 ->getBufferStart(), "CHECK-NEXT can't be the first check in a file")

    let (numNewLines, firstNewLine) = countNumNewlinesBetween(buffer)
    if numNewLines == 0 {
      diagnose(.error, at: self.loc, with: prefix + "-NEXT: is on the same line as previous match", options: options)
      rest.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!, buf)
        diagnose(.note, at: loc, with: "'next' match was here", options: options)
      }
      buffer.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!, buf)
        diagnose(.note, at: loc, with: "previous match ended here", options: options)
      }
      return true
    }

    if numNewLines != 1 {
      diagnose(.error, at: self.loc, with: prefix + "-NEXT: is not on the line after the previous match", options: options)
      rest.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!, buf)
        diagnose(.note, at: loc, with: "'next' match was here", options: options)
      }
      buffer.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!, buf)
        diagnose(.note, at: loc, with: "previous match ended here", options: options)
        if let fnl = firstNewLine {
          let noteLoc = CheckLoc.inBuffer(buf.baseAddress!.advanced(by: buffer.distance(from: buffer.startIndex, to: fnl)), buf)
          diagnose(.note, at: noteLoc, with: "non-matching line after previous match is here", options: options)
        }
      }
      return true
    }

    return false
  }

  /// Verify there's no "not strings" in the given buffer.
  private func checkNot(_ buffer : String, _ notStrings : [Pattern], _ variableTable : BoxedTable, _ options: FileCheckOptions) -> Bool {
    for pat in notStrings {
      assert(pat.type == .not, "Expect CHECK-NOT!")

      guard let range = pat.match(buffer, variableTable) else {
        continue
      }
      buffer.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
        let loc = CheckLoc.inBuffer(buf.baseAddress!.advanced(by: range.location), buf)
        diagnose(.error, at: loc, with: self.prefix + "-NOT: string occurred!", options: options)
      }
      diagnose(.note, at: pat.patternLoc, with: self.prefix + "-NOT: pattern specified here", options: options)
      return true
    }

    return false
  }

  /// Match "dag strings" and their mixed "not strings".
  func checkDAG(_ buffer : String, _ variableTable : BoxedTable, _ options: FileCheckOptions) -> (Int, [Pattern])? {
    var notStrings = [Pattern]()
    if dagNotStrings.isEmpty {
      return (0, notStrings)
    }
    
    var lastPos = 0
    var startPos = lastPos
    
    for pattern in self.dagNotStrings {
      assert((pattern.type == .dag || pattern.type == .not), "Invalid CHECK-DAG or CHECK-NOT!")
      
      if pattern.type == .not {
        notStrings.append(pattern)
        continue
      }
      
      assert((pattern.type == .dag), "Expect CHECK-DAG!")
      
      // CHECK-DAG always matches from the start.
      let matchBuffer = buffer.substring(from: buffer.index(buffer.startIndex, offsetBy: startPos))
      // With a group of CHECK-DAGs, a single mismatching means the match on
      // that group of CHECK-DAGs fails immediately.
      guard let range = pattern.match(matchBuffer, variableTable) else {
        //				PrintCheckFailed(SM, Pat.getLoc(), Pat, MatchBuffer, VariableTable)
        return nil
      }

      // Re-calc it as the offset relative to the start of the original string.
      let matchPos = range.location + startPos
      if !notStrings.isEmpty {
        if matchPos < lastPos {
          // Reordered?
          buffer.cString(using: .utf8)?.withUnsafeBufferPointer { buf in
            let loc1 = CheckLoc.inBuffer(buf.baseAddress!.advanced(by: matchPos), buf)
            diagnose(.error, at: loc1, with: prefix + "-DAG: found a match of CHECK-DAG reordering across a CHECK-NOT", options: options)
            let loc2 = CheckLoc.inBuffer(buf.baseAddress!.advanced(by: lastPos), buf)
            diagnose(.note, at: loc2, with: prefix + "-DAG: the farthest match of CHECK-DAG is found here", options: options)
          }
          diagnose(.note, at: notStrings[0].patternLoc, with: prefix + "-NOT: the crossed pattern specified here", options: options)
          diagnose(.note, at: pattern.patternLoc, with: prefix + "-DAG: the reordered pattern specified here", options: options)
          return nil
        }
        // All subsequent CHECK-DAGs should be matched from the farthest
        // position of all precedent CHECK-DAGs (including this one.)
        startPos = lastPos
        // If there's CHECK-NOTs between two CHECK-DAGs or from CHECK to
        // CHECK-DAG, verify that there's no 'not' strings occurred in that
        // region.
        let skippedRegion = buffer.substring(
          with: Range<String.Index>(
            uncheckedBounds: (
              buffer.index(buffer.startIndex, offsetBy: lastPos),
              buffer.index(buffer.startIndex, offsetBy: matchPos)
            )
          )
        )
        if self.checkNot(skippedRegion, notStrings, variableTable, options) {
          return nil
        }
        // Clear "not strings".
        notStrings.removeAll()
      }
      
      // Update the last position with CHECK-DAG matches.
      lastPos = max(matchPos + range.length, lastPos)
    }
    
    return (lastPos, notStrings)
  }
}

private enum DiagnosticKind: String {
  case error
  case warning
  case note

  var color: ANSIColor {
    switch self {
    case .error: return .red
    case .warning: return .magenta
    case .note: return .green
    }
  }
}

struct StdOutStream: TextOutputStream {
    mutating func write(_ string: String) {
        print(string, terminator: "")
    }
}

var stdoutStream = StdOutStream()
var diagnosticStream = ColoredANSIStream(&stdoutStream)

private func diagnose(_ kind : DiagnosticKind, at loc : CheckLoc, with message : String, options: FileCheckOptions) {
  let disableColors = options.contains(.disableColors)
  if disableColors {
    print("\(kind): \(message)")
  } else {
    diagnosticStream.write("\(kind): ", with: [.bold, kind.color])
    diagnosticStream.write("\(message)\n", with: [.bold])
  }

  let msg = loc.message
  if !msg.isEmpty {
    if disableColors {
      print(msg)
    } else {
      diagnosticStream.write("\(msg)\n")
    }
  }
}
