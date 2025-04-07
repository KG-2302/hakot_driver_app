import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'loadingscreen.dart'; // Make sure your file is named correctly
// No need to change the rest of your imports here

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Always show the loading screen on startup.
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hakot Driver',
      theme: ThemeData(
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: Colors.white,
      ),
      debugShowCheckedModeBanner: false,
      // Always start with the loading screen.
      home: const LoadingScreenPage(),
    );
  }
}
