import 'package:material_ui/material_ui.dart';

class StatusPanel extends StatelessWidget {
  const StatusPanel({super.key, required this.title, required this.message,
    this.isError = false, this.action, this.actionLabel});

  final String title;
  final String message;
  final bool isError;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = isError ? colors.error : colors.primary;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(isError ? Icons.error_outline : Icons.info_outline, color: color),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 4),
            Text(message, style: TextStyle(color: colors.onSurface)),
            if (action != null) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(onPressed: action, child: Text(actionLabel ?? 'Retry')),
            ),
          ])),
        ]),
      ),
    );
  }
}
