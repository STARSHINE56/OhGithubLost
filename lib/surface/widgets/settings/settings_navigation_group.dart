/// 设置首页统一导航：同组共享一张卡片，入口只放名称，不放长说明。
library;

import 'package:flutter/material.dart';

class OgLSettingsNavigationGroup extends StatelessWidget {
  const OgLSettingsNavigationGroup({required this.title, required this.children, super.key});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Semantics(header: true, child: Text(title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant))),
        ),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 60, endIndent: 16),
              children[i],
            ],
          ]),
        ),
      ],
    ),
  );
}

class OgLSettingsNavigationRow extends StatelessWidget {
  const OgLSettingsNavigationRow({required this.icon, required this.title,
    required this.onTap, super.key});
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 64),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      minLeadingWidth: 28,
      horizontalTitleGap: 16,
      leading: Icon(icon, size: 24),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    ),
  );
}
