part of 'session_screen.dart';

class _StopAgentPill extends StatelessWidget {
  const _StopAgentPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = readableTextOn(
      colors,
      background: colors.danger,
      preferred: colors.accentOn,
    );
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
                AppIcons.stop_circle_rounded,
                size: 16,
                color: foreground,
              ),
              const SizedBox(width: 6),
              Text(
                'Stop agent',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
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
  late final TextEditingController _urlController;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _submitManual() {
    final parsed = parseBrowserPreviewTargetInput(_urlController.text);
    final candidate = parsed.candidate;
    if (candidate == null) {
      setState(() => _inputError = parsed.error ?? 'Enter a valid URL.');
      return;
    }
    Navigator.of(context).pop(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return MeshBottomSheetScaffold(
      icon: AppIcons.open_in_browser_rounded,
      title: 'Open browser',
      description: 'Enter a URL on this host, or use a detected local app.',
      maxWidth: 680,
      maxHeightFactor: 0.78,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _urlController,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onChanged: (_) {
                if (_inputError != null) {
                  setState(() => _inputError = null);
                }
              },
              onSubmitted: (_) => _submitManual(),
              decoration: InputDecoration(
                labelText: 'URL',
                hintText: 'localhost:3000 or https://example.com',
                errorText: _inputError,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tip: localhost means the machine running this session. A plain port like 3000 works too.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
            if (widget.suggestions.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Detected apps',
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
            ],
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
                  icon: const Icon(AppIcons.open_in_browser_rounded),
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
            AppIcons.open_in_browser_rounded,
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
