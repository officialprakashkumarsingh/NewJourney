import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Color Palette
const Color draculaBackground = Color(0xFF282A36);
const Color draculaCurrentLine = Color(0xFF44475A);
const Color draculaForeground = Color(0xFFF8F8F2);
const Color draculaComment = Color(0xFF6272A4);
const Color draculaPurple = Color(0xFFBD93F9);
const Color draculaGreen = Color(0xFF50FA7B);

class ThemeNotifier extends ChangeNotifier {
  final String key = "theme";
  SharedPreferences? _prefs;
  late ThemeMode _themeMode;

  ThemeMode get themeMode => _themeMode;

  ThemeNotifier() {
    _themeMode = ThemeMode.light;
    _loadFromPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  Future<void> _loadFromPrefs() async {
    await _initPrefs();
    bool isDarkMode = _prefs?.getBool(key) ?? false;
    _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  Future<void> _saveToPrefs() async {
    await _initPrefs();
    await _prefs?.setBool(key, _themeMode == ThemeMode.dark);
  }

  void setTheme(ThemeMode themeMode) {
    if (_themeMode == themeMode) return;
    _themeMode = themeMode;
    _saveToPrefs();
    notifyListeners();
  }

  static final ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.white,
    primaryColor: Colors.black,
    cardColor: Colors.grey[50],
    appBarTheme: AppBarTheme(
      color: Colors.white,
      elevation: 0,
      foregroundColor: Colors.black,
      surfaceTintColor: Colors.white,
      iconTheme: const IconThemeData(color: Colors.black),
      titleTextStyle: GoogleFonts.inter(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
    iconTheme: const IconThemeData(color: Colors.black54),
    dividerColor: Colors.grey.shade200,
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    )),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.black)),
    switchTheme: SwitchThemeData(
      thumbColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.selected)) {
          return Colors.green;
        }
        return null; // Uses default color
      }),
      trackColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.selected)) {
          return Colors.green.withOpacity(0.5);
        }
        return null; // Uses default color
      }),
    ),
  );

  static final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: draculaBackground,
    primaryColor: draculaForeground,
    cardColor: draculaCurrentLine,
    appBarTheme: AppBarTheme(
      color: draculaBackground,
      elevation: 0,
      foregroundColor: draculaForeground,
      surfaceTintColor: draculaBackground,
      iconTheme: const IconThemeData(color: draculaForeground),
      titleTextStyle: GoogleFonts.inter(color: draculaForeground, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme).apply(
      bodyColor: draculaForeground,
      displayColor: draculaForeground,
    ),
    iconTheme: const IconThemeData(color: draculaComment),
    dividerColor: draculaCurrentLine,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: draculaForeground,
        foregroundColor: draculaBackground,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: draculaForeground),
    ),
    dialogBackgroundColor: draculaCurrentLine,
    switchTheme: SwitchThemeData(
      thumbColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.selected)) {
          return draculaGreen;
        }
        return draculaComment;
      }),
      trackColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.selected)) {
          return draculaGreen.withOpacity(0.5);
        }
        return draculaCurrentLine;
      }),
    ),
  );
}