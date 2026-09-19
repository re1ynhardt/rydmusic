import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/language_provider.dart';
import '../providers/vk_auth_provider.dart';
import '../theme/app_theme.dart';

/// Шторка логина VK в настройках: username/password → возможные
/// промежуточные шаги (код по SMS или капча, см. [VkAuthChallenge]) →
/// залогинен. Открывается через showModalBottomSheet, как и
/// info-шторки SoundCloud/Audiomack (см. settings_screen.dart).
class VkLoginSheet extends StatefulWidget {
  const VkLoginSheet({super.key});

  @override
  State<VkLoginSheet> createState() => _VkLoginSheetState();
}

class _VkLoginSheetState extends State<VkLoginSheet> {
  final _loginCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _loginCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitLogin(VkAuthProvider auth) async {
    if (_loginCtrl.text.trim().isEmpty || _passwordCtrl.text.isEmpty) return;
    await auth.login(
      username: _loginCtrl.text.trim(),
      password: _passwordCtrl.text,
    );
  }

  Future<void> _submitCode(VkAuthProvider auth, bool isCaptcha) async {
    if (_codeCtrl.text.trim().isEmpty) return;
    final code = _codeCtrl.text.trim();
    _codeCtrl.clear();
    if (isCaptcha) {
      await auth.submitCaptcha(code);
    } else {
      await auth.submitSmsCode(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<VkAuthProvider>();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: AppColors.accentGradient,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.groups_rounded,
                      size: 18, color: AppColors.onAccent),
                ),
                const SizedBox(width: 12),
                const Text('VK',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            if (auth.initializing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (auth.isLoggedIn)
              _buildLoggedIn(auth)
            else if (auth.challenge?.needsSmsCode == true)
              _buildSmsStep(auth)
            else if (auth.challenge?.needsCaptcha == true)
              _buildCaptchaStep(auth)
            else
              _buildLoginForm(auth),
          ],
        ),
      ),
    );
  }

  Widget _buildLoggedIn(VkAuthProvider auth) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          auth.userId != null
              ? l10n.vkLoggedInWithId(auth.userId!)
              : l10n.vkLoggedInLong,
          style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => auth.logout(),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: BorderSide(color: AppColors.surfaceElevated),
              minimumSize: const Size.fromHeight(46),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(l10n.logOut),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginForm(VkAuthProvider auth) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.vkLoginInfo,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _loginCtrl,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: l10n.vkLoginLabel,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: l10n.password,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                size: 18,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          onSubmitted: (_) => _submitLogin(auth),
        ),
        if (auth.error != null) ...[
          const SizedBox(height: 10),
          Text(auth.error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: auth.loading ? null : () => _submitLogin(auth),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: auth.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(l10n.logIn),
          ),
        ),
      ],
    );
  }

  Widget _buildSmsStep(VkAuthProvider auth) {
    final l10n = context.l10n;
    final mask = auth.challenge?.phoneMask;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          mask != null
              ? l10n.vkSmsSentTo(mask)
              : l10n.vkSmsRequested,
          style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l10n.vkSmsCodeLabel),
          onSubmitted: (_) => _submitCode(auth, false),
        ),
        if (auth.error != null) ...[
          const SizedBox(height: 10),
          Text(auth.error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => auth.cancelChallenge(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: BorderSide(color: AppColors.surfaceElevated),
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(l10n.cancel),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: auth.loading ? null : () => _submitCode(auth, false),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: auth.loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(l10n.confirm),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCaptchaStep(VkAuthProvider auth) {
    final l10n = context.l10n;
    final imageUrl = auth.challenge?.captchaImageUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.vkCaptchaPrompt,
          style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 12),
        if (imageUrl != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(imageUrl, height: 60),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _codeCtrl,
          decoration: InputDecoration(labelText: l10n.vkCaptchaLabel),
          onSubmitted: (_) => _submitCode(auth, true),
        ),
        if (auth.error != null) ...[
          const SizedBox(height: 10),
          Text(auth.error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => auth.cancelChallenge(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: BorderSide(color: AppColors.surfaceElevated),
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(l10n.cancel),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: auth.loading ? null : () => _submitCode(auth, true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: auth.loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(l10n.confirm),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
