import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../theme/app_theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isRegister = false;
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthProvider auth) async {
    FocusScope.of(context).unfocus();
    final ok = _isRegister
        ? await auth.register(
            email: _emailCtrl.text,
            password: _passCtrl.text,
            displayName: _nameCtrl.text,
          )
        : await auth.login(email: _emailCtrl.text, password: _passCtrl.text);
    if (ok && mounted) {
      // AuthGate сам переключится на MainShell по изменению isLoggedIn.
    } else if (!ok && mounted && auth.error != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(auth.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final l10n = context.l10n;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _isRegister ? l10n.authCreateAccount : l10n.authWelcomeBack,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 4),
                    Text(
                      _isRegister
                          ? l10n.authRegisterHint
                          : l10n.authLoginHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: 28),
                    if (_isRegister) ...[
                      _field(
                        controller: _nameCtrl,
                        label: l10n.nameLabel,
                        icon: Icons.person_outline_rounded,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _field(
                      controller: _emailCtrl,
                      label: 'E-mail',
                      icon: Icons.alternate_email_rounded,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    SizedBox(height: 12),
                    _field(
                      controller: _passCtrl,
                      label: l10n.password,
                      icon: Icons.lock_outline_rounded,
                      obscure: _obscure,
                      suffix: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          color: AppColors.textSecondary,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    SizedBox(height: 22),
                    SizedBox(
                      height: 50,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: AppColors.accentGradient,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: auth.loading ? null : () => _submit(auth),
                          child: auth.loading
                              ? SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: AppColors.onAccent,
                                  ),
                                )
                              : Text(
                                  _isRegister ? l10n.signUp : l10n.logIn,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.onAccent),
                                ),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    TextButton(
                      onPressed: () => setState(() => _isRegister = !_isRegister),
                      child: Text(
                        _isRegister
                            ? l10n.authHaveAccount
                            : l10n.authNoAccount,
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Переключатель языка — экран входа показывается до настроек,
            // и без него англоязычному пользователю пришлось бы сначала
            // разобраться с русским интерфейсом.
            Positioned(
              top: 4,
              right: 12,
              child: TextButton.icon(
                onPressed: () => context.read<LanguageProvider>().setLanguage(
                      l10n.language == AppLanguage.ru
                          ? AppLanguage.en
                          : AppLanguage.ru,
                    ),
                icon: Icon(Icons.language_rounded,
                    size: 18, color: AppColors.textSecondary),
                label: Text(
                  l10n.language == AppLanguage.ru
                      ? l10n.languageEn
                      : l10n.languageRu,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboardType,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.surface,
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 20),
        suffixIcon: suffix,
        labelText: label,
        labelStyle: TextStyle(color: AppColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
