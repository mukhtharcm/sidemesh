import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'src/screens/home_screen.dart';

void main() {
  runApp(const SidemeshApp());
}

class SidemeshApp extends StatelessWidget {
  const SidemeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFCA6B1F),
        brightness: Brightness.light,
        surface: const Color(0xFFFFF8EF),
      ),
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'Sidemesh',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF3E7D5),
        textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme),
        appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: const Color(0xFFF3E7D5),
          foregroundColor: const Color(0xFF221C15),
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFFFFFBF5),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
            side: BorderSide(color: Color(0x14000000)),
          ),
        ),
        navigationBarTheme: base.navigationBarTheme.copyWith(
          backgroundColor: const Color(0xFFFFFBF5),
          indicatorColor: const Color(0xFFEBC8A1),
          labelTextStyle: WidgetStateProperty.all(
            GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const SidemeshHomeScreen(),
    );
  }
}
