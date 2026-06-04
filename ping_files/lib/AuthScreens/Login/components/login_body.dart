import 'package:flutter/material.dart';
import 'package:ping_files/AuthScreens/Login/components/background.dart';
import 'package:ping_files/AuthScreens/ResetPassword/reset_password_screen.dart';
import 'package:ping_files/AuthScreens/Signup/components/social_icon.dart';
import 'package:ping_files/AuthScreens/Welcome/components/rounded_button.dart';
import 'package:ping_files/components/rounded_input_field.dart';
import 'package:ping_files/components/rounded_password_field.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:lottie/lottie.dart';
import 'package:ping_files/ProfileCreation/ActivationLevelZeroScreen.dart';
import 'package:ping_files/AuthScreens/Signup/signup_screen.dart';
import 'package:ping_files/main_app/main_app_shell.dart';
import 'package:flutter/services.dart';
import 'package:ping_files/services/local_account_vault.dart';


class LoginBody extends StatefulWidget {
  final bool showSavedProfilesOnOpen;

  const LoginBody({
    super.key,
    this.showSavedProfilesOnOpen = true,
  });

  @override
  State<LoginBody> createState() => _LoginBodyState();
}

class _LoginBodyState extends State<LoginBody> with TickerProviderStateMixin {
  // Controllers
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  final TextEditingController phoneUsernameController = TextEditingController();
  final TextEditingController phonePasswordController = TextEditingController();

  // State
  String email = '';
  String password = '';
  String? loginError;
  bool isLoading = false;
  bool _didPromptSavedAccounts = false;
  final bool _savedSheetDismissedForSession = false;

  List<SavedAccount> get _rememberedEmailAccounts => _savedAccounts
      .where((a) => a.type == 'email' && a.hasSavedSecret)
      .toList();

  // Firestore instance
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  late final TabController _tabController;

  List<SavedAccount> _savedAccounts = [];

  bool rememberEmailCredentials = true;
  bool rememberPhoneCredentials = false;

  

  @override
  void dispose() {
    _tabController.dispose();
    emailController.dispose();
    passwordController.dispose();
    phoneUsernameController.dispose();
    phonePasswordController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadSavedAccounts();
      if (!mounted) return;

      if (widget.showSavedProfilesOnOpen &&
          !_savedSheetShownThisSession &&
          !_savedSheetDismissedThisSession &&
          _oneTapAccounts.isNotEmpty) {
        _savedSheetShownThisSession = true;
        await _showSavedAccountsSheet();
      }
    });
  }

  bool _savedSheetShownThisSession = false;
  final bool _savedSheetDismissedThisSession = false;

  List<SavedAccount> get _oneTapAccounts => _savedAccounts
      .where((a) => a.type == 'email' && a.hasSavedSecret)
      .toList();

  Future<void> _maybePromptSavedAccounts() async {
    if (_didPromptSavedAccounts) return;
    _didPromptSavedAccounts = true;

    if (!widget.showSavedProfilesOnOpen) return;
    if (_savedSheetDismissedForSession) return;
    if (_rememberedEmailAccounts.isEmpty) return;

    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;

    await _showSavedAccountsSheet();
  }

  Future<void> _loginWithSavedAccount(SavedAccount account) async {
    final savedSecret = await LocalAccountVault.readSecret(account);

    if (savedSecret == null || savedSecret.isEmpty) {
      await LocalAccountVault.removeAccount(account);
      await _loadSavedAccounts();
      if (!mounted) return;
      return;
    }

    setState(() {
      isLoading = true;
      loginError = null;
    });

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: account.identifier,
        password: savedSecret,
      );

      await credential.user?.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (refreshedUser == null) {
        throw FirebaseAuthException(code: 'user-null', message: 'Login failed.');
      }

      if (!refreshedUser.emailVerified) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        _showEmailVerificationPopup();
        return;
      }

      final uid = refreshedUser.uid;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final data = doc.data() ?? {};

      await LocalAccountVault.saveAccount(
        uid: uid,
        type: 'email',
        identifier: account.identifier,
        fullName: (data['fullName'] ?? data['name'])?.toString(),
        username: data['username']?.toString(),
        photoUrl: (data['photoUrl'] ??
                data['profilePhotoUrl'] ??
                data['avatarUrl'])
            ?.toString(),
        secret: savedSecret,
        saveSecret: true,
      );

      final onboardingComplete = (data['onboardingComplete'] == true);
      final profileLevel = (data['profileLevel'] is num)
          ? (data['profileLevel'] as num).toInt()
          : 0;

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => (onboardingComplete || profileLevel >= 10)
              ? const MainAppShell()
              : const ActivationLevelZeroScreen(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loginError = _mapEmailAuthError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loginError = "Something went wrong. Please try again.";
      });
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  // ----------------- EMAIL LOGIN -----------------
  Future<void> _loginWithEmail() async {
    FocusScope.of(context).unfocus();

    final typedEmail = emailController.text.trim();
    final typedPassword = passwordController.text;

    if (typedEmail.isEmpty || typedPassword.isEmpty) {
      setState(() {
        loginError = "Enter both email and password.";
      });
      return;
    }

    setState(() {
      isLoading = true;
      loginError = null;
    });

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: typedEmail,
        password: typedPassword,
      );

      await credential.user?.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (refreshedUser == null) {
        if (!mounted) return;
        setState(() {
          loginError = "Login failed. Please try again.";
        });
        return;
      }

      if (!refreshedUser.emailVerified) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        _showEmailVerificationPopup();
        return;
      }

      final uid = refreshedUser.uid;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final data = doc.data() ?? {};

      await LocalAccountVault.saveAccount(
        uid: uid,
        type: 'email',
        identifier: typedEmail,
        fullName: (data['fullName'] ?? data['name'])?.toString(),
        username: data['username']?.toString(),
        photoUrl: (data['photoUrl'] ??
                data['profilePhotoUrl'] ??
                data['avatarUrl'])
            ?.toString(),
        secret: typedPassword,
        saveSecret: true,
      );

      TextInput.finishAutofillContext(
        shouldSave: rememberEmailCredentials,
      );

      final onboardingComplete = (data['onboardingComplete'] == true);
      final profileLevel = (data['profileLevel'] is num)
          ? (data['profileLevel'] as num).toInt()
          : 0;

      if (!mounted) return;

      if (onboardingComplete || profileLevel >= 10) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainAppShell()),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const ActivationLevelZeroScreen(),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loginError = _mapEmailAuthError(e);
      });
    } catch (e, st) {
      debugPrint('LOGIN ERROR: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        loginError = "Something went wrong. Please try again.";
      });
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  void _showEmailVerificationPopup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Lottie.asset("assets/images/verify.json", height: 120, repeat: true),
            const SizedBox(height: 16),
            const Text(
              "Verify Your Email",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, fontFamily: 'Poppins'),
            ),
            const SizedBox(height: 12),
            const Text(
              "A verification link was sent to your email. Please verify your account to continue.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.mediumGray, fontFamily: 'Poppins'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                "Okay",
                style: TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'Poppins'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadSavedAccounts() async {
    final loaded = await LocalAccountVault.loadAccounts();

    final remembered = loaded
        .where((a) => a.type == 'email' && a.hasSavedSecret)
        .toList();

    for (final account in remembered) {
      final needsName = account.fullName?.trim().isEmpty ?? true;
      final needsUsername = account.username?.trim().isEmpty ?? true;
      final needsPhoto = account.photoUrl?.trim().isEmpty ?? true;

      if (!(needsName || needsUsername || needsPhoto)) continue;
      if (account.uid.trim().isEmpty) continue;

      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(account.uid)
            .get();

        final data = doc.data();
        if (data == null) continue;

        await LocalAccountVault.saveAccount(
          uid: account.uid,
          type: account.type,
          identifier: account.identifier,
          fullName: (data['fullName'] ?? data['name'])?.toString(),
          username: data['username']?.toString(),
          photoUrl: (data['photoUrl'] ??
                  data['profilePhotoUrl'] ??
                  data['avatarUrl'])
              ?.toString(),
          saveSecret: null, // preserve existing saved password
        );
      } catch (_) {
        // Silent fallback. Don't break the login screen over metadata refresh.
      }
    }

    final refreshed = await LocalAccountVault.loadAccounts();

    if (!mounted) return;
    setState(() {
      _savedAccounts = refreshed
          .where((a) => a.type == 'email' && a.hasSavedSecret)
          .toList();
    });
  }

  void _setControllerText(TextEditingController controller, String value) {
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _showSavedAccountsSheet() async {
    final accounts = _oneTapAccounts; // or use _savedAccounts if that's your final list
    if (!mounted || accounts.isEmpty) return;

    final selected = await showModalBottomSheet<SavedAccount>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (sheetContext) {
        final screenHeight = MediaQuery.of(sheetContext).size.height;

        return Container(
          height: screenHeight * 0.68, // a bit above half the screen
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Log into Pingmee',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Poppins',
                  ),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Choose an account on this device',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.mediumGray,
                      fontFamily: 'Poppins',
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    itemCount: accounts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, index) {
                      final account = accounts[index];

                      final displayName =
                          (account.fullName?.trim().isNotEmpty == true)
                              ? account.fullName!.trim()
                              : account.identifier;

                      final handle =
                          (account.username?.trim().isNotEmpty == true)
                              ? '@${account.username!.trim()}'
                              : '';

                      return InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: isLoading
                            ? null
                            : () => Navigator.of(sheetContext).pop(account),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF7F8FA),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 28,
                                backgroundImage: (account.photoUrl != null &&
                                        account.photoUrl!.trim().isNotEmpty)
                                    ? NetworkImage(account.photoUrl!.trim())
                                    : null,
                                child: (account.photoUrl == null ||
                                        account.photoUrl!.trim().isEmpty)
                                    ? Text(
                                        displayName.isNotEmpty
                                            ? displayName[0].toUpperCase()
                                            : '?',
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'Poppins',
                                      ),
                                    ),
                                    if (handle.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        handle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.mediumGray,
                                          fontFamily: 'Poppins',
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFFF3F4F6),
                        foregroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: const Text(
                        'Use another account',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null) return;

    await _loginWithSavedAccount(selected);
  }

  String _mapEmailAuthError(FirebaseAuthException e) {
    switch (e.code.toLowerCase()) {
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'user-not-found':
        return 'No Pingmee account exists for that email.';
      case 'wrong-password':
        return 'That password is incorrect.';
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return 'Those credentials do not match any account.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many login attempts. Try again later.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled.';
      default:
        final msg = e.message?.trim();
        return (msg != null && msg.isNotEmpty)
            ? msg
            : 'Login failed (${e.code}).';
    }
  }

  // ----------------- PHONE LOGIN -----------------
  Future<void> _loginWithPhone() async {
    setState(() {
      isLoading = true;
      loginError = null;
    });

    try {
      final input = phoneUsernameController.text.trim();
      final password = phonePasswordController.text;

      if (input.isEmpty || password.isEmpty) {
        setState(() {
          loginError = "Enter both username/phone and password.";
          isLoading = false;
        });
        return;
      }

      // Search Firestore users by username or phone
      final queryUsername = await _firestore.collection('users').where('username', isEqualTo: input).limit(1).get();
      final queryPhone = queryUsername.docs.isEmpty
          ? await _firestore.collection('users').where('phone', isEqualTo: input).limit(1).get()
          : queryUsername;

      if (queryPhone.docs.isEmpty) {
        setState(() {
          loginError = "User not found.";
          isLoading = false;
        });
        return;
      }

      final userDoc = queryPhone.docs.first.data();
      final storedPassword = userDoc['password'] ?? '';

      if (storedPassword != password) {
        setState(() {
          loginError = "Incorrect password.";
          isLoading = false;
        });
        return;
      }

      // Success: Navigate to profile creation or home
      // Success: Navigate based on onboarding completion
      final uid = queryPhone.docs.first.id; // or userDoc['uid'] if you store it

      final doc = await _firestore.collection('users').doc(uid).get();
      final data = doc.data();

      final onboardingComplete = (data?['onboardingComplete'] == true);
      final profileLevel = (data?['profileLevel'] is num)
          ? (data!['profileLevel'] as num).toInt()
          : 0;

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => (onboardingComplete || profileLevel >= 10)
              ? const MainAppShell()
              : const ActivationLevelZeroScreen(),
        ),
      );

    } catch (e) {
      setState(() {
        loginError = "Login failed. Try again.";
      });
    } finally {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Tab>[
      const Tab(text: 'Email'),
      const Tab(text: 'Phone'),
    ];

    final size = MediaQuery.of(context).size;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Background(
        child: DefaultTabController(
          length: tabs.length,
          child: Column(
            children: [
              const SizedBox(height: 64),
              const Text(
                "Welcome Back",
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: AppColors.heading,
                ),
              ),
              const SizedBox(height: 12),
              TabBar(
                controller: _tabController,
                indicatorColor: AppColors.brandGreen,
                labelColor: AppColors.brandGreen,
                unselectedLabelColor: Colors.grey,
                tabs: tabs,
              ),

              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // ---------- EMAIL LOGIN TAB ----------
                    SingleChildScrollView(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 16),
                        child: Column(
                          children: [
                            const SizedBox(height: 16),
                            Image.asset(
                              'assets/images/loginemail.png',
                              height: size.height * 0.25,
                            ),
                            const SizedBox(height: 16),
                            AutofillGroup(
                              child: Column(
                                children: [
                                AutofillGroup(
                                  child: Column(
                              children: [
                                        RoundedInputField(
                                          controller: emailController,
                                          hintText: "Email",
                                          onChanged: (value) => setState(() => email = value),
                                          autofillHints: const [
                                            AutofillHints.email,
                                            AutofillHints.username,
                                          ],
                                          icon: Icons.email,
                                        ),
                                        const SizedBox(height: 16),
                                        RoundedPasswordField(
                                          controller: passwordController,
                                          onChanged: (value) => setState(() => password = value),
                                          autofillHints: const [AutofillHints.password],
                                        ),
                                      ],
                                    ),
                                  ),
                                  Row(
                                      children: [
                                      Checkbox(
                                        value: rememberEmailCredentials,
                                        onChanged: (v) {
                                          setState(() => rememberEmailCredentials = v ?? false);
                                        },
                                      ),
                                      const Expanded(
                                        child: Text(
                                          "Remember me on this device",
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontFamily: 'Poppins',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                            
                            if (loginError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  loginError!,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            const SizedBox(height: 24),
                            RoundedButton(
                              text: isLoading ? "Logging in..." : "Login",
                              press: isLoading ? null : _loginWithEmail,
                            ),
                            const SizedBox(height: 16),

                            // 🔹 Forgot password
                            TextButton(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const ResetPasswordScreen(),
                                ),
                              ),
                              child: const Text(
                                "Forgot Password?",
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.brandGreen,
                                ),
                              ),
                            ),

                            const SizedBox(height: 24),

                            // 🔹 Sign up prompt
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  "Don’t have an account? ",
                                  style: TextStyle(
                                    color: AppColors.brandGreen,
                                    fontSize: 14,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const SignupScreen(),
                                      ),
                                    );
                                  },
                                  child: const Text(
                                    "Sign Up",
                                    style: TextStyle(
                                      color: AppColors.brandGreen,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 20),

                            // 🔹 OR divider
                            Row(
                              children: [
                                Expanded(child: Divider()),
                                Padding(
                                  padding:
                                      EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(
                                    "OR",
                                    style: TextStyle(
                                      color: AppColors.caption,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Expanded(child: Divider()),
                              ],
                            ),

                            const SizedBox(height: 20),

                            // 🔹 Social login icons
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SocialIcon(
                                  iconSrc:
                                      "assets/icons/google-plus.svg",
                                  onPressed: () {},
                                ),
                                const SizedBox(width: 16),
                                SocialIcon(
                                  iconSrc:
                                      "assets/icons/facebook.svg",
                                  onPressed: () {},
                                ),
                                const SizedBox(width: 16),
                                SocialIcon(
                                  iconSrc:
                                      "assets/icons/linkedin.svg",
                                  onPressed: () {},
                                ),
                              ],
                            ),

                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),

                    // ---------- PHONE LOGIN TAB ----------
                    SingleChildScrollView(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 16),
                        child: Column(
                          children: [
                            const SizedBox(height: 16),
                            Image.asset(
                              'assets/images/phone.png',
                              height: size.height * 0.25,
                            ),
                            const SizedBox(height: 16),
                            RoundedInputField(
                              controller: phoneUsernameController,
                              hintText: "Username or Phone number",
                              onChanged: (_) {},
                              icon: Icons.person,
                            ),
                            const SizedBox(height: 16),
                            RoundedPasswordField(
                              controller: phonePasswordController,
                              onChanged: (_) {},
                            ),
                            if (loginError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  loginError!,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            const SizedBox(height: 24),
                            RoundedButton(
                              text:
                                  isLoading ? "Logging in..." : "Login",
                              press:
                                  isLoading ? null : _loginWithPhone,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

  }
}
