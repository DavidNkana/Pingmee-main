import 'package:flutter/material.dart';

class CreatePingDraft {
  final TextEditingController titleCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController customCategoryCtrl = TextEditingController();
  final TextEditingController tagCtrl = TextEditingController();
  final TextEditingController meetingPointCtrl = TextEditingController();
  final TextEditingController maxMembersCtrl = TextEditingController();

  String? category;
  bool categoryIsCustom = false;
  bool requiresApproval = false;
  final List<String> tags = [];

  String privacy = "public";
  int accuracyMode = 1;
  int durationMinutes = 1440;
  bool startNow = true;

  DateTime? scheduledDate = DateTime.now();
  TimeOfDay? scheduledStartTime = const TimeOfDay(hour: 11, minute: 30);
  TimeOfDay? scheduledEndTime = const TimeOfDay(hour: 14, minute: 0);

  void clear() {
    titleCtrl.clear();
    descCtrl.clear();
    customCategoryCtrl.clear();
    tagCtrl.clear();
    meetingPointCtrl.clear();

    category = null;
    categoryIsCustom = false;
    tags.clear();

    privacy = "public";
    accuracyMode = 1;
    durationMinutes = 60;
    startNow = true;

    scheduledDate = DateTime.now();
    scheduledStartTime = const TimeOfDay(hour: 11, minute: 30);
    scheduledEndTime = const TimeOfDay(hour: 14, minute: 0);

    requiresApproval = false;
    maxMembersCtrl.clear();
  }

  void dispose() {
    titleCtrl.dispose();
    descCtrl.dispose();
    customCategoryCtrl.dispose();
    tagCtrl.dispose();
    meetingPointCtrl.dispose();
    maxMembersCtrl.dispose();
  }
}
