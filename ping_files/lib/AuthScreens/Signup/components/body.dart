// import statements (keep your existing ones and add Firestore)
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:ping_files/AuthScreens/Login/components/login_body.dart';
import 'package:ping_files/AuthScreens/Signup/components/or_divider.dart';
import 'package:ping_files/AuthScreens/Signup/components/social_icon.dart';
import 'package:ping_files/components/already_have_an_account_check.dart';
import 'package:ping_files/components/rounded_input_field.dart';
import 'package:ping_files/components/rounded_password_field.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/AuthScreens/Welcome/components/rounded_button.dart';
import 'package:lottie/lottie.dart';
import 'package:ping_files/AuthScreens/Login/components/background.dart';

class SignUpBody extends StatefulWidget {
  const SignUpBody({super.key, required this.child});
  final Widget child;

  @override
  State<SignUpBody> createState() => _SignUpBodyState();
}

class _SignUpBodyState extends State<SignUpBody> with TickerProviderStateMixin {
  // Email sign-up fields (same as before)
  String email = '';
  String password = '';
  String? errorMessage;
  bool isLoading = false;

  final passwordCriteria = {
    'Lowercase letter': (String p) => RegExp(r'[a-z]').hasMatch(p),
    'Uppercase letter': (String p) => RegExp(r'[A-Z]').hasMatch(p),
    'Number': (String p) => RegExp(r'\d').hasMatch(p),
    'Symbol': (String p) => RegExp(r'[!@#\$&*~.,;:?%^()_+=|<>/-]').hasMatch(p),
    '8+ characters': (String p) => p.length >= 8,
  };

  // Phone sign-up fields
  final TextEditingController phoneController = TextEditingController();
  String selectedCountryCode = '+260'; // default to Zambia
  bool sendingOtp = false;

  String? _verificationId;
  bool otpInProgress = false;

  // Firestore instance
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    final tabs = <Tab>[
      const Tab(text: 'Email'),
      const Tab(text: 'Phone'),
    ];

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Background(
        child: DefaultTabController(
          length: tabs.length,
          child: Column(
            children: [
              const SizedBox(height: 64),
              const Text(
                "Sign up",
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: AppColors.heading,
                ),
              ),
              const SizedBox(height: 12),
              TabBar(
                indicatorColor: AppColors.brandGreen,
                labelColor: AppColors.brandGreen,
                unselectedLabelColor: Colors.grey,
                tabs: tabs,
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    // ---------- Tab 1: Email signup (your existing UI) ----------
                    SingleChildScrollView(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const SizedBox(height: 8),
                            Image.asset(
                              'assets/images/signupemail.png',
                              height: size.height * 0.25,
                            ),
                            const SizedBox(height: 16),
                            RoundedInputField(
                              controller: emailController,
                              hintText: "Email",
                              onChanged: (value) => setState(() => email = value),
                              autofillHints: const [AutofillHints.email, AutofillHints.username],
                              icon: Icons.email,
                            ),

                            const SizedBox(height: 16),

                            RoundedPasswordField(
                              controller: passwordController,
                              onChanged: (value) => setState(() => password = value),
                              autofillHints: const [AutofillHints.newPassword],
                            ),
                            const SizedBox(height: 16),
                            _buildPasswordHint(),
                            const SizedBox(height: 16),
                            _buildPasswordBar(),
                            if (errorMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  errorMessage!,
                                  style: const TextStyle(color: Colors.red, fontSize: 14),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            const SizedBox(height: 20),
                            RoundedButton(
                              text: isLoading ? "Signing Up..." : "Sign Up",
                              press: isLoading ? null : () => _signUpUser(context),
                            ),
                            const SizedBox(height: 16),
                            AlreadyHaveAnAccountCheck(
                              login: false,
                              onPress: () => Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(builder: (_) => const LoginScreen()),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const OrDivider(),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SocialIcon(
                                  iconSrc: "assets/icons/facebook.svg",
                                  onPressed: () {},
                                ),
                                SocialIcon(
                                  iconSrc: "assets/icons/google-plus.svg",
                                  onPressed: () {},
                                ),
                                SocialIcon(
                                  iconSrc: "assets/icons/linkedin.svg",
                                  onPressed: () {},
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),

                    // ---------- Tab 2: Phone signup ----------
                    SingleChildScrollView(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Image.asset(
                              'assets/images/phone.png',
                              height: size.height * 0.25,
                            ),
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                "Enter your phone number",
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.mediumGray,
                                  fontFamily: 'Poppins',
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Country code + phone input row
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.grey.shade300),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: selectedCountryCode,
                                      items: <String>['+260', '+27', '+1', '+44', '+233']
                                          .map((code) => DropdownMenuItem(
                                                value: code,
                                                child: Text(code, style: const TextStyle(fontSize: 14)),
                                              ))
                                          .toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() => selectedCountryCode = val);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextField(
                                    controller: phoneController,
                                    keyboardType: TextInputType.phone,
                                    decoration: InputDecoration(
                                      hintText: '7xx xxx xxx',
                                      border: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(8)),
                                        borderSide: BorderSide.none,
                                      ),
                                      filled: true,
                                      fillColor: AppColors.inputFill,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 20),

                            RoundedButton(
                              text: sendingOtp ? "Sending OTP..." : "Send OTP",
                              press: sendingOtp ? null : () => _startPhoneSignUpFlow(context),
                            ),

                            const SizedBox(height: 16),
                            Text(
                              "You'll receive a 6-digit code. Standard SMS rates may apply.",
                              style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
                              textAlign: TextAlign.center,
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

  // --------------------------
  // Email signup existing code (unchanged)
  // --------------------------
  Widget _buildPasswordHint() {
    final unmet =
        passwordCriteria.entries.where((entry) => !entry.value(password)).map((entry) => entry.key).toList();

    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        unmet.isEmpty ? "Great password" : "Include: ${unmet.join(', ')}",
        style: const TextStyle(
          fontSize: 12,
          color: AppColors.mediumGray,
          fontFamily: 'Poppins',
        ),
      ),
    );
  }

  Widget _buildPasswordBar() {
    final total = passwordCriteria.length;
    final passed = passwordCriteria.values.where((check) => check(password)).length;

    return Container(
      height: 12,
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: List.generate(total, (i) {
          final isPassed = i < passed;
          return Expanded(
            child: Container(
              margin: EdgeInsets.only(right: i == total - 1 ? 0 : 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: isPassed
                    ? LinearGradient(
                        colors: [
                          AppColors.brandGreen,
                          AppColors.brandGreen.withOpacity(0.8),
                        ],
                      )
                    : const LinearGradient(
                        colors: [Colors.grey, Colors.grey],
                      ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Future<void> _signUpUser(BuildContext context) async {
    final typedEmail = emailController.text.trim();
    final typedPassword = passwordController.text;

    setState(() {
      errorMessage = null;
      isLoading = true;
    });

    final valid = passwordCriteria.values.every((check) => check(typedPassword));

    if (typedEmail.isEmpty || typedPassword.isEmpty) {
      setState(() {
        errorMessage = "Enter both email and password.";
        isLoading = false;
      });
      return;
    }

    if (!valid) {
      setState(() {
        errorMessage = "Please complete all password requirements.";
        isLoading = false;
      });
      return;
    }

    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: typedEmail,
        password: typedPassword,
      );

      final user = cred.user;
      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-null',
          message: 'User creation failed.',
        );
      }

      // Use default verification email for now.
      await user.sendEmailVerification();

      // Critical: stop auth-listener hijack.
      await FirebaseAuth.instance.signOut();

      if (!mounted) return;

      _showVerificationPopup();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.code.toLowerCase()) {
          case 'email-already-in-use':
            errorMessage = "That email is already in use.";
            break;
          case 'invalid-email':
            errorMessage = "That email address is not valid.";
            break;
          case 'weak-password':
            errorMessage = "That password is too weak.";
            break;
          case 'operation-not-allowed':
            errorMessage = "Email/password sign-up is not enabled.";
            break;
          case 'network-request-failed':
            errorMessage = "Network error. Check your connection.";
            break;
          default:
            errorMessage = e.message?.trim().isNotEmpty == true
                ? e.message!
                : "Signup failed (${e.code}).";
        }
      });
    } catch (e, st) {
        debugPrint('SIGNUP ERROR: $e');
        debugPrintStack(stackTrace: st);

        if (!mounted) return;
        setState(() {
          errorMessage = "Something went wrong. Please try again.";
        });
      } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  void _showVerificationPopup() {
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
            Lottie.asset(
              "assets/images/email-sent.json",
              height: 120,
              repeat: true,
              animate: true,
            ),
            const SizedBox(height: 16),
            const Text(
              "Verification Link Sent!",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                fontFamily: 'Poppins',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "Please verify your account through the link sent to your email.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.mediumGray,
                fontFamily: 'Poppins',
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LoginScreen(showSavedProfilesOnOpen: false),
                  ),
                );
              },
              child: const Text(
                "Okay",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: 'Poppins',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------
  // PHONE SIGN-UP FLOW
  // --------------------------
  Future<void> _startPhoneSignUpFlow(BuildContext context) async {
    final raw = phoneController.text.trim();
    if (raw.isEmpty) {
      _showSnack("Please enter your phone number");
      return;
    }

    final fullNumber = selectedCountryCode + raw.replaceAll(RegExp(r'\s+'), '');
    setState(() => sendingOtp = true);

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: fullNumber,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Auto-retrieval or instant verification
          try {
            await FirebaseAuth.instance.signInWithCredential(credential);
            // proceed to collect username
            _showUsernameModal(context);
          } catch (e) {
            _showSnack("Automatic verification failed.");
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          _showSnack("Verification failed: ${e.message}");
        },
        codeSent: (String verificationId, int? resendToken) {
          setState(() {
            _verificationId = verificationId;
            sendingOtp = false;
          });
          // show OTP modal
          _showOtpModal(context);
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
        timeout: const Duration(seconds: 60),
      );
    } catch (e) {
      _showSnack("Failed to send OTP. ${e.toString()}");
      setState(() => sendingOtp = false);
    }
  }

  void _showSnack(String msg) {
    final sc = ScaffoldMessenger.of(context);
    sc.hideCurrentSnackBar();
    sc.showSnackBar(SnackBar(content: Text(msg)));
  }

  // OTP modal bottom sheet
  void _showOtpModal(BuildContext ctx) {
    final otpController = TextEditingController();

    showModalBottomSheet(
      context: ctx,
      isDismissible: false,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Enter verification code",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                "We sent a 6-digit code to your phone.",
                style: TextStyle(color: AppColors.mediumGray),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: otpController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: "6-digit code"),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.brandGreen),
                onPressed: () async {
                  final code = otpController.text.trim();
                  if (code.length < 4) {
                    _showSnack("Enter the 6-digit code");
                    return;
                  }
                  Navigator.of(context).pop(); // close OTP modal
                  await _verifyOtpAndSignIn(code, ctx);
                },
                child: const Text("Verify"),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  // Optionally allow resend by calling _startPhoneSignUpFlow again
                },
                child: const Text("Cancel"),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _verifyOtpAndSignIn(String code, BuildContext ctx) async {
    setState(() => otpInProgress = true);
    try {
      if (_verificationId == null) {
        _showSnack("Verification id missing. Try again.");
        setState(() => otpInProgress = false);
        return;
      }

      final credential = PhoneAuthProvider.credential(verificationId: _verificationId!, smsCode: code);

      final result = await FirebaseAuth.instance.signInWithCredential(credential);

      if (result.user != null) {
        // Signed in successfully with phone -> ask for username to finish profile
        await _showUsernameModal(ctx);
      } else {
        _showSnack("Sign-in failed.");
      }
    } on FirebaseAuthException catch (e) {
      _showSnack("Verification failed: ${e.message}");
    } catch (e) {
      _showSnack("Verification failed. Try again.");
    } finally {
      setState(() => otpInProgress = false);
    }
  }

  // Username modal bottom sheet
  Future<void> _showUsernameModal(BuildContext ctx) async {
  final usernameController = TextEditingController();
  final pwController = TextEditingController();

  await showModalBottomSheet(
    context: ctx,
    isDismissible: false,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Create your profile",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),

            // Use your RoundedInputField (already imported)
            RoundedInputField(
              hintText: "Choose a username",
              controller: usernameController,
              onChanged: (v) {},
              icon: Icons.person,
            ),
            const SizedBox(height: 12),

            // Use your existing RoundedPasswordField with eye toggle
            RoundedPasswordField(
              controller: pwController,
              autofillHints: const [AutofillHints.newPassword],
              onChanged: (value) {},
            ),
            const SizedBox(height: 20),

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                minimumSize: const Size(double.infinity, 48),
              ),
              onPressed: () async {
                final username = usernameController.text.trim();
                if (username.isEmpty) {
                  _showSnack("Please choose a username");
                  return;
                }

                Navigator.of(context).pop();
                await _finalizePhoneSignup(username);
              },
              child: const Text(
                "Create Account",
                style: TextStyle(color: Colors.white),
              ),
            ),

            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
          ],
        ),
      );
    },
  );
}


  // Store username in Firestore and redirect to login
  Future<void> _finalizePhoneSignup(String username) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack("No authenticated user. Try again.");
      return;
    }

    final uid = user.uid;
    final phone = user.phoneNumber ?? (selectedCountryCode + phoneController.text.trim());

    // Check username uniqueness
    final existing = await _firestore.collection('users').where('username', isEqualTo: username).limit(1).get();
    if (existing.docs.isNotEmpty) {
      _showSnack("Username already taken. Pick another.");
      return;
    }

    // Save profile
    await _firestore.collection('users').doc(uid).set({
      'uid': uid,
      'username': username,
      'phone': phone,
      'photoUrl': null,
      'bio': '',
      'interests': [],
      'createdAt': FieldValue.serverTimestamp(),
      'authProvider': 'phone',
    }, SetOptions(merge: true));

    // Sign out the phone session so user will log in through the Login screen (Phone tab) next
    await FirebaseAuth.instance.signOut();

    // Redirect to login screen
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
      _showSnack("Account created. Please log in with Phone tab.");
    }
  }
}

class LoginScreen extends StatelessWidget {
  final bool showSavedProfilesOnOpen;

  const LoginScreen({
    super.key,
    this.showSavedProfilesOnOpen = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LoginBody(showSavedProfilesOnOpen: showSavedProfilesOnOpen),
    );
  }
}

