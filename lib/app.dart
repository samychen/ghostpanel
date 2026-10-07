import 'package:flutter/material.dart';

import 'screens/server_list_screen.dart';
import 'theme.dart';

class GhostPanelApp extends StatelessWidget {
  const GhostPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostPanel',
      debugShowCheckedModeBanner: false,
      theme: GhostTheme.dark(),
      home: const ServerListScreen(),
    );
  }
}
