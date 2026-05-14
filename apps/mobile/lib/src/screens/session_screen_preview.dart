part of 'session_screen.dart';

class _StopAgentPill extends StatelessWidget {
  const _StopAgentPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.danger,
      shape: const StadiumBorder(),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.24),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.stop_circle_rounded,
                size: 16,
                color: colors.userBubbleOn,
              ),
              const SizedBox(width: 6),
              Text(
                'Stop agent',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.userBubbleOn,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewTargetPickerSheet extends StatefulWidget {
  const _PreviewTargetPickerSheet({required this.suggestions});

  final List<BrowserPreviewTargetCandidate> suggestions;

  @override
  State<_PreviewTargetPickerSheet> createState() =>
      _PreviewTargetPickerSheetState();
}

class _PreviewTargetPickerSheetState extends State<_PreviewTargetPickerSheet> {
  late final TextEditingController _portController;
  String _scheme = 'http';

  @override
  void initState() {
    super.initState();
    final initialPort = widget.suggestions.isNotEmpty
        ? widget.suggestions.first.port.toString()
        : '3000';
    if (widget.suggestions.isNotEmpty) {
      _scheme = widget.suggestions.first.scheme;
    }
    _portController = TextEditingController(text: initialPort);
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  void _submitManual() {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      showAppSnackBar(context, 'Enter a port between 1 and 65535.');
      return;
    }
    Navigator.of(context).pop(
      BrowserPreviewTargetCandidate(
        host: '127.0.0.1',
        port: port,
        scheme: _scheme,
        sourceLabel: 'Port $port',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return MeshBottomSheetScaffold(
      icon: Icons.open_in_browser_rounded,
      title: 'Open a preview',
      description:
          'Choose one of the web ports from this session, or enter one yourself.',
      maxWidth: 680,
      maxHeightFactor: 0.78,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.suggestions.isNotEmpty) ...[
              Text(
                'Detected ports',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: context.colors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              for (final suggestion in widget.suggestions)
                _PreviewSuggestionTile(
                  suggestion: suggestion,
                  onTap: () => Navigator.of(context).pop(suggestion),
                ),
              const SizedBox(height: 18),
            ],
            Text(
              'Enter a port',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.colors.textSecondary,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '3000',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment<String>(value: 'http', label: Text('HTTP')),
                    ButtonSegment<String>(value: 'https', label: Text('HTTPS')),
                  ],
                  selected: <String>{_scheme},
                  onSelectionChanged: (selection) {
                    if (selection.isEmpty) return;
                    setState(() => _scheme = selection.first);
                  },
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _submitManual,
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Open'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewSuggestionTile extends StatelessWidget {
  const _PreviewSuggestionTile({required this.suggestion, required this.onTap});

  final BrowserPreviewTargetCandidate suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MeshListRow(
        framed: true,
        tone: MeshSurfaceTone.muted,
        radius: AppRadii.control,
        onTap: onTap,
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.open_in_browser_rounded,
            size: 18,
            color: colors.accent,
          ),
        ),
        title: Text(
          suggestion.endpointLabel,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          suggestion.sourceLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
        ),
        trailing: MeshPill(
          label: suggestion.scheme.toUpperCase(),
          tone: MeshPillTone.accent,
          mono: true,
        ),
      ),
    );
  }
}
