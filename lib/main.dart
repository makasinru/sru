import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/screens/root_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  runApp(ChangeNotifierProvider.value(value: state, child: const SruApp()));
}

class SruApp extends StatelessWidget {
  const SruApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SRU VPN',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const RootScreen(),
    );
  }
}
