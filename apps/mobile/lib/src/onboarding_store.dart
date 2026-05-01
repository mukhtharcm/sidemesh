import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the user has completed onboarding.
class OnboardingStore {
  OnboardingStore._();
  static final OnboardingStore instance = OnboardingStore._();

  static const _key = 'sidemesh_onboarding_completed_v1';
  bool? _cached;

  Future<bool> get isCompleted async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    _cached = prefs.getBool(_key) ?? false;
    return _cached!;
  }

  Future<void> markCompleted() async {
    _cached = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  Future<void> reset() async {
    _cached = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
