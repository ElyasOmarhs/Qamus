import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:qamus/src/data/dictionary.dart';
import 'package:qamus/src/data/notifications.dart';
import 'package:qamus/src/data/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class _Dictionary extends Fake implements Dictionary {
  @override
  Featured wordOfDay(DateTime day) =>
      const Featured(key: 'علم', word: 'عِلْم', bookId: 1, preview: 'المعرفة');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const timezoneChannel = MethodChannel('flutter_timezone');
  final calls = <MethodCall>[];
  var granted = true;
  var deviceZone = 'Asia/Kabul';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.UTC);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    granted = true;
    deviceZone = 'Asia/Kabul';
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
        case 'openAppNotificationSettings':
          return true;
        case 'requestNotificationsPermission':
          return granted;
        case 'areNotificationsEnabled':
          return granted;
        case 'cancel':
        case 'zonedSchedule':
          return null;
        default:
          throw StateError('Unexpected platform call: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(
      timezoneChannel,
      (call) async => deviceZone,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(timezoneChannel, null);
  });

  test(
    'Android consent asks for notifications without opening alarm settings',
    () async {
      final notifications = WordNotifications();
      expect(await notifications.requestPermission(), isTrue);
      expect(calls.map((c) => c.method), [
        'initialize',
        'requestNotificationsPermission',
      ]);
      granted = false;
      expect(await notifications.requestPermission(), isFalse);
    },
  );

  test(
    'blocked notifications open app notification settings, not alarms',
    () async {
      final notifications = WordNotifications();
      expect(await notifications.openSettings(), isTrue);
      expect(calls.map((c) => c.method), [
        'initialize',
        'openAppNotificationSettings',
      ]);
    },
  );

  test('08:00 Kabul is 03:30 UTC, with seven future local slots', () {
    final now = tz.TZDateTime(tz.getLocation('Asia/Kabul'), 2026, 9, 12, 7);
    final times = dailyWordTimes(now, 8);
    expect(times, hasLength(7));
    expect(times.first.toUtc(), DateTime.utc(2026, 9, 12, 3, 30));
    expect(times.every((t) => t.hour == 8 && t.minute == 0), isTrue);
    final after = dailyWordTimes(
      tz.TZDateTime(now.location, 2026, 9, 12, 8),
      8,
    );
    expect(after.first.day, 13);
    expect(
      dailyWordTimes(now, 20).first.toUtc(),
      DateTime.utc(2026, 9, 12, 15, 30),
    );
  });

  test(
    'calendar scheduling preserves 08:00 across daylight saving changes',
    () {
      final zone = tz.getLocation('America/New_York');
      final spring = dailyWordTimes(tz.TZDateTime(zone, 2026, 3, 7, 7), 8);
      expect(spring.every((t) => t.hour == 8), isTrue);
      expect(spring[1].difference(spring[0]), const Duration(hours: 23));
      final fall = dailyWordTimes(tz.TZDateTime(zone, 2026, 10, 31, 7), 8);
      expect(fall.every((t) => t.hour == 8), isTrue);
      expect(fall[1].difference(fall[0]), const Duration(hours: 25));
    },
  );

  test(
    'rebuild reads device zone, replaces seven alarms, and disabling cancels',
    () async {
      final notifications = WordNotifications();
      final settings = await Settings.load([1]);
      await settings.setDailyWord(true);
      await settings.setDailyWordHour(8);
      await notifications.reschedule(
        dictionary: _Dictionary(),
        settings: settings,
      );
      var scheduled = calls.where((c) => c.method == 'zonedSchedule').toList();
      expect(scheduled, hasLength(7));
      for (final call in scheduled) {
        final args = call.arguments as Map;
        expect(args['timeZoneName'], 'Asia/Kabul');
        expect(DateTime.parse(args['scheduledDateTime'] as String).hour, 8);
        expect(
          (args['platformSpecifics'] as Map)['scheduleMode'],
          'inexactAllowWhileIdle',
        );
      }
      deviceZone = 'Europe/London';
      calls.clear();
      await notifications.reschedule(
        dictionary: _Dictionary(),
        settings: settings,
      );
      scheduled = calls.where((c) => c.method == 'zonedSchedule').toList();
      expect(scheduled, hasLength(7));
      expect(
        (scheduled.first.arguments as Map)['timeZoneName'],
        'Europe/London',
      );
      expect(calls.take(7).every((c) => c.method == 'cancel'), isTrue);
      calls.clear();
      await settings.setDailyWord(false);
      await notifications.reschedule(
        dictionary: _Dictionary(),
        settings: settings,
      );
      expect(calls.where((c) => c.method == 'cancel'), hasLength(7));
      expect(calls.where((c) => c.method == 'zonedSchedule'), isEmpty);
    },
  );
}
