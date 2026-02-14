import 'package:dart_emu_example/src/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';

/// Root application widget for the DartEMU terminal UI.
class App extends StatelessWidget {
  /// Creates the application.
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DartEMU',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const TerminalScreen(),
    );
  }
}
