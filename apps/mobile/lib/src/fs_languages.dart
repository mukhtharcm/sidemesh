/// Guess the highlight.js language id from a file path's extension.
/// Returns null when the extension is unknown — the syntax widget will
/// fall back to plaintext rendering.
String? languageForPath(String path) {
  final lastSlash = path.lastIndexOf('/');
  final name = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
  final lower = name.toLowerCase();
  if (!lower.contains('.')) {
    return _bareNameLanguage(lower);
  }
  final ext = lower.substring(lower.lastIndexOf('.') + 1);
  switch (ext) {
    case 'dart':
      return 'dart';
    case 'ts':
    case 'tsx':
      return 'typescript';
    case 'js':
    case 'mjs':
    case 'cjs':
    case 'jsx':
      return 'javascript';
    case 'json':
      return 'json';
    case 'yaml':
    case 'yml':
      return 'yaml';
    case 'toml':
      return 'ini';
    case 'md':
    case 'markdown':
      return 'markdown';
    case 'html':
    case 'htm':
      return 'xml';
    case 'xml':
    case 'svg':
      return 'xml';
    case 'css':
      return 'css';
    case 'scss':
    case 'sass':
      return 'scss';
    case 'rs':
      return 'rust';
    case 'go':
      return 'go';
    case 'py':
      return 'python';
    case 'rb':
      return 'ruby';
    case 'java':
      return 'java';
    case 'kt':
    case 'kts':
      return 'kotlin';
    case 'swift':
      return 'swift';
    case 'c':
    case 'h':
      return 'c';
    case 'cpp':
    case 'cc':
    case 'cxx':
    case 'hpp':
    case 'hh':
      return 'cpp';
    case 'cs':
      return 'csharp';
    case 'sh':
    case 'bash':
    case 'zsh':
      return 'bash';
    case 'sql':
      return 'sql';
    case 'gradle':
      return 'groovy';
    case 'dockerfile':
      return 'dockerfile';
    case 'tf':
      return 'hcl';
    case 'lua':
      return 'lua';
    case 'php':
      return 'php';
    default:
      return null;
  }
}

String? _bareNameLanguage(String name) {
  switch (name) {
    case 'dockerfile':
      return 'dockerfile';
    case 'makefile':
      return 'makefile';
    case 'cargo.lock':
    case 'cargo.toml':
      return 'ini';
    default:
      return null;
  }
}
