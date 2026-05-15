import 'package:flutter/material.dart';

class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({super.key});

  static const _toolbarHeight = 72.0;

  @override
  Size get preferredSize => const Size.fromHeight(_toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPrimary = theme.colorScheme.onPrimary;
    return AppBar(
      backgroundColor: theme.colorScheme.primary,
      foregroundColor: onPrimary,
      elevation: 0,
      toolbarHeight: _toolbarHeight,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Sciens Gimbal Controller',
            style: theme.textTheme.titleLarge?.copyWith(
              color: onPrimary,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'old glass goes digital',
            style: theme.textTheme.bodySmall?.copyWith(
              color: onPrimary.withValues(alpha: 0.75),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
