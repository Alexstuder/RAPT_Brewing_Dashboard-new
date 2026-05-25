import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _isSignup = false;
  bool _isBusy = false;
  bool _passwordVisible = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      final auth = Supabase.instance.client.auth;
      final email = _emailCtrl.text.trim();
      final password = _passwordCtrl.text;
      if (_isSignup) {
        await auth.signUp(email: email, password: password);
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.water_drop_outlined,
                        size: 64,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'RAPT Brewing Dashboard',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isSignup ? 'Konto erstellen' : 'Anmelden',
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _emailCtrl,
                        decoration: const InputDecoration(
                          labelText: 'E-Mail',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        autocorrect: false,
                        enableSuggestions: false,
                        onFieldSubmitted: (_) {
                          FocusScope.of(context).requestFocus(_passwordFocus);
                        },
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return 'E-Mail erforderlich';
                          if (!value.contains('@')) return 'Ungültige E-Mail';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordCtrl,
                        focusNode: _passwordFocus,
                        decoration: InputDecoration(
                          labelText: 'Passwort',
                          prefixIcon: const Icon(Icons.lock_outlined),
                          suffixIcon: Semantics(
                            label: _passwordVisible
                                ? 'Passwort verbergen'
                                : 'Passwort anzeigen',
                            button: true,
                            child: IconButton(
                              icon: Icon(
                                _passwordVisible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              onPressed: () => setState(
                                () => _passwordVisible = !_passwordVisible,
                              ),
                            ),
                          ),
                        ),
                        obscureText: !_passwordVisible,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return 'Passwort erforderlich';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.redAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton(
                          onPressed: _isBusy ? null : _submit,
                          child: _isBusy
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _isSignup ? 'Registrieren' : 'Anmelden',
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _isBusy
                            ? null
                            : () => setState(() {
                                  _isSignup = !_isSignup;
                                  _error = null;
                                }),
                        // #60A5FA on dark scaffold: ~6.6:1 — WCAG AA body text
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF60A5FA),
                        ),
                        child: Text(
                          _isSignup
                              ? 'Schon ein Konto? Anmelden'
                              : 'Noch kein Konto? Registrieren',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
