import 'package:flutter/material.dart';

import '../../widgets/settings_cards.dart';

/// 2026-10-03, per the user: "i dont like the design of setting screen ...
/// re-design ... make each section as card", revised same day: "dont make
/// wrapped cards. make once card, name it 'connections' ... another card
/// for theme ... another for app version" — a plain single-column stack of
/// three cards (Appearance, Connections, About), no responsive wrap.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          AppearanceCard(),
          SizedBox(height: 16),
          ConnectionsCard(),
          SizedBox(height: 16),
          BackupRestoreCard(),
          SizedBox(height: 16),
          AboutCard(),
        ],
      ),
    );
  }
}
