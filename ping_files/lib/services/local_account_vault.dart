import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedAccount {
  final String uid;
  final String type;
  final String identifier;
  final String? fullName;
  final String? username;
  final String? photoUrl;
  final DateTime updatedAt;
  final bool hasSavedSecret;

  const SavedAccount({
    required this.uid,
    required this.type,
    required this.identifier,
    required this.updatedAt,
    this.fullName,
    this.username,
    this.photoUrl,
    this.hasSavedSecret = false,
  });

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'type': type,
        'identifier': identifier,
        'fullName': fullName,
        'username': username,
        'photoUrl': photoUrl,
        'updatedAt': updatedAt.toIso8601String(),
        'hasSavedSecret': hasSavedSecret,
      };

  factory SavedAccount.fromJson(Map<String, dynamic> json) {
    return SavedAccount(
      uid: (json['uid'] ?? '').toString(),
      type: (json['type'] ?? '').toString().trim().toLowerCase(),
      identifier: (json['identifier'] ?? '').toString().trim(),
      fullName: json['fullName']?.toString(),
      username: json['username']?.toString(),
      photoUrl: json['photoUrl']?.toString(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      hasSavedSecret: json['hasSavedSecret'] == true,
    );
  }
}

class LocalAccountVault {
  static const _prefsKey = 'pingmee_saved_accounts_v1';
  static const _secure = FlutterSecureStorage();

  static String _normalizeType(String type) {
    return type.trim().toLowerCase();
  }

  static String _normalizeIdentifier(String type, String identifier) {
    final normalizedType = _normalizeType(type);
    final value = identifier.trim();

    switch (normalizedType) {
      case 'email':
        return value.toLowerCase();

      case 'phone':
        return value.replaceAll(RegExp(r'\s+'), '');

      default:
        return value.toLowerCase();
    }
  }

  static String _secretKey(String type, String identifier) {
    final normalizedType = _normalizeType(type);
    final normalizedIdentifier = _normalizeIdentifier(type, identifier);
    return 'pingmee_secret_${normalizedType}_$normalizedIdentifier';
  }

  static Future<List<SavedAccount>> loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);

    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final accounts = decoded
          .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      accounts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return accounts;
    } catch (_) {
      await prefs.remove(_prefsKey);
      return [];
    }
  }

  static Future<void> saveAccount({
    required String uid,
    required String type,
    required String identifier,
    String? fullName,
    String? username,
    String? photoUrl,
    String? secret,
    bool? saveSecret,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await loadAccounts();

    final normalizedType = _normalizeType(type);
    final normalizedIdentifier = _normalizeIdentifier(type, identifier);

    SavedAccount? existing;
    for (final account in accounts) {
      if (account.type == normalizedType &&
          account.identifier == normalizedIdentifier) {
        existing = account;
        break;
      }
    }

    accounts.removeWhere(
      (a) => a.type == normalizedType && a.identifier == normalizedIdentifier,
    );

    final nextHasSavedSecret = saveSecret == null
        ? (existing?.hasSavedSecret ?? false)
        : (saveSecret && (secret?.isNotEmpty ?? false));

    accounts.insert(
      0,
      SavedAccount(
        uid: uid.trim().isNotEmpty ? uid.trim() : (existing?.uid ?? ''),
        type: normalizedType,
        identifier: normalizedIdentifier,
        fullName: (fullName != null && fullName.trim().isNotEmpty)
            ? fullName.trim()
            : existing?.fullName,
        username: (username != null && username.trim().isNotEmpty)
            ? username.trim()
            : existing?.username,
        photoUrl: (photoUrl != null && photoUrl.trim().isNotEmpty)
            ? photoUrl.trim()
            : existing?.photoUrl,
        updatedAt: DateTime.now(),
        hasSavedSecret: nextHasSavedSecret,
      ),
    );

    final trimmed = accounts.take(10).toList();

    await prefs.setString(
      _prefsKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );

    final key = _secretKey(normalizedType, normalizedIdentifier);

    try {
      if (saveSecret == null) {
        return; // leave secure storage untouched
      }

      if (saveSecret && secret != null && secret.isNotEmpty) {
        await _secure.write(key: key, value: secret);
      } else {
        await _secure.delete(key: key);
      }
    } catch (e) {
      debugPrint('SECURE STORAGE WRITE FAILED: $e');
    }
  }

  static Future<String?> readSecret(SavedAccount account) async {
    try {
      return await _secure.read(
        key: _secretKey(account.type, account.identifier),
      );
    } catch (e) {
      debugPrint('SECURE STORAGE READ FAILED: $e');
      return null;
    }
  }

  static Future<void> removeAccount(SavedAccount account) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await loadAccounts();

    final normalizedType = _normalizeType(account.type);
    final normalizedIdentifier =
        _normalizeIdentifier(account.type, account.identifier);

    accounts.removeWhere(
      (a) => a.type == normalizedType && a.identifier == normalizedIdentifier,
    );

    await prefs.setString(
      _prefsKey,
      jsonEncode(accounts.map((e) => e.toJson()).toList()),
    );

    try {
      await _secure.delete(
        key: _secretKey(account.type, account.identifier),
      );
    } catch (e) {
      debugPrint('SECURE STORAGE DELETE FAILED: $e');
    }
  }
}