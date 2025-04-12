import 'package:attendance_app/screens/home_screen.dart'; // Import HomeScreen
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized(); // Ensure bindings are initialized
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Attendance App', // Updated title
      theme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: Colors.blue), // Changed theme color
        useMaterial3: true,
        visualDensity: VisualDensity
            .adaptivePlatformDensity, // Added for better cross-platform look
      ),
      home: const HomeScreen(), // Set HomeScreen as home
    );
  }
}

// Removed the default MyHomePage and _MyHomePageState widgets
