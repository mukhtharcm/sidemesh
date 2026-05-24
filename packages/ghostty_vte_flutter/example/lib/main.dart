import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeGhosttyVteWeb();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.controller, this.autoStart = true});

  final GhosttyTerminalController? controller;
  final bool autoStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ghostty VT Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E8F74),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF071019),
        useMaterial3: true,
      ),
      home: TerminalStudioPage(controller: controller, autoStart: autoStart),
    );
  }
}

class TerminalStudioPage extends StatefulWidget {
  const TerminalStudioPage({super.key, this.controller, this.autoStart = true});

  final GhosttyTerminalController? controller;
  final bool autoStart;

  @override
  State<TerminalStudioPage> createState() => _TerminalStudioPageState();
}

enum _DemoMouseTrackingProfile { disabled, x10, normal, button, any }

enum _DemoMouseFormatProfile { x10, utf8, sgr, urxvt, sgrPixels }

class _TerminalStudioPageState extends State<TerminalStudioPage>
    with SingleTickerProviderStateMixin {
  late final GhosttyTerminalController _terminal;
  late final bool _ownsTerminal;
  GhosttyTerminalShellProfile _selectedShellProfile =
      GhosttyTerminalShellProfile.auto;
  String _activeShellLabel = 'not started';
  String _activeShellCommand = '(not started)';
  Map<String, String> _activeShellEnvironment = const <String, String>{};
  final TextEditingController _commandController = TextEditingController(
    text:
        'printf "\\e]2;Ghostty VT Studio\\a\\e[32mreal terminal ready\\e[0m\\n"',
  );
  final TextEditingController _oscController = TextEditingController(
    text: '2;Ghostty VT Studio',
  );
  final TextEditingController _sgrController = TextEditingController(
    text: '1;38;2;14;143;116;4',
  );
  final TextEditingController _utf8Controller = TextEditingController(
    text: 'c',
  );
  final TextEditingController _codepointController = TextEditingController(
    text: '0x63',
  );
  final TextEditingController _fontFamilyController = TextEditingController();
  final TextEditingController _renderDumpStartRowController =
      TextEditingController();
  final TextEditingController _renderDumpEndRowController =
      TextEditingController();
  final TextEditingController _renderDumpStartColController =
      TextEditingController();
  final TextEditingController _renderDumpEndColController =
      TextEditingController();

  // Clipboard/selection/hyperlink state
  String _selectionText = '';
  String _lastCopiedText = '';
  String _lastHyperlink = '';
  int _pasteRequestCount = 0;

  // onWritePty activity log
  final List<String> _writePtyLog = <String>[];
  int _writePtyTotalBytes = 0;

  // Effect callback activity tracking
  int _bellCount = 0;
  int _titleChangedCount = 0;
  String _lastTitle = '';
  int _sizeQueryCount = 0;
  int _colorSchemeQueryCount = 0;
  int _deviceAttributesQueryCount = 0;
  int _enquiryCount = 0;
  int _xtversionCount = 0;
  final List<String> _effectLog = <String>[];

  static const List<_ActionOption> _actions = <_ActionOption>[
    _ActionOption('Press', GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS),
    _ActionOption('Repeat', GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT),
    _ActionOption('Release', GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE),
  ];

  static const List<_KeyOption> _keys = <_KeyOption>[
    _KeyOption('C', GhosttyKey.GHOSTTY_KEY_C),
    _KeyOption('Enter', GhosttyKey.GHOSTTY_KEY_ENTER),
    _KeyOption('Tab', GhosttyKey.GHOSTTY_KEY_TAB),
    _KeyOption('Up', GhosttyKey.GHOSTTY_KEY_ARROW_UP),
    _KeyOption('Down', GhosttyKey.GHOSTTY_KEY_ARROW_DOWN),
    _KeyOption('Left', GhosttyKey.GHOSTTY_KEY_ARROW_LEFT),
    _KeyOption('Right', GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT),
    _KeyOption('F1', GhosttyKey.GHOSTTY_KEY_F1),
    _KeyOption('F2', GhosttyKey.GHOSTTY_KEY_F2),
  ];

  static const List<_ModOption> _mods = <_ModOption>[
    _ModOption('Shift', GhosttyModsMask.shift),
    _ModOption('Ctrl', GhosttyModsMask.ctrl),
    _ModOption('Alt', GhosttyModsMask.alt),
    _ModOption('Super', GhosttyModsMask.superKey),
  ];

  static const List<_RendererModeOption> _rendererModes = <_RendererModeOption>[
    _RendererModeOption(
      label: 'Formatter Paint',
      value: GhosttyTerminalRendererMode.formatter,
      enabledOnWeb: true,
    ),
    _RendererModeOption(
      label: 'Render Paint',
      value: GhosttyTerminalRendererMode.renderState,
      enabledOnWeb: false,
      unavailableReason: 'Native render requires non-web platforms.',
    ),
  ];

  late final TabController _tabs = TabController(length: 5, vsync: this);

  final List<String> _activity = <String>[];
  GhosttyKeyAction _selectedAction = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS;
  GhosttyKey _selectedKey = GhosttyKey.GHOSTTY_KEY_C;
  final Set<int> _selectedMods = <int>{GhosttyModsMask.ctrl};
  bool _composing = false;
  bool _formatterPalette = false;
  bool _formatterModes = false;
  bool _formatterScrollingRegion = false;
  bool _formatterTabstops = false;
  bool _formatterPwd = false;
  bool _formatterKeyboard = false;
  bool _formatterCursor = false;
  bool _formatterStyle = false;
  bool _formatterHyperlink = false;
  bool _formatterProtection = false;
  bool _formatterKittyKeyboard = false;
  bool _formatterCharsets = false;
  Uint8List _encodedBytes = Uint8List(0);
  String _plainSnapshot = '';
  String _vtSnapshot = '';
  String _htmlSnapshot = '';
  bool _pasteSafe = true;
  bool _hideDemoChrome = false;
  bool _fullWidthTerminal = false;
  bool _renderDumpOnlyInterestingRows = true;
  double _cellWidthScale = 1;
  GhosttyTerminalRendererMode _renderer = GhosttyTerminalRendererMode.formatter;
  GhosttyTerminalInteractionPolicy _interactionPolicy =
      GhosttyTerminalInteractionPolicy.auto;
  _DemoMouseTrackingProfile _mouseTrackingProfile =
      _DemoMouseTrackingProfile.disabled;
  _DemoMouseFormatProfile _mouseFormatProfile = _DemoMouseFormatProfile.sgr;
  bool _mouseFocusEvents = false;
  bool _mouseAltScroll = false;
  VtOscCommand? _oscCommand;
  String? _oscError;
  List<VtSgrAttributeData> _sgrAttributes = <VtSgrAttributeData>[];
  String? _sgrError;

  GhosttyTerminalShellLaunch? get _controllerLaunch =>
      _terminal.activeShellLaunch;

  String get _currentShellLabel =>
      _controllerLaunch?.label ?? _activeShellLabel;

  String get _currentShellCommand =>
      _controllerLaunch?.commandLine ?? _activeShellCommand;

  Map<String, String> get _currentShellEnvironment =>
      _controllerLaunch?.environment ?? _activeShellEnvironment;

  String get _terminalFontFamily {
    final configured = _fontFamilyController.text.trim();
    if (configured.isNotEmpty) {
      return configured;
    }
    return GoogleFonts.notoSansMono().fontFamily ?? 'monospace';
  }

  List<String> get _terminalFontFallback {
    final symbolsFamily = GoogleFonts.notoSansSymbols2().fontFamily;
    return <String>[
      if (symbolsFamily != null && _terminalFontFamily != symbolsFamily)
        symbolsFamily,
      'Noto Color Emoji',
    ];
  }

  void _refreshDump() {
    setState(() {
      // Rebuild to recompute `_renderViewportDump()` from the latest inspector state.
    });
  }

  @override
  void initState() {
    super.initState();
    _terminal = widget.controller ?? GhosttyTerminalController();
    _ownsTerminal = widget.controller == null;
    _terminal.addListener(_onTerminalChanged);
    _terminal.onWritePtyData = _onWritePtyData;
    _terminal.onBellData = _onBell;
    _terminal.onTitleChangedData = _onTitleChanged;
    _terminal.onSizeQueryData = _onSizeQuery;
    _terminal.onColorSchemeQueryData = _onColorSchemeQuery;
    _terminal.onDeviceAttributesQueryData = _onDeviceAttributesQuery;
    _terminal.onEnquiryData = _onEnquiry;
    _terminal.onXtversionData = _onXtversion;
    if (widget.autoStart) {
      _bootstrap();
    } else {
      _recomputeInspectorState(
        addLog: false,
        refreshSnapshots: false,
        skipNativeChecks: true,
      );
    }
  }

  @override
  void dispose() {
    _terminal.onWritePtyData = null;
    _terminal.onBellData = null;
    _terminal.onTitleChangedData = null;
    _terminal.onSizeQueryData = null;
    _terminal.onColorSchemeQueryData = null;
    _terminal.onDeviceAttributesQueryData = null;
    _terminal.onEnquiryData = null;
    _terminal.onXtversionData = null;
    _terminal.removeListener(_onTerminalChanged);
    if (_ownsTerminal) {
      _terminal.dispose();
    }
    _tabs.dispose();
    _commandController.dispose();
    _oscController.dispose();
    _sgrController.dispose();
    _utf8Controller.dispose();
    _codepointController.dispose();
    _fontFamilyController.dispose();
    _renderDumpStartRowController.dispose();
    _renderDumpEndRowController.dispose();
    _renderDumpStartColController.dispose();
    _renderDumpEndColController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final launch = await _startDemoShell();
    _activeShellLabel = launch.label;
    _activeShellCommand = launch.commandLine;
    _activeShellEnvironment = launch.environment ?? const <String, String>{};
    if (kIsWeb) {
      _terminal.appendDebugOutput(
        '\x1b]2;Ghostty VT Studio\x07'
        '\x1b[32mweb demo backend attached\x1b[0m\n'
        '\x1b[90mType into the terminal and inspect formatter outputs on the right.\x1b[0m\n',
      );
    }
    _appendLog('Terminal session started (${launch.label}).');
    _recomputeInspectorState(addLog: false);
    if (mounted) {
      setState(() {});
    }
  }

  Future<_DemoShellLaunch> _startDemoShell() async {
    if (kIsWeb) {
      await _terminal.start();
      return const _DemoShellLaunch(
        label: 'web transport demo',
        commandLine: 'web transport demo',
      );
    }

    final launch = await _terminal.startShellProfile(
      profile: _selectedShellProfile,
      platformEnvironment: ghosttyTerminalPlatformEnvironment(),
    );
    if (launch != null) {
      return _DemoShellLaunch(
        label: launch.label,
        commandLine: launch.commandLine,
        environment: launch.environment,
      );
    }

    final fallbackEnvironment = ghosttyTerminalShellEnvironment(
      platformEnvironment: ghosttyTerminalPlatformEnvironment(),
      overrides: const <String, String>{'TERM': 'xterm-256color'},
    );
    await _terminal.start(environment: fallbackEnvironment);
    return _DemoShellLaunch(
      label: 'default shell fallback',
      commandLine: '(default shell)',
      environment: fallbackEnvironment,
    );
  }

  Future<void> _selectShellProfile(GhosttyTerminalShellProfile profile) async {
    if (_selectedShellProfile == profile) {
      return;
    }
    setState(() {
      _selectedShellProfile = profile;
    });
    if (_terminal.isRunning) {
      await _restartTerminal();
    }
  }

  bool _safeTerminalMode(VtMode mode) {
    try {
      return _terminal.terminal.getMode(mode);
    } catch (_) {
      return false;
    }
  }

  void _applyMouseProtocolModes() {
    try {
      final terminal = _terminal.terminal;
      terminal.setMode(VtModes.x10Mouse, false);
      terminal.setMode(VtModes.normalMouse, false);
      terminal.setMode(VtModes.buttonMouse, false);
      terminal.setMode(VtModes.anyMouse, false);
      terminal.setMode(VtModes.utf8Mouse, false);
      terminal.setMode(VtModes.sgrMouse, false);
      terminal.setMode(VtModes.urxvtMouse, false);
      terminal.setMode(VtModes.sgrPixelsMouse, false);

      switch (_mouseTrackingProfile) {
        case _DemoMouseTrackingProfile.disabled:
          break;
        case _DemoMouseTrackingProfile.x10:
          terminal.setMode(VtModes.x10Mouse, true);
        case _DemoMouseTrackingProfile.normal:
          terminal.setMode(VtModes.normalMouse, true);
        case _DemoMouseTrackingProfile.button:
          terminal.setMode(VtModes.buttonMouse, true);
        case _DemoMouseTrackingProfile.any:
          terminal.setMode(VtModes.anyMouse, true);
      }

      switch (_mouseFormatProfile) {
        case _DemoMouseFormatProfile.x10:
          break;
        case _DemoMouseFormatProfile.utf8:
          terminal.setMode(VtModes.utf8Mouse, true);
        case _DemoMouseFormatProfile.sgr:
          terminal.setMode(VtModes.sgrMouse, true);
        case _DemoMouseFormatProfile.urxvt:
          terminal.setMode(VtModes.urxvtMouse, true);
        case _DemoMouseFormatProfile.sgrPixels:
          terminal.setMode(VtModes.sgrPixelsMouse, true);
      }

      terminal.setMode(VtModes.focusEvent, _mouseFocusEvents);
      terminal.setMode(VtModes.altScroll, _mouseAltScroll);
    } catch (_) {}
    _recomputeInspectorState(addLog: false);
  }

  void _syncMouseProtocolControlsFromTerminal() {
    if (_safeTerminalMode(VtModes.anyMouse)) {
      _mouseTrackingProfile = _DemoMouseTrackingProfile.any;
    } else if (_safeTerminalMode(VtModes.buttonMouse)) {
      _mouseTrackingProfile = _DemoMouseTrackingProfile.button;
    } else if (_safeTerminalMode(VtModes.normalMouse)) {
      _mouseTrackingProfile = _DemoMouseTrackingProfile.normal;
    } else if (_safeTerminalMode(VtModes.x10Mouse)) {
      _mouseTrackingProfile = _DemoMouseTrackingProfile.x10;
    } else {
      _mouseTrackingProfile = _DemoMouseTrackingProfile.disabled;
    }

    if (_safeTerminalMode(VtModes.sgrPixelsMouse)) {
      _mouseFormatProfile = _DemoMouseFormatProfile.sgrPixels;
    } else if (_safeTerminalMode(VtModes.sgrMouse)) {
      _mouseFormatProfile = _DemoMouseFormatProfile.sgr;
    } else if (_safeTerminalMode(VtModes.urxvtMouse)) {
      _mouseFormatProfile = _DemoMouseFormatProfile.urxvt;
    } else if (_safeTerminalMode(VtModes.utf8Mouse)) {
      _mouseFormatProfile = _DemoMouseFormatProfile.utf8;
    } else {
      _mouseFormatProfile = _DemoMouseFormatProfile.x10;
    }

    _mouseFocusEvents = _safeTerminalMode(VtModes.focusEvent);
    _mouseAltScroll = _safeTerminalMode(VtModes.altScroll);
  }

  void _onTerminalChanged() {
    if (!mounted) {
      return;
    }
    _refreshSnapshots();
    _syncMouseProtocolControlsFromTerminal();
    setState(() {});
  }

  void _onWritePtyData(Uint8List data) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final preview = data.length <= 32 ? hex : '${hex.substring(0, 95)}...';
    _writePtyLog.insert(0, '$hh:$mm:$ss.$ms  ${data.length}B  $preview');
    if (_writePtyLog.length > 200) {
      _writePtyLog.removeLast();
    }
    _writePtyTotalBytes += data.length;
    if (mounted) {
      setState(() {});
    }
  }

  void _appendEffectLog(String message) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    _effectLog.insert(0, '$hh:$mm:$ss.$ms  $message');
    if (_effectLog.length > 200) {
      _effectLog.removeLast();
    }
  }

  void _onBell() {
    _bellCount++;
    _appendEffectLog('BEL received (#$_bellCount)');
    if (mounted) setState(() {});
  }

  void _onTitleChanged() {
    _titleChangedCount++;
    _lastTitle = _terminal.title;
    _appendEffectLog('Title changed to "$_lastTitle" (#$_titleChangedCount)');
    if (mounted) setState(() {});
  }

  VtSizeReportSize? _onSizeQuery() {
    _sizeQueryCount++;
    _appendEffectLog('Size query (#$_sizeQueryCount)');
    if (mounted) setState(() {});
    return VtSizeReportSize(
      rows: _terminal.rows,
      columns: _terminal.cols,
      cellWidth: 8,
      cellHeight: 16,
    );
  }

  GhosttyColorScheme? _onColorSchemeQuery() {
    _colorSchemeQueryCount++;
    _appendEffectLog('Color scheme query (#$_colorSchemeQueryCount)');
    if (mounted) setState(() {});
    return GhosttyColorScheme.GHOSTTY_COLOR_SCHEME_DARK;
  }

  VtDeviceAttributes? _onDeviceAttributesQuery() {
    _deviceAttributesQueryCount++;
    _appendEffectLog('Device attributes query (#$_deviceAttributesQueryCount)');
    if (mounted) setState(() {});
    return const VtDeviceAttributes(
      primary: VtDeviceAttributesPrimary(
        conformanceLevel: 62,
        features: <int>[1, 6, 7, 22],
      ),
      secondary: VtDeviceAttributesSecondary(
        deviceType: 1,
        firmwareVersion: 10,
      ),
      tertiary: VtDeviceAttributesTertiary(unitId: 0),
    );
  }

  Uint8List _onEnquiry() {
    _enquiryCount++;
    _appendEffectLog('ENQ received (#$_enquiryCount)');
    if (mounted) setState(() {});
    // Respond with an empty answerback by default.
    return Uint8List(0);
  }

  String _onXtversion() {
    _xtversionCount++;
    _appendEffectLog('XTVERSION query (#$_xtversionCount)');
    if (mounted) setState(() {});
    return 'GhosttyVTStudio 1.0';
  }

  void _appendLog(String message) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    _activity.insert(0, '$hh:$mm:$ss  $message');
    if (_activity.length > 120) {
      _activity.removeLast();
    }
  }

  void _refreshSnapshots() {
    _plainSnapshot = _terminal.plainText;
    final extra = _formatterExtra;
    _vtSnapshot = _terminal.formatTerminal(
      emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
      extra: extra,
      trim: false,
    );
    _htmlSnapshot = _terminal.formatTerminal(
      emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_HTML,
      extra: extra,
      trim: false,
    );
  }

  VtFormatterTerminalExtra get _formatterExtra => VtFormatterTerminalExtra(
    palette: _formatterPalette,
    modes: _formatterModes,
    scrollingRegion: _formatterScrollingRegion,
    tabstops: _formatterTabstops,
    pwd: _formatterPwd,
    keyboard: _formatterKeyboard,
    screen: VtFormatterScreenExtra(
      cursor: _formatterCursor,
      style: _formatterStyle,
      hyperlink: _formatterHyperlink,
      protection: _formatterProtection,
      kittyKeyboard: _formatterKittyKeyboard,
      charsets: _formatterCharsets,
    ),
  );

  bool get _allFormatterExtrasEnabled =>
      _formatterPalette &&
      _formatterModes &&
      _formatterScrollingRegion &&
      _formatterTabstops &&
      _formatterPwd &&
      _formatterKeyboard &&
      _formatterCursor &&
      _formatterStyle &&
      _formatterHyperlink &&
      _formatterProtection &&
      _formatterKittyKeyboard &&
      _formatterCharsets;

  void _setAllFormatterExtras(bool enabled) {
    setState(() {
      _formatterPalette = enabled;
      _formatterModes = enabled;
      _formatterScrollingRegion = enabled;
      _formatterTabstops = enabled;
      _formatterPwd = enabled;
      _formatterKeyboard = enabled;
      _formatterCursor = enabled;
      _formatterStyle = enabled;
      _formatterHyperlink = enabled;
      _formatterProtection = enabled;
      _formatterKittyKeyboard = enabled;
      _formatterCharsets = enabled;
      _recomputeInspectorState(addLog: false);
    });
  }

  String _mouseProtocolSummary() {
    try {
      final state = _terminal.terminal.mouseProtocolState;
      if (!state.enabled) {
        return 'Mouse reporting: disabled';
      }
      return 'Mouse reporting: ${state.trackingMode?.name ?? 'unknown'}'
          ' • ${state.format?.name ?? 'unknown'}'
          ' • focus ${state.focusEvents ? 'on' : 'off'}'
          ' • altScroll ${state.altScroll ? 'on' : 'off'}';
    } catch (_) {
      return 'Mouse reporting unavailable before native terminal init.';
    }
  }

  String _renderSemanticSummary() {
    final snapshot = _terminal.renderSnapshot;
    if (snapshot == null || !snapshot.hasViewportData) {
      return 'Render snapshot unavailable on this platform or before native viewport update.';
    }

    var promptRows = 0;
    var continuationRows = 0;
    var promptTextCells = 0;
    var promptInputCells = 0;
    var promptOutputCells = 0;

    for (final row in snapshot.rowsData) {
      if (row.isPrompt) {
        promptRows += 1;
      }
      if (row.isPromptContinuation) {
        continuationRows += 1;
      }
      for (final cell in row.cells) {
        if (cell.isPromptText) {
          promptTextCells += 1;
        }
        if (cell.isPromptInput) {
          promptInputCells += 1;
        }
        if (cell.isPromptOutput) {
          promptOutputCells += 1;
        }
      }
    }

    final cursor = snapshot.cursor;
    return 'rows=${snapshot.rowsData.length}\n'
        'promptRows=$promptRows\n'
        'promptContinuationRows=$continuationRows\n'
        'promptTextCells=$promptTextCells\n'
        'promptInputCells=$promptInputCells\n'
        'promptOutputCells=$promptOutputCells\n'
        'cursorVisible=${cursor.visible}\n'
        'cursorViewport=${cursor.hasViewportPosition ? '${cursor.row},${cursor.col}' : '(offscreen)'}';
  }

  String _renderViewportDump() {
    final snapshot = _terminal.renderSnapshot;
    if (snapshot == null || !snapshot.hasViewportData) {
      return 'Render snapshot unavailable on this platform or before native viewport update.';
    }

    final startRow = _parseNullableInt(_renderDumpStartRowController.text);
    final endRow = _parseNullableInt(_renderDumpEndRowController.text);
    final startCol = _parseNullableInt(_renderDumpStartColController.text);
    final endCol = _parseNullableInt(_renderDumpEndColController.text);

    final buffer = StringBuffer()
      ..writeln(
        'cols=${snapshot.cols} rows=${snapshot.rows} dirty=${snapshot.dirty}',
      )
      ..writeln(
        'cursor=${snapshot.cursor.hasViewportPosition ? '${snapshot.cursor.row},${snapshot.cursor.col}' : '(offscreen)'}'
        ' visible=${snapshot.cursor.visible}'
        ' blinking=${snapshot.cursor.blinking}'
        ' wideTail=${snapshot.cursor.onWideTail}',
      );

    for (var rowIndex = 0; rowIndex < snapshot.rowsData.length; rowIndex++) {
      if (startRow != null && rowIndex < startRow) {
        continue;
      }
      if (endRow != null && rowIndex > endRow) {
        continue;
      }

      final row = snapshot.rowsData[rowIndex];
      final visibleText = _sliceRenderRowText(
        row,
        startCol: startCol,
        endCol: endCol,
      );
      if (_renderDumpOnlyInterestingRows &&
          visibleText.trim().isEmpty &&
          !row.dirty &&
          !row.hasHyperlink &&
          !row.styled &&
          !row.wrap &&
          !row.wrapContinuation) {
        continue;
      }

      buffer
        ..writeln(
          'row $rowIndex '
          'dirty=${row.dirty} wrap=${row.wrap} cont=${row.wrapContinuation} '
          'styled=${row.styled} link=${row.hasHyperlink}',
        )
        ..writeln('  text: ${visibleText.replaceAll('\t', r'\t')}');

      var col = 0;
      for (final cell in row.cells) {
        final cellStartCol = col;
        final cellEndCol = col + cell.width - 1;
        final overlapsSelectedColumns =
            (startCol == null || cellEndCol >= startCol) &&
            (endCol == null || cellStartCol <= endCol);
        final codepoint = cell.metadata.codepoint;
        final display = cell.text.isEmpty ? ' ' : cell.text;
        final interesting =
            cell.width != 1 ||
            cell.hasStyling ||
            cell.hasHyperlink ||
            cell.metadata.hasBackgroundColor ||
            cell.text.isEmpty ||
            codepoint > 0x7F;
        if (interesting && overlapsSelectedColumns) {
          buffer.writeln(
            '  [$cellStartCol] "${_escapeDumpText(display)}" '
            'U+${codepoint.toRadixString(16).toUpperCase().padLeft(4, '0')} '
            'w=${cell.width} '
            'text=${cell.hasText} style=${cell.hasStyling} link=${cell.hasHyperlink} '
            'bg=${_describeOptionalColor(cell.metadata.backgroundColor)} '
            'semantic=${cell.semanticContent.name}',
          );
        }
        col += cell.width;
      }
    }

    return buffer.toString().trimRight();
  }

  String _sliceRenderRowText(
    GhosttyTerminalRenderRow row, {
    int? startCol,
    int? endCol,
  }) {
    final buffer = StringBuffer();
    var col = 0;
    for (final cell in row.cells) {
      final cellStartCol = col;
      final cellEndCol = col + cell.width - 1;
      final overlapsSelectedColumns =
          (startCol == null || cellEndCol >= startCol) &&
          (endCol == null || cellStartCol <= endCol);
      if (overlapsSelectedColumns) {
        if (cell.text.isNotEmpty) {
          buffer.write(cell.text);
        } else {
          buffer.write(' '.padRight(cell.width));
        }
      }
      col += cell.width;
    }
    return buffer.toString();
  }

  int? _parseNullableInt(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return int.tryParse(trimmed);
  }

  String _escapeDumpText(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');

  String _describeOptionalColor(Color? color) {
    if (color == null) {
      return 'none';
    }
    final argb = color.toARGB32();
    final hex =
        '${((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0')}'
        '${((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0')}'
        '${(argb & 0xFF).toRadixString(16).padLeft(2, '0')}';
    return '#$hex';
  }

  Future<void> _copyTextToClipboard(
    String text, {
    required String message,
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _recomputeInspectorState({
    bool addLog = true,
    bool refreshSnapshots = true,
    bool skipNativeChecks = false,
  }) {
    if (refreshSnapshots) {
      _refreshSnapshots();
    } else {
      _plainSnapshot = '';
      _vtSnapshot = '';
      _htmlSnapshot = '';
    }
    if (skipNativeChecks) {
      _pasteSafe = true;
      _oscCommand = null;
      _oscError = 'OSC parser unavailable without native assets.';
      _sgrAttributes = <VtSgrAttributeData>[];
      _sgrError = 'SGR parser unavailable without native assets.';
      _encodedBytes = Uint8List(0);
    } else {
      _pasteSafe = GhosttyVt.isPasteSafe(_commandController.text);
      _parseOsc();
      _parseSgr();
      _encodeKeyPreview();
    }
    if (addLog) {
      _appendLog('Refreshed formatter, parser, and key inspector state.');
    }
  }

  Future<void> _restartTerminal() async {
    await _terminal.stop();
    final launch = await _startDemoShell();
    _activeShellLabel = launch.label;
    _activeShellCommand = launch.commandLine;
    _activeShellEnvironment = launch.environment ?? const <String, String>{};
    _appendLog('Terminal session restarted (${launch.label}).');
    _recomputeInspectorState(addLog: false);
    setState(() {});
  }

  Future<void> _stopTerminal() async {
    await _terminal.stop();
    _appendLog('Terminal session stopped.');
    setState(() {});
  }

  Future<void> _copyShellEnvironment() async {
    final text = _formatEnvironment(_currentShellEnvironment);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied shell environment.')));
  }

  void _sendCommand() {
    final sent = _terminal.write(
      '${_commandController.text}\n',
      sanitizePaste: true,
    );
    if (sent) {
      _appendLog('Sent command to shell stdin.');
    } else {
      _appendLog(
        'Command send blocked (session stopped or paste safety failed).',
      );
    }
    setState(() {});
  }

  void _injectDemoOutput() {
    _terminal.appendDebugOutput(
      '\x1b]2;Ghostty VT Studio\x07'
      '\x1b[1;32mVT demo\x1b[0m  '
      '\x1b[4;38;2;255;190;92mwrapped formatter output\x1b[0m\n'
      'normal line\n'
      '\x1b[2Koverwritten line\rrepainted line\n'
      '\x1b[90mOSC title and SGR styling are feeding the live terminal.\x1b[0m\n',
    );
    _appendLog('Injected demo VT output into the terminal buffer.');
    _recomputeInspectorState(addLog: false);
    setState(() {});
  }

  void _clearTerminal() {
    _terminal.clear();
    _appendLog('Reset terminal and cleared scrollback snapshot.');
    _recomputeInspectorState(addLog: false);
    setState(() {});
  }

  void _sendQuickKey(GhosttyKey key, {int mods = 0, String utf8Text = ''}) {
    final sent = _terminal.sendKey(
      key: key,
      mods: mods,
      utf8Text: utf8Text,
      unshiftedCodepoint: utf8Text.isEmpty ? 0 : utf8Text.runes.first,
    );
    _appendLog(
      sent ? 'Sent key ${key.name}.' : 'Key send failed (terminal stopped).',
    );
    setState(() {});
  }

  void _sendDemoMouse() {
    final sent = _terminal.sendMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
      position: const VtMousePosition(x: 16, y: 16),
      size: const VtMouseEncoderSize(
        screenWidth: 1280,
        screenHeight: 720,
        cellWidth: 10,
        cellHeight: 20,
      ),
      trackingMode: GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL,
      format: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR,
    );
    _appendLog(sent ? 'Sent demo mouse event.' : 'Mouse send failed.');
    setState(() {});
  }

  void _encodeKeyPreview() {
    final encoder = VtKeyEncoder();
    final event = VtKeyEvent();
    try {
      encoder.setOptionsFromTerminal(_terminal.terminal);
      event
        ..action = _selectedAction
        ..key = _selectedKey
        ..mods = _maskFrom(_selectedMods)
        ..composing = _composing
        ..utf8Text = _utf8Controller.text
        ..unshiftedCodepoint = _parseCodepoint(_codepointController.text);
      _encodedBytes = encoder.encode(event);
    } catch (_) {
      _encodedBytes = Uint8List(0);
    } finally {
      event.close();
      encoder.close();
    }
  }

  int _maskFrom(Set<int> values) {
    var out = 0;
    for (final value in values) {
      out |= value;
    }
    return out;
  }

  int _parseCodepoint(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return 0;
    }
    if (trimmed.startsWith('0x') || trimmed.startsWith('0X')) {
      return int.parse(trimmed.substring(2), radix: 16);
    }
    return int.parse(trimmed);
  }

  void _parseOsc() {
    final parser = VtOscParser();
    try {
      parser.addText(_oscController.text);
      _oscCommand = parser.end();
      _oscError = null;
    } catch (error) {
      _oscCommand = null;
      _oscError = error.toString();
    } finally {
      parser.close();
    }
  }

  void _parseSgr() {
    final matches = RegExp(r'\d+').allMatches(_sgrController.text);
    final values = matches.map((m) => int.parse(m.group(0)!)).toList();
    if (values.isEmpty) {
      _sgrAttributes = <VtSgrAttributeData>[];
      _sgrError = 'Enter one or more integer params such as 1;31;4.';
      return;
    }

    final parser = VtSgrParser();
    try {
      _sgrAttributes = parser.parseParams(values);
      _sgrError = null;
    } catch (error) {
      _sgrAttributes = <VtSgrAttributeData>[];
      _sgrError = error.toString();
    } finally {
      parser.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1180;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ghostty VT Studio'),
        actions: <Widget>[
          IconButton(
            tooltip: _hideDemoChrome
                ? 'Show demo controls'
                : 'Hide most demo controls',
            onPressed: () => setState(() {
              _hideDemoChrome = !_hideDemoChrome;
            }),
            icon: Icon(
              _hideDemoChrome
                  ? Icons.tune_outlined
                  : Icons.visibility_off_outlined,
            ),
          ),
          IconButton(
            tooltip: _fullWidthTerminal
                ? 'Restore split layout'
                : 'Use full-width terminal',
            onPressed: () => setState(() {
              _fullWidthTerminal = !_fullWidthTerminal;
            }),
            icon: Icon(
              _fullWidthTerminal
                  ? Icons.splitscreen_outlined
                  : Icons.width_full_outlined,
            ),
          ),
          TextButton.icon(
            onPressed: _terminal.isRunning ? _stopTerminal : _restartTerminal,
            icon: Icon(
              _terminal.isRunning
                  ? Icons.stop_circle_outlined
                  : Icons.play_arrow_outlined,
            ),
            label: Text(_terminal.isRunning ? 'Stop' : 'Start'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: wide
            ? _buildWideBody(theme)
            : ListView(
                children: <Widget>[
                  SizedBox(height: 620, child: _buildTerminalColumn(theme)),
                  const SizedBox(height: 16),
                  SizedBox(height: 560, child: _buildInspector(theme)),
                ],
              ),
      ),
    );
  }

  Widget _buildWideBody(ThemeData theme) {
    if (_fullWidthTerminal) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(flex: 9, child: _buildTerminalColumn(theme)),
          const SizedBox(height: 16),
          Expanded(flex: 6, child: _buildInspector(theme)),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(flex: 8, child: _buildTerminalColumn(theme)),
        const SizedBox(width: 16),
        Expanded(flex: 7, child: _buildInspector(theme)),
      ],
    );
  }

  Widget _buildTerminalColumn(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final terminalHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * 0.42).clamp(220.0, 420.0)
            : 320.0;
        if (_hideDemoChrome) {
          final fullHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : terminalHeight;
          return _buildTerminalViewport(theme, height: fullHeight);
        }
        return ListView(
          children: <Widget>[
            if (!kIsWeb) ...<Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: GhosttyTerminalShellProfile.values
                    .map(
                      (profile) => ChoiceChip(
                        label: Text(profile.label),
                        selected: _selectedShellProfile == profile,
                        onSelected: (_) => _selectShellProfile(profile),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _sendCommand,
                  icon: const Icon(Icons.subdirectory_arrow_left),
                  label: const Text('Send Command'),
                ),
                OutlinedButton.icon(
                  onPressed: _injectDemoOutput,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Inject VT Demo'),
                ),
                OutlinedButton.icon(
                  onPressed: _clearTerminal,
                  icon: const Icon(Icons.layers_clear),
                  label: const Text('Reset'),
                ),
                OutlinedButton.icon(
                  onPressed: _restartTerminal,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Restart Shell'),
                ),
                _StatusPill(
                  label: _terminal.isRunning ? 'Running' : 'Stopped',
                  color: _terminal.isRunning
                      ? const Color(0xFF2BD576)
                      : const Color(0xFFD65C5C),
                ),
                _StatusPill(
                  label: '${_terminal.cols} x ${_terminal.rows}',
                  color: theme.colorScheme.secondary,
                ),
                _StatusPill(
                  label: '${_terminal.lineCount} lines',
                  color: theme.colorScheme.tertiary,
                ),
                _StatusPill(
                  label: _currentShellLabel,
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _commandController,
              onChanged: (_) => setState(() {
                _pasteSafe = GhosttyVt.isPasteSafe(_commandController.text);
              }),
              decoration: InputDecoration(
                labelText: 'Shell command or pasted text',
                helperText: _pasteSafe
                    ? 'Paste-safe input'
                    : 'Paste safety would block this input',
                helperStyle: TextStyle(
                  color: _pasteSafe
                      ? const Color(0xFF76E5B1)
                      : const Color(0xFFFFA899),
                ),
                border: const OutlineInputBorder(),
                suffixIcon: Icon(
                  _pasteSafe ? Icons.verified : Icons.warning_amber_rounded,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 280,
                  child: TextField(
                    controller: _fontFamilyController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Terminal font family',
                      hintText: 'JetBrainsMono Nerd Font',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 240,
                    maxWidth: 360,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Cell width scale ${_cellWidthScale.toStringAsFixed(2)}',
                      ),
                      Slider(
                        value: _cellWidthScale,
                        min: 0.75,
                        max: 1.4,
                        divisions: 13,
                        label: _cellWidthScale.toStringAsFixed(2),
                        onChanged: (value) => setState(() {
                          _cellWidthScale = value;
                        }),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final mode in _rendererModes)
                      mode.enabledOnWeb || !kIsWeb
                          ? ChoiceChip(
                              key: ValueKey<String>(
                                'render-mode-${mode.value.name}',
                              ),
                              label: Text(mode.label),
                              selected: _renderer == mode.value,
                              onSelected: (_) => setState(() {
                                _renderer = mode.value;
                              }),
                            )
                          : Tooltip(
                              message:
                                  mode.unavailableReason ??
                                  'Render mode unavailable on web',
                              child: ChoiceChip(
                                key: ValueKey<String>(
                                  'render-mode-${mode.value.name}',
                                ),
                                label: Text(mode.label),
                                selected: _renderer == mode.value,
                                onSelected: null,
                              ),
                            ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Renderer: ${_renderer.name}'),
                const SizedBox(height: 8),
                SegmentedButton<GhosttyTerminalInteractionPolicy>(
                  segments:
                      const <ButtonSegment<GhosttyTerminalInteractionPolicy>>[
                        ButtonSegment<GhosttyTerminalInteractionPolicy>(
                          value: GhosttyTerminalInteractionPolicy.auto,
                          label: Text('Auto'),
                          icon: Icon(Icons.tune),
                        ),
                        ButtonSegment<GhosttyTerminalInteractionPolicy>(
                          value:
                              GhosttyTerminalInteractionPolicy.selectionFirst,
                          label: Text('Selection First'),
                          icon: Icon(Icons.select_all),
                        ),
                        ButtonSegment<GhosttyTerminalInteractionPolicy>(
                          value: GhosttyTerminalInteractionPolicy
                              .terminalMouseFirst,
                          label: Text('Terminal Mouse'),
                          icon: Icon(Icons.mouse),
                        ),
                      ],
                  selected: <GhosttyTerminalInteractionPolicy>{
                    _interactionPolicy,
                  },
                  onSelectionChanged:
                      (Set<GhosttyTerminalInteractionPolicy> selection) {
                        setState(() {
                          _interactionPolicy = selection.first;
                        });
                      },
                ),
                const SizedBox(height: 8),
                Text('Interaction: ${_interactionPolicy.name}'),
                const SizedBox(height: 4),
                Text(_mouseProtocolSummary()),
                const SizedBox(height: 8),
                const Text('Mouse Tracking'),
                SegmentedButton<_DemoMouseTrackingProfile>(
                  segments: const <ButtonSegment<_DemoMouseTrackingProfile>>[
                    ButtonSegment<_DemoMouseTrackingProfile>(
                      value: _DemoMouseTrackingProfile.disabled,
                      label: Text('Disabled'),
                    ),
                    ButtonSegment<_DemoMouseTrackingProfile>(
                      value: _DemoMouseTrackingProfile.x10,
                      label: Text('X10'),
                    ),
                    ButtonSegment<_DemoMouseTrackingProfile>(
                      value: _DemoMouseTrackingProfile.normal,
                      label: Text('Normal'),
                    ),
                    ButtonSegment<_DemoMouseTrackingProfile>(
                      value: _DemoMouseTrackingProfile.button,
                      label: Text('Button'),
                    ),
                    ButtonSegment<_DemoMouseTrackingProfile>(
                      value: _DemoMouseTrackingProfile.any,
                      label: Text('Any'),
                    ),
                  ],
                  selected: <_DemoMouseTrackingProfile>{_mouseTrackingProfile},
                  onSelectionChanged:
                      (Set<_DemoMouseTrackingProfile> selection) {
                        setState(() {
                          _mouseTrackingProfile = selection.first;
                        });
                        _applyMouseProtocolModes();
                      },
                ),
                const SizedBox(height: 8),
                const Text('Mouse Format'),
                SegmentedButton<_DemoMouseFormatProfile>(
                  segments: const <ButtonSegment<_DemoMouseFormatProfile>>[
                    ButtonSegment<_DemoMouseFormatProfile>(
                      value: _DemoMouseFormatProfile.x10,
                      label: Text('X10'),
                    ),
                    ButtonSegment<_DemoMouseFormatProfile>(
                      value: _DemoMouseFormatProfile.utf8,
                      label: Text('UTF8'),
                    ),
                    ButtonSegment<_DemoMouseFormatProfile>(
                      value: _DemoMouseFormatProfile.sgr,
                      label: Text('SGR'),
                    ),
                    ButtonSegment<_DemoMouseFormatProfile>(
                      value: _DemoMouseFormatProfile.urxvt,
                      label: Text('URXVT'),
                    ),
                    ButtonSegment<_DemoMouseFormatProfile>(
                      value: _DemoMouseFormatProfile.sgrPixels,
                      label: Text('SGR Pixels'),
                    ),
                  ],
                  selected: <_DemoMouseFormatProfile>{_mouseFormatProfile},
                  onSelectionChanged: (Set<_DemoMouseFormatProfile> selection) {
                    setState(() {
                      _mouseFormatProfile = selection.first;
                    });
                    _applyMouseProtocolModes();
                  },
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FilterChip(
                      label: const Text('Focus Events'),
                      selected: _mouseFocusEvents,
                      onSelected: (selected) {
                        setState(() {
                          _mouseFocusEvents = selected;
                        });
                        _applyMouseProtocolModes();
                      },
                    ),
                    FilterChip(
                      label: const Text('Alt Scroll'),
                      selected: _mouseAltScroll,
                      onSelected: (selected) {
                        setState(() {
                          _mouseAltScroll = selected;
                        });
                        _applyMouseProtocolModes();
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildTerminalViewport(theme, height: terminalHeight),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: () =>
                      _sendQuickKey(GhosttyKey.GHOSTTY_KEY_ARROW_UP),
                  child: const Text('Up'),
                ),
                FilledButton.tonal(
                  onPressed: () =>
                      _sendQuickKey(GhosttyKey.GHOSTTY_KEY_ARROW_LEFT),
                  child: const Text('Left'),
                ),
                FilledButton.tonal(
                  onPressed: () =>
                      _sendQuickKey(GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT),
                  child: const Text('Right'),
                ),
                FilledButton.tonal(
                  onPressed: () =>
                      _sendQuickKey(GhosttyKey.GHOSTTY_KEY_BACKSPACE),
                  child: const Text('Backspace'),
                ),
                FilledButton.tonal(
                  onPressed: () => _sendQuickKey(
                    GhosttyKey.GHOSTTY_KEY_C,
                    mods: GhosttyModsMask.ctrl,
                    utf8Text: 'c',
                  ),
                  child: const Text('Ctrl+C'),
                ),
                FilledButton.tonal(
                  onPressed: () => _sendQuickKey(GhosttyKey.GHOSTTY_KEY_TAB),
                  child: const Text('Tab'),
                ),
                FilledButton.tonal(
                  onPressed: () => _sendQuickKey(GhosttyKey.GHOSTTY_KEY_ENTER),
                  child: const Text('Enter'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildTerminalViewport(ThemeData theme, {required double height}) {
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: GhosttyTerminalView(
            controller: _terminal,
            autofocus: true,
            showVerticalScrollbar: true,
            chromeColor: const Color(0xFF10212C),
            backgroundColor: const Color(0xFF060D13),
            foregroundColor: const Color(0xFFE7F8F5),
            fontSize: 14,
            lineHeight: 1.32,
            fontFamily: _terminalFontFamily,
            fontFamilyFallback: _terminalFontFallback,
            cellWidthScale: _cellWidthScale,
            renderer: _renderer,
            interactionPolicy: _interactionPolicy,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            onSelectionChanged: (selection) {
              setState(() {
                _selectionText = selection != null
                    ? '${selection.base} -> ${selection.extent}'
                    : '';
              });
              _appendLog(
                selection != null
                    ? 'Selection changed: ${selection.base} -> ${selection.extent}'
                    : 'Selection cleared.',
              );
            },
            onCopySelection: (text) async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!mounted) {
                return;
              }
              setState(() {
                _lastCopiedText = text.length > 120
                    ? '${text.substring(0, 120)}...'
                    : text;
              });
              _appendLog('Copied ${text.length} chars to clipboard.');
            },
            onPasteRequest: () async {
              setState(() {
                _pasteRequestCount += 1;
              });
              _appendLog('Paste requested (#$_pasteRequestCount).');
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              return data?.text;
            },
            onOpenHyperlink: (uri) async {
              setState(() {
                _lastHyperlink = uri;
              });
              _appendLog('Hyperlink activated: $uri');
            },
          ),
        ),
      ),
    );
  }

  Widget _buildInspector(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF09131C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          TabBar(
            controller: _tabs,
            tabs: const <Tab>[
              Tab(text: 'Snapshots'),
              Tab(text: 'Key Encoder'),
              Tab(text: 'Parsers'),
              Tab(text: 'Session'),
              Tab(text: 'Terminal'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _buildSnapshotsTab(),
                _buildKeyTab(),
                _buildParserTab(),
                _buildSessionTab(),
                _buildTerminalTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshotsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          'Formatter Extras',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilterChip(
              label: const Text('All Extras'),
              selected: _allFormatterExtrasEnabled,
              onSelected: _setAllFormatterExtras,
            ),
            _boolChip(
              'Palette',
              _formatterPalette,
              (v) => setState(() {
                _formatterPalette = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Modes',
              _formatterModes,
              (v) => setState(() {
                _formatterModes = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Scrolling Region',
              _formatterScrollingRegion,
              (v) => setState(() {
                _formatterScrollingRegion = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Tabstops',
              _formatterTabstops,
              (v) => setState(() {
                _formatterTabstops = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'PWD',
              _formatterPwd,
              (v) => setState(() {
                _formatterPwd = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Keyboard',
              _formatterKeyboard,
              (v) => setState(() {
                _formatterKeyboard = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Cursor',
              _formatterCursor,
              (v) => setState(() {
                _formatterCursor = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Style',
              _formatterStyle,
              (v) => setState(() {
                _formatterStyle = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Hyperlink',
              _formatterHyperlink,
              (v) => setState(() {
                _formatterHyperlink = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Protection',
              _formatterProtection,
              (v) => setState(() {
                _formatterProtection = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Kitty Keyboard',
              _formatterKittyKeyboard,
              (v) => setState(() {
                _formatterKittyKeyboard = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
            _boolChip(
              'Charsets',
              _formatterCharsets,
              (v) => setState(() {
                _formatterCharsets = v;
                _recomputeInspectorState(addLog: false);
              }),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _snapshotCard('Plain Text', _plainSnapshot),
        const SizedBox(height: 12),
        _snapshotCard('VT Output', _vtSnapshot),
        const SizedBox(height: 12),
        _snapshotCard('HTML Output', _htmlSnapshot),
        const SizedBox(height: 12),
        _snapshotCard('Render Semantics', _renderSemanticSummary()),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _renderDumpStartRowController,
                decoration: const InputDecoration(
                  labelText: 'Start row',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _renderDumpEndRowController,
                decoration: const InputDecoration(
                  labelText: 'End row',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _renderDumpStartColController,
                decoration: const InputDecoration(
                  labelText: 'Start col',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _renderDumpEndColController,
                decoration: const InputDecoration(
                  labelText: 'End col',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilterChip(
              label: const Text('Only interesting rows'),
              selected: _renderDumpOnlyInterestingRows,
              onSelected: (selected) => setState(() {
                _renderDumpOnlyInterestingRows = selected;
              }),
            ),
            OutlinedButton.icon(
              onPressed: _refreshDump,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Dump'),
            ),
            OutlinedButton.icon(
              onPressed: () => _copyTextToClipboard(
                _renderViewportDump(),
                message: 'Copied renderState viewport dump.',
              ),
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy Dump'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _snapshotCard('RenderState Viewport Dump', _renderViewportDump()),
      ],
    );
  }

  Widget _buildKeyTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<GhosttyKeyAction>(
                initialValue: _selectedAction,
                decoration: const InputDecoration(
                  labelText: 'Action',
                  border: OutlineInputBorder(),
                ),
                items: _actions
                    .map(
                      (option) => DropdownMenuItem<GhosttyKeyAction>(
                        value: option.value,
                        child: Text(option.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _selectedAction = value;
                    _encodeKeyPreview();
                  });
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<GhosttyKey>(
                initialValue: _selectedKey,
                decoration: const InputDecoration(
                  labelText: 'Key',
                  border: OutlineInputBorder(),
                ),
                items: _keys
                    .map(
                      (option) => DropdownMenuItem<GhosttyKey>(
                        value: option.value,
                        child: Text(option.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _selectedKey = value;
                    _encodeKeyPreview();
                  });
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _mods
              .map(
                (option) => FilterChip(
                  label: Text(option.label),
                  selected: _selectedMods.contains(option.mask),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _selectedMods.add(option.mask);
                      } else {
                        _selectedMods.remove(option.mask);
                      }
                      _encodeKeyPreview();
                    });
                  },
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _utf8Controller,
                decoration: const InputDecoration(
                  labelText: 'UTF-8 text',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(_encodeKeyPreview),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _codepointController,
                decoration: const InputDecoration(
                  labelText: 'Unshifted codepoint',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(_encodeKeyPreview),
              ),
            ),
          ],
        ),
        SwitchListTile.adaptive(
          value: _composing,
          title: const Text('Composing'),
          contentPadding: EdgeInsets.zero,
          onChanged: (value) {
            setState(() {
              _composing = value;
              _encodeKeyPreview();
            });
          },
        ),
        const SizedBox(height: 8),
        _snapshotCard(
          'Encoded bytes',
          _encodedBytes.isEmpty
              ? '(empty)'
              : _encodedBytes
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(' '),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () {
            final sent = _terminal.sendKey(
              key: _selectedKey,
              action: _selectedAction,
              mods: _maskFrom(_selectedMods),
              composing: _composing,
              utf8Text: _utf8Controller.text,
              unshiftedCodepoint: _parseCodepoint(_codepointController.text),
            );
            _appendLog(
              sent ? 'Sent custom key event.' : 'Key event send failed.',
            );
            setState(() {});
          },
          icon: const Icon(Icons.keyboard),
          label: const Text('Send Key Event'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _sendDemoMouse,
          icon: const Icon(Icons.mouse),
          label: const Text('Send Demo Mouse Event'),
        ),
      ],
    );
  }

  Widget _buildParserTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          'Paste Safety',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          _pasteSafe
              ? 'Current command is safe to paste.'
              : 'Current command would be blocked by paste safety.',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _oscController,
          decoration: const InputDecoration(
            labelText: 'OSC payload',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {
            _parseOsc();
          }),
        ),
        const SizedBox(height: 8),
        _snapshotCard(
          'OSC result',
          _oscError ??
              'type=${_oscCommand?.type.name ?? 'unknown'}\nwindowTitle=${_oscCommand?.windowTitle ?? '(none)'}',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _sgrController,
          decoration: const InputDecoration(
            labelText: 'SGR params',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {
            _parseSgr();
          }),
        ),
        const SizedBox(height: 8),
        _snapshotCard(
          'SGR attributes',
          _sgrError ??
              (_sgrAttributes.isEmpty
                  ? '(none)'
                  : _sgrAttributes
                        .map((attr) => _describeSgr(attr))
                        .join('\n')),
        ),
      ],
    );
  }

  Widget _buildTerminalTab() {
    String terminalState;
    try {
      final vt = _terminal.terminal;
      final cursor = vt.cursorPosition;
      final screen = vt.isPrimaryScreen
          ? 'primary'
          : vt.isAlternateScreen
          ? 'alternate'
          : 'unknown';
      final scrollbar = vt.scrollbar;
      terminalState =
          'title="${vt.title}"\n'
          'pwd="${vt.pwd}"\n'
          'cursor=(${cursor.x}, ${cursor.y})\n'
          'cursorPendingWrap=${vt.cursorPendingWrap}\n'
          'activeScreen=$screen\n'
          'totalRows=${vt.totalRows}  scrollbackRows=${vt.scrollbackRows}\n'
          'size=${vt.widthPx}x${vt.heightPx} px\n'
          'scrollbar: offset=${scrollbar.offset} / total=${scrollbar.total} visible=${scrollbar.length}\n'
          'mouseTracking=${vt.mouseTracking}\n'
          'bracketedPaste=${_safeTerminalMode(VtModes.bracketedPaste)}\n'
          'cursorKeys=${_safeTerminalMode(VtModes.cursorKeys)}\n'
          'kittyKeyboardFlags=${vt.kittyKeyboardFlags}\n'
          '${_mouseProtocolSummary()}';
    } catch (_) {
      terminalState = '(terminal not yet initialized)';
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _snapshotCard('Terminal State', terminalState),
        const SizedBox(height: 12),
        _snapshotCard(
          'Clipboard / Selection',
          'selection=$_selectionText\n'
              'lastCopied=${_lastCopiedText.isEmpty ? '(none)' : _lastCopiedText}\n'
              'lastHyperlink=${_lastHyperlink.isEmpty ? '(none)' : _lastHyperlink}\n'
              'pasteRequests=$_pasteRequestCount',
        ),
        const SizedBox(height: 12),

        // --- Trigger Effects ---
        Row(
          children: <Widget>[
            const Text(
              'Trigger Effects',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                _bellCount = 0;
                _titleChangedCount = 0;
                _lastTitle = '';
                _sizeQueryCount = 0;
                _colorSchemeQueryCount = 0;
                _deviceAttributesQueryCount = 0;
                _enquiryCount = 0;
                _xtversionCount = 0;
                _effectLog.clear();
              }),
              child: const Text('Reset'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _triggerButton(
              label: 'BEL',
              tooltip: 'Send BEL character (0x07)',
              sequence: '\x07',
            ),
            _triggerButton(
              label: 'Set Title',
              tooltip: r'Send OSC 2 ; Demo Title BEL',
              sequence: '\x1b]2;Demo Title\x07',
            ),
            _triggerButton(
              label: 'Size Query',
              tooltip: 'Send CSI 18 t (text area size)',
              sequence: '\x1b[18t',
            ),
            _triggerButton(
              label: 'Color Scheme',
              tooltip: 'Send CSI ? 996 n',
              sequence: '\x1b[?996n',
            ),
            _triggerButton(
              label: 'DA1',
              tooltip: 'Send CSI c (primary device attributes)',
              sequence: '\x1b[c',
            ),
            _triggerButton(
              label: 'DA2',
              tooltip: 'Send CSI > c (secondary device attributes)',
              sequence: '\x1b[>c',
            ),
            _triggerButton(
              label: 'DA3',
              tooltip: 'Send CSI = c (tertiary device attributes)',
              sequence: '\x1b[=c',
            ),
            _triggerButton(
              label: 'ENQ',
              tooltip: 'Send ENQ character (0x05)',
              sequence: '\x05',
            ),
            _triggerButton(
              label: 'XTVERSION',
              tooltip: 'Send CSI > q',
              sequence: '\x1b[>q',
            ),
            _triggerButton(
              label: 'DSR',
              tooltip: 'Send CSI 5 n (device status report)',
              sequence: '\x1b[5n',
            ),
          ],
        ),
        const SizedBox(height: 12),
        _snapshotCard(
          'Effect Callback Counters',
          'bell=$_bellCount\n'
              'titleChanged=$_titleChangedCount  title="$_lastTitle"\n'
              'sizeQuery=$_sizeQueryCount\n'
              'colorSchemeQuery=$_colorSchemeQueryCount\n'
              'deviceAttributesQuery=$_deviceAttributesQueryCount\n'
              'enquiry=$_enquiryCount\n'
              'xtversion=$_xtversionCount',
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            const Text(
              'Effect Callback Log',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _effectLog.clear()),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _snapshotCard(
          'Effect Log',
          _effectLog.isEmpty
              ? '(no effect callbacks triggered yet — press a button above)'
              : _effectLog.take(60).join('\n'),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            const Text(
              'onWritePty Activity',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Text(
              '$_writePtyTotalBytes bytes total',
              style: const TextStyle(fontSize: 12, color: Color(0xFF76E5B1)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() {
                _writePtyLog.clear();
                _writePtyTotalBytes = 0;
              }),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _snapshotCard(
          'Write PTY Log',
          _writePtyLog.isEmpty
              ? '(no pty writes yet — trigger with DSR queries, DA responses, etc.)'
              : _writePtyLog.take(60).join('\n'),
        ),
      ],
    );
  }

  Widget _buildSessionTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _snapshotCard(
          'Session Stats',
          'running=${_terminal.isRunning}\n'
              'title=${_terminal.title}\n'
              'size=${_terminal.cols}x${_terminal.rows}\n'
              'lines=${_terminal.lineCount}\n'
              'scrollback=${_terminal.maxScrollback}',
        ),
        const SizedBox(height: 12),
        _snapshotCard(
          'Launch',
          'profile=${_selectedShellProfile.label}\n'
              'label=$_currentShellLabel\n'
              'command=$_currentShellCommand',
        ),
        const SizedBox(height: 12),
        _snapshotCard(
          'Environment',
          _formatEnvironment(_currentShellEnvironment),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _copyShellEnvironment,
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy Environment'),
          ),
        ),
        const SizedBox(height: 12),
        _snapshotCard(
          'Recent Activity',
          _activity.isEmpty ? '(no activity yet)' : _activity.join('\n'),
        ),
      ],
    );
  }

  Widget _snapshotCard(String title, String body) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1A24),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF193041)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SelectableText(
              body,
              style: const TextStyle(fontFamily: 'monospace', height: 1.35),
            ),
          ],
        ),
      ),
    );
  }

  Widget _triggerButton({
    required String label,
    required String tooltip,
    required String sequence,
  }) {
    return Tooltip(
      message: tooltip,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF193041),
          foregroundColor: const Color(0xFF76E5B1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
        onPressed: () {
          _terminal.terminal.write(sequence);
          _appendEffectLog('Injected: $label');
          setState(() {});
        },
        child: Text(label),
      ),
    );
  }

  Widget _boolChip(String label, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label),
      selected: value,
      onSelected: onChanged,
    );
  }

  String _describeSgr(VtSgrAttributeData attr) {
    final buffer = StringBuffer(attr.tag.name);
    if (attr.paletteIndex != null) {
      buffer.write(' index=${attr.paletteIndex}');
    }
    if (attr.rgb != null) {
      buffer.write(' rgb=${attr.rgb}');
    }
    if (attr.underline != null) {
      buffer.write(' underline=${attr.underline!.name}');
    }
    if (attr.unknown != null) {
      buffer.write(' unknown=${attr.unknown!.partial}');
    }
    return buffer.toString();
  }

  String _formatEnvironment(Map<String, String> environment) {
    if (environment.isEmpty) {
      return '(inherited or unavailable)';
    }
    final entries = environment.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((entry) => '${entry.key}=${entry.value}').join('\n');
  }
}

class _DemoShellLaunch {
  const _DemoShellLaunch({
    required this.label,
    required this.commandLine,
    this.environment,
  });

  final String label;
  final String commandLine;
  final Map<String, String>? environment;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _ActionOption {
  const _ActionOption(this.label, this.value);

  final String label;
  final GhosttyKeyAction value;
}

class _KeyOption {
  const _KeyOption(this.label, this.value);

  final String label;
  final GhosttyKey value;
}

class _ModOption {
  const _ModOption(this.label, this.mask);

  final String label;
  final int mask;
}

class _RendererModeOption {
  const _RendererModeOption({
    required this.label,
    required this.value,
    required this.enabledOnWeb,
    this.unavailableReason,
  });

  final String label;
  final GhosttyTerminalRendererMode value;
  final bool enabledOnWeb;
  final String? unavailableReason;
}
