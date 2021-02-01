/*
 *   Famedly
 *   Copyright (C) 2020, 2021 Famedly GmbH
 *   Copyright (C) 2021 Fluffychat
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'dart:convert';

import 'package:famedlysdk/famedlysdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_html/prefer_universal/html.dart' as darthtml;

import 'package:flutter_gen/gen_l10n/l10n.dart';
import 'package:flutter_gen/gen_l10n/l10n_en.dart';
import 'background_push_plugin.dart';
import '../platform_infos.dart';
import '../../components/matrix.dart';
import '../matrix_locals.dart';
import '../../app_config.dart';
import '../famedlysdk_store.dart';
import '../../config/setting_keys.dart';

class LocalNotificationPlugin {
  Client client;
  L10n l10n;
  Future<void> loadLocale() async {
    // inspired by _lookupL10n in .dart_tool/flutter_gen/gen_l10n/l10n.dart
    l10n ??=
        matrix?.l10n ?? (await L10n.delegate.load(window.locale)) ?? L10nEn();
  }

  Future<void> _initNotifications;
  bool reinited = false;
  MatrixState matrix;

  LocalNotificationPlugin._(this.client) {
    Logs().v('[Notify] setup');
    onSync ??= client.onSync.stream.listen((r) => update());
    onEvent ??= client.onEvent.stream.listen((e) => event(e));
    onPreNotify ??= BackgroundPushPlugin.clientOnly(client)
        .onPreNotify
        .stream
        .listen(preNotify);
    if (kIsWeb) {
      onFocusSub = darthtml.window.onFocus.listen((_) => webHasFocus = true);
      onBlurSub = darthtml.window.onBlur.listen((_) => webHasFocus = false);
    }

    _initNotifications = kIsWeb
        ? registerDesktopNotifications()
        : _flutterLocalNotificationsPlugin.initialize(
            InitializationSettings(
              android: AndroidInitializationSettings('notifications_icon'),
              iOS: IOSInitializationSettings(
                // constructor is called early (before runApp),
                // so don't request permissions here.
                requestAlertPermission: false,
                requestBadgePermission: false,
                requestSoundPermission: false,
              ),
            ),
          );

    _initNotifications.then((_) => update());
  }

  static LocalNotificationPlugin _instance;
  factory LocalNotificationPlugin.clientOnly(Client client) {
    _instance ??= LocalNotificationPlugin._(client);
    return _instance;
  }

  factory LocalNotificationPlugin(MatrixState matrix) {
    _instance ??= LocalNotificationPlugin._(matrix.client);
    _instance.matrix = matrix;
    return _instance;
  }

  void update() {
    // print('[Notify] updating');
    client.rooms.forEach((r) async {
      try {
        await _notification(r);
      } catch (e, s) {
        Logs().e('[Notify] Error processing update', e, s);
      }
    });
  }

  void reinit() {
    if (reinited == true) {
      return;
    }
    Logs().v('[Notify] reinit');
    _initNotifications = _flutterLocalNotificationsPlugin?.initialize(
        InitializationSettings(
          android: AndroidInitializationSettings('notifications_icon'),
          iOS: IOSInitializationSettings(),
        ), onSelectNotification: (String payload) async {
      Logs().v('[Notify] Selected: $payload');
      _openRoom(payload);
      return null;
    });
    reinited = true;
  }

  void event(EventUpdate e) {
    notYetLoaded[e.roomID]?.removeWhere((x) => x == e.content['event_id']);
    dirtyRoomIds.add(e.roomID);
  }

  Map<String, Set<String>> notYetLoaded = {};

  /// Rooms that has been changed since app start
  final dirtyRoomIds = <String>{};

  void preNotify(PreNotify pn) {
    final r = client.getRoomById(pn.roomId);
    if (r == null) return;
    notYetLoaded[pn.roomId] ??= {};
    notYetLoaded[pn.roomId].add(pn.eventId);
    dirtyRoomIds.add(pn.roomId);
    _notification(r);
  }

  final _flutterLocalNotificationsPlugin =
      kIsWeb ? null : FlutterLocalNotificationsPlugin();

  StreamSubscription<SyncUpdate> onSync;
  StreamSubscription<EventUpdate> onEvent;
  StreamSubscription<PreNotify> onPreNotify;

  final roomEvent = <String, String>{};

  void _openRoom(String roomId) async {
    if (matrix == null) {
      return;
    }
    await matrix.widget.apl.currentState
        .pushNamedAndRemoveUntilIsFirst('/rooms/$roomId');
  }

  Future<dynamic> _notification(Room room) async {
    await _initNotifications;

    final dirty = dirtyRoomIds.remove(room.id);

    final notYet = notYetLoaded[room.id]?.length ?? 0;
    if (notYet == 0 &&
        room.notificationCount == 0 &&
        room.membership != Membership.invite) {
      if (!roomEvent.containsKey(room.id) || roomEvent[room.id] != null) {
        Logs().v('[Notify] clearing ' + room.id);
        roomEvent[room.id] = null;
        final id = await mapRoomIdToInt(room.id);
        await _flutterLocalNotificationsPlugin?.cancel(id);
      }
      return;
    }

    final event = notYet == 0 ? room.lastEvent : null;
    final eventId = event?.eventId ??
        (room.membership == Membership.invite ? 'invite' : '');
    if (roomEvent[room.id] == eventId) {
      return;
    }

    if (webHasFocus && room.id == matrix?.activeRoomId) {
      return;
    }

    await loadLocale();

    // Calculate the body
    final body = room.membership == Membership.invite
        ? l10n.youAreInvitedToThisChat
        : event?.getLocalizedBody(
              MatrixLocals(l10n),
              withSenderNamePrefix: !room.isDirectChat ||
                  room.lastEvent.senderId == client.userID,
              hideReply: true,
            ) ??
            l10n.unreadMessages(room.notificationCount);

    Logs().v('[Notify] showing ' + room.id);
    roomEvent[room.id] = eventId;

    // Show notification
    if (_flutterLocalNotificationsPlugin != null) {
      // The person object for the android message style notification
      final person = Person(
        name: room.getLocalizedDisplayname(MatrixLocals(l10n)),
        icon: room.avatar == null || room.avatar.toString().isEmpty
            ? null
            : BitmapFilePathAndroidIcon(
                await downloadAndSaveAvatar(
                  room.avatar,
                  client,
                  width: 126,
                  height: 126,
                ),
              ),
      );
      var androidPlatformChannelSpecifics = AndroidNotificationDetails(
          AppConfig.pushNotificationsChannelId,
          AppConfig.pushNotificationsChannelName,
          AppConfig.pushNotificationsChannelDescription,
          styleInformation: MessagingStyleInformation(
            person,
            messages: [
              Message(
                body,
                event?.originServerTs ?? DateTime.now(),
                person,
              )
            ],
          ),
          importance: Importance.max,
          priority: Priority.high,
          when: event?.originServerTs?.millisecondsSinceEpoch,
          onlyAlertOnce: !dirty);
      var iOSPlatformChannelSpecifics = IOSNotificationDetails();
      var platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: iOSPlatformChannelSpecifics,
      );
      final id = await mapRoomIdToInt(room.id);
      await _flutterLocalNotificationsPlugin.show(
        id,
        room.getLocalizedDisplayname(MatrixLocals(l10n)),
        body,
        platformChannelSpecifics,
        payload: room.id,
      );
    } else if (PlatformInfos.isWeb) {
      sendDesktopNotification(
        room.getLocalizedDisplayname(MatrixLocals(l10n)),
        body,
        roomId: room.id,
        icon: event?.sender?.avatarUrl?.getThumbnail(client,
                width: 64, height: 64, method: ThumbnailMethod.crop) ??
            room?.avatar?.getThumbnail(client,
                width: 64, height: 64, method: ThumbnailMethod.crop),
      );
    } else {
      Logs().w('No platform support for notifications');
    }
  }

  static Future<String> downloadAndSaveAvatar(Uri content, Client client,
      {int width, int height}) async {
    final thumbnail = width == null && height == null ? false : true;
    final tempDirectory = (await getTemporaryDirectory()).path;
    final prefix = thumbnail ? 'thumbnail' : '';
    var file =
        File('$tempDirectory/${prefix}_${content.toString().split("/").last}');

    if (!file.existsSync()) {
      final url = Uri.parse(thumbnail
          ? content.getThumbnail(client, width: width, height: height)
          : content.getDownloadLink(client));
      if (url.host.isEmpty) return '';
      final request = await HttpClient()
          .getUrl(url)
          .timeout(Duration(seconds: 5))
          .catchError((e) => null);
      if (request == null) return '';
      final response = await request.close();
      var bytes = await consolidateHttpClientResponseBytes(response)
          .timeout(Duration(seconds: 5))
          .catchError((e) => null);
      if (bytes == null) return '';
      await file.writeAsBytes(bytes);
    }

    return file.path;
  }

  /// Workaround for the problem that local notification IDs must be int but we
  /// sort by [roomId] which is a String. To make sure that we don't have duplicated
  /// IDs we map the [roomId] to a number and store this number.
  Future<int> mapRoomIdToInt(String roomId) async {
    final storage = matrix?.store ?? Store();
    final idMap = json.decode(
        (await storage.getItem(SettingKeys.notificationCurrentIds)) ?? '{}');
    int currentInt;
    try {
      currentInt = idMap[roomId];
    } catch (_) {
      currentInt = null;
    }
    if (currentInt != null) {
      return currentInt;
    }
    currentInt = idMap.keys.length + 1;
    idMap[roomId] = currentInt;
    await storage.setItem(
        SettingKeys.notificationCurrentIds, json.encode(idMap));
    return currentInt;
  }

  StreamSubscription<darthtml.Event> onFocusSub;
  StreamSubscription<darthtml.Event> onBlurSub;

  bool webHasFocus = true;

  void sendDesktopNotification(
    String title,
    String body, {
    String icon,
    String roomId,
  }) async {
    try {
      darthtml.AudioElement()
        ..src = 'assets/assets/sounds/pop.wav'
        ..autoplay = true
        ..load();
      final notification = darthtml.Notification(
        title,
        body: body,
        icon: icon,
      );
      notification.onClick.listen((e) => _openRoom(roomId));
    } catch (e, s) {
      Logs().e('[Notify] Error sending desktop notification', e, s);
    }
  }

  Future<void> registerDesktopNotifications() async {
    await client.onSync.stream.first;
    await darthtml.Notification.requestPermission();
    onSync ??= client.onSync.stream.listen(updateTabTitle);
  }

  void updateTabTitle(dynamic sync) {
    var unreadEvents = 0;
    client.rooms.forEach((Room room) {
      if (room.membership == Membership.invite || room.notificationCount > 0) {
        unreadEvents++;
      }
    });
    if (unreadEvents > 0) {
      darthtml.document.title = '($unreadEvents) FluffyChat';
    } else {
      darthtml.document.title = 'FluffyChat';
    }
  }
}
