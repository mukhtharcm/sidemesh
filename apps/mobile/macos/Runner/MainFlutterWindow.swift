import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()

    // Default launch size — tuned for a laptop display; user can resize.
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let width: CGFloat = min(1180, screenFrame.width - 120)
    let height: CGFloat = min(760, screenFrame.height - 120)
    let originX = screenFrame.midX - width / 2
    let originY = screenFrame.midY - height / 2
    let windowFrame = NSRect(x: originX, y: originY, width: width, height: height)

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 520)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let nativeComposerRegistrar = flutterViewController.registrar(forPlugin: "SidemeshNativeComposer")
    let nativeComposerFactory = SidemeshNativeComposerViewFactory(messenger: nativeComposerRegistrar.messenger)
    nativeComposerRegistrar.register(nativeComposerFactory, withId: "sidemesh/native-composer")

    super.awakeFromNib()
  }
}

private final class SidemeshNativeComposerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    SidemeshNativeComposerView(
      viewIdentifier: viewId,
      arguments: args,
      messenger: messenger
    )
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class SidemeshNativeComposerView: NSView, NSTextViewDelegate {
  private let channel: FlutterMethodChannel
  private let scrollView = NSScrollView(frame: .zero)
  private let textView = NSTextView(frame: .zero)
  private let placeholderLabel = NSTextField(labelWithString: "")
  private var suppressOutgoingEdits = false
  private var shouldRestoreFocusAfterActivation = false

  init(viewIdentifier viewId: Int64, arguments args: Any?, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "sidemesh/native_composer/\(viewId)",
      binaryMessenger: messenger
    )
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupViews()
    applyCreationArguments(args)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidResignActive),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    channel.setMethodCallHandler(nil)
  }

  private func setupViews() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.delegate = self
    textView.drawsBackground = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.font = NSFont.systemFont(ofSize: 15)
    textView.textColor = NSColor.labelColor
    textView.insertionPointColor = NSColor.labelColor
    textView.textContainerInset = NSSize(width: 0, height: 8)
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )

    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.textColor = NSColor.placeholderTextColor
    placeholderLabel.font = NSFont.systemFont(ofSize: 15)
    placeholderLabel.lineBreakMode = .byTruncatingTail
    placeholderLabel.isHidden = true

    addSubview(scrollView)
    addSubview(placeholderLabel)
    scrollView.documentView = textView

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    ])
  }

  private func applyCreationArguments(_ args: Any?) {
    let map = args as? [String: Any]
    placeholderLabel.stringValue = map?["placeholder"] as? String ?? ""
    let initialText = map?["text"] as? String ?? ""
    let initialLength = (initialText as NSString).length
    let selectionStart = map?["selectionStart"] as? Int ?? initialLength
    let selectionEnd = map?["selectionEnd"] as? Int ?? selectionStart
    applyEditingState(text: initialText, selectionStart: selectionStart, selectionEnd: selectionEnd)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setEditingState":
      let map = call.arguments as? [String: Any] ?? [:]
      let text = map["text"] as? String ?? ""
      let textLength = (text as NSString).length
      let selectionStart = map["selectionStart"] as? Int ?? textLength
      let selectionEnd = map["selectionEnd"] as? Int ?? selectionStart
      applyEditingState(text: text, selectionStart: selectionStart, selectionEnd: selectionEnd)
      result(nil)
    case "focus":
      focusTextView()
      result(nil)
    case "unfocus":
      if window?.firstResponder === textView {
        window?.makeFirstResponder(nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func applyEditingState(text: String, selectionStart: Int, selectionEnd: Int) {
    let length = (text as NSString).length
    let start = max(0, min(selectionStart, length))
    let end = max(0, min(selectionEnd, length))
    suppressOutgoingEdits = true
    if textView.string != text {
      textView.string = text
    }
    textView.setSelectedRange(NSRange(location: start, length: abs(end - start)))
    suppressOutgoingEdits = false
    updatePlaceholderVisibility()
  }

  private func focusTextView() {
    window?.makeFirstResponder(textView)
  }

  private func updatePlaceholderVisibility() {
    placeholderLabel.isHidden = !textView.string.isEmpty
  }

  private func currentSelectionRange() -> NSRange {
    let selection = textView.selectedRange()
    if selection.location == NSNotFound {
      return NSRange(location: (textView.string as NSString).length, length: 0)
    }
    return selection
  }

  private func sendEditingChanged() {
    let selection = currentSelectionRange()
    channel.invokeMethod("editingChanged", arguments: [
      "text": textView.string,
      "selectionStart": selection.location,
      "selectionEnd": selection.location + selection.length
    ])
  }

  @objc
  private func handleAppDidResignActive() {
    shouldRestoreFocusAfterActivation = window?.firstResponder === textView
  }

  @objc
  private func handleAppDidBecomeActive() {
    guard shouldRestoreFocusAfterActivation else {
      return
    }
    shouldRestoreFocusAfterActivation = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
      self?.focusTextView()
    }
  }

  func textDidChange(_ notification: Notification) {
    updatePlaceholderVisibility()
    guard !suppressOutgoingEdits else {
      return
    }
    sendEditingChanged()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard !suppressOutgoingEdits else {
      return
    }
    sendEditingChanged()
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard commandSelector == #selector(NSResponder.insertNewline(_:)) ||
        commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else {
      return false
    }
    let flags = NSApp.currentEvent?.modifierFlags ?? []
    if flags.contains(.shift) {
      return false
    }
    channel.invokeMethod("submit", arguments: nil)
    return true
  }
}
