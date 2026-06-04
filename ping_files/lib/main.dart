import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ping_files/splash_screen.dart';
import 'package:ping_files/theme/colors2.dart';

import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'package:ping_files/features/chat/pingmee_stream_chat_scope.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:giphy_get/l10n.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pingmee',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.brandGreen,
          primary: AppColors.brandGreen,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.brandGreen,
        ),
        splashColor: AppColors.brandGreen.withOpacity(.08),
        highlightColor: Colors.transparent,
        fontFamily: 'Inter',
      ),
      localizationsDelegates: [
        ...GlobalMaterialLocalizations.delegates,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GiphyGetUILocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''),
      ],
      home: CustomSplashScreen(),
      builder: (context, child) {
        return PingmeeStreamChatScope(
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
