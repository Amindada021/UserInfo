import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A lightweight local screen gate. This is NOT database encryption.
/// The SHA-256 comparison avoids publishing the requested PIN in plaintext.
/// A hardcoded hash in an open-source APK is still susceptible to guessing.
class AppAppearance {
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.light);
}

class PasscodeGate extends StatefulWidget {
  const PasscodeGate({super.key, required this.child});
  final Widget child;

  @override
  State<PasscodeGate> createState() => _PasscodeGateState();
}

class _PasscodeGateState extends State<PasscodeGate> {
  static const String _salt = 'userinfo-static-gate-v1|';
  static const String _pinHash =
      'bebae09c95c298af811e3e20ecbc38461a353e2071f29cc514e6accb83dc1e3c';

  final TextEditingController _pin = TextEditingController();
  bool _unlocked = false;
  int _failures = 0;
  DateTime? _lockedUntil;
  String _error = '';

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _tryUnlock() {
    final deadline = _lockedUntil;
    if (deadline != null && DateTime.now().isBefore(deadline)) {
      setState(() => _error = 'تلاش‌های زیاد؛ کمی بعد دوباره امتحان کن');
      return;
    }
    final digest = sha256.convert(utf8.encode('$_salt${_pin.text}')).toString();
    if (digest == _pinHash) {
      _pin.clear();
      setState(() {
        _unlocked = true;
        _failures = 0;
        _error = '';
      });
    } else {
      _pin.clear();
      _failures++;
      if (_failures >= 5) {
        _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
        _failures = 0;
      }
      setState(() => _error = 'رمز ورود نادرست است');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AutofillGroup(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_outline, size: 46),
                  const SizedBox(height: 16),
                  const Text('ورود به UserInfo',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                  const SizedBox(height: 12),
                  const Text('رمز محلی فقط برای قفل صفحه است؛ دیتابیس هنوز رمزگذاری نشده.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pin,
                    autofocus: true,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _tryUnlock(),
                    decoration: const InputDecoration(labelText: 'رمز ورود'),
                  ),
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(_error, style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _tryUnlock,
                    child: const Text('ورود'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
