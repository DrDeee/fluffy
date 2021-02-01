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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:famedlysdk/famedlysdk.dart';
import 'package:fcm_shared_isolate/fcm_shared_isolate.dart';
import 'package:flushbar/flushbar_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pedantic/pedantic.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../../components/matrix.dart';
import '../platform_infos.dart';
import '../../app_config.dart';
import '../../config/setting_keys.dart';
import '../famedlysdk_store.dart';

class PreNotify {
  PreNotify(this.roomId, this.eventId);
  String roomId;
  String eventId;
}

class NoTokenException implements Exception {
  String get cause => 'Cannot get firebase token';
}

class BackgroundPushPlugin {
  static BackgroundPushPlugin _instance;
  Client client;
  MatrixState matrix;
  String _fcmToken;
  LoginState _loginState;

  final StreamController<PreNotify> onPreNotify = StreamController.broadcast();

  final pendingTests = <String, Completer<void>>{};

  void Function() _onMatrixInit;

  DateTime lastReceivedPush;

  BackgroundPushPlugin._(this.client) {
    onLogin ??=
        client.onLoginStateChanged.stream.listen(handleLoginStateChanged);
    _firebaseMessaging.setListeners(
      onMessage: _onFcmMessage,
      onNewToken: _newFcmToken,
    );
    UnifiedPush.setListeners(
      onNewEndpoint: _newUpEndpoint,
      onRegistrationFailed: _upUnregistered,
      onRegistrationRefused: _upUnregistered,
      onUnregistered: _upUnregistered,
      onMessage: _onUpMessage,
    );
  }

  factory BackgroundPushPlugin.clientOnly(Client client) {
    _instance ??= BackgroundPushPlugin._(client);
    return _instance;
  }

  factory BackgroundPushPlugin(MatrixState matrix) {
    final instance = BackgroundPushPlugin.clientOnly(matrix.client);
    unawaited(instance.initMatrix(matrix));
    return instance;
  }

  Future<void> initMatrix(MatrixState matrix) async {
    this.matrix = matrix;
    _onMatrixInit?.call();
    _onMatrixInit = null;
  }

  void handleLoginStateChanged(LoginState state) {
    _loginState = state;
    if (state == LoginState.logged && PlatformInfos.isMobile) {
      setupPush();
    }
  }

  void _newFcmToken(String token) {
    _fcmToken = token;
    if (_loginState == LoginState.logged && PlatformInfos.isMobile) {
      setupPush();
    }
  }

  final _firebaseMessaging = FcmSharedIsolate();

  StreamSubscription<LoginState> onLogin;

  Future<void> setupPusher({
    String gatewayUrl,
    String token,
    Set<String> oldTokens,
  }) async {
    final clientName = PlatformInfos.clientName;
    oldTokens ??= <String>{};
    final pushers = await client.requestPushers().catchError((e) {
      Logs().w('[Push] Unable to request pushers', e);
      return <Pusher>[];
    });
    var setNewPusher = false;
    if (gatewayUrl != null && token != null && clientName != null) {
      final currentPushers = pushers.where((pusher) => pusher.pushkey == token);
      if (currentPushers.length == 1 &&
          currentPushers.first.kind == 'http' &&
          currentPushers.first.appId == AppConfig.pushNotificationsAppId &&
          currentPushers.first.appDisplayName == clientName &&
          currentPushers.first.deviceDisplayName == client.deviceName &&
          currentPushers.first.lang == 'en' &&
          currentPushers.first.data.url.toString() == gatewayUrl &&
          currentPushers.first.data.format ==
              AppConfig.pushNotificationsPusherFormat) {
        Logs().i('[Push] Pusher already set');
      } else {
        oldTokens.add(token);
        if (client.isLogged()) {
          setNewPusher = true;
        }
      }
    }
    for (final pusher in pushers) {
      if (oldTokens.contains(pusher.pushkey)) {
        pusher.kind = null;
        try {
          await client.setPusher(
            pusher,
            append: true,
          );
          Logs().i('[Push] Removed legacy pusher for this device');
        } catch (err) {
          Logs().w('[Push] Failed to remove old pusher', err);
        }
      }
    }
    if (setNewPusher) {
      try {
        await client.setPusher(
          Pusher(
            token,
            AppConfig.pushNotificationsAppId,
            clientName,
            client.deviceName,
            'en',
            PusherData(
              url: Uri.parse(gatewayUrl),
              format: AppConfig.pushNotificationsPusherFormat,
            ),
            kind: 'http',
          ),
          append: false,
        );
      } catch (e, s) {
        Logs().e('[Push] Unable to set pushers', e, s);
      }
    }
  }

  Future<void> setupPush() async {
    if (_loginState != LoginState.logged || !PlatformInfos.isMobile) {
      return;
    }
    if (!PlatformInfos.isIOS &&
        (await UnifiedPush.getDistributors()).isNotEmpty) {
      await setupUp();
    } else {
      await setupFirebase();
    }
  }

  Future<void> _noFcmWarning() async {
    if (matrix?.context == null) {
      return;
    }
    if (await matrix.store.getItemBool(SettingKeys.showNoGoogle, true)) {
      await FlushbarHelper.createError(
        message: matrix.l10n.noGoogleServicesWarning,
        duration: Duration(seconds: 15),
      ).show(matrix.context);
      if (null == await matrix.store.getItem(SettingKeys.showNoGoogle)) {
        await matrix.store.setItemBool(SettingKeys.showNoGoogle, false);
      }
    }
  }

  Future<void> setupFirebase() async {
    if (_fcmToken?.isEmpty ?? true) {
      try {
        _fcmToken = await _firebaseMessaging.getToken();
      } catch (e, s) {
        Logs().e('[Push] cannot get token', e, s);
        await _noFcmWarning();
        return;
      }
    }
    await setupPusher(
      gatewayUrl: AppConfig.pushNotificationsGatewayUrl,
      token: _fcmToken,
    );

    if (matrix == null) {
      _onMatrixInit = sendTestMessageGUI;
    } else if (kReleaseMode) {
      // ignore: unawaited_futures
      sendTestMessageGUI();
    }
  }

  Future<void> setupUp() async {
    final store = matrix?.store ?? Store();
    if (!(await store.getItemBool(SettingKeys.unifiedPushRegistered, false))) {
      Logs().i('[Push] UnifiedPush not registered, attempting to do so...');
      await UnifiedPush.registerAppWithDialog();
    } else {
      // make sure the endpoint is up-to-date etc.
      await _newUpEndpoint(
          await store.getItem(SettingKeys.unifiedPushEndpoint));
    }
  }

  Future<void> _onFcmMessage(Map<dynamic, dynamic> message) async {
    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(message['data'] ?? message);
      await _onMessage(data);
    } catch (e, s) {
      Logs().e('[Push] Error while processing notification', e, s);
    }
  }

  Future<void> _newUpEndpoint(String newEndpoint) async {
    if (newEndpoint?.isEmpty ?? true) {
      await _upUnregistered();
      return;
    }
    var endpoint =
        'https://matrix.gateway.unifiedpush.org/_matrix/push/v1/notify';
    try {
      final url = Uri.parse(newEndpoint)
          .replace(
            path: '/_matrix/push/v1/notify',
            query: '',
          )
          .toString()
          .split('?')
          .first;
      final res = json.decode(utf8.decode((await http.get(url)).bodyBytes));
      if (res['gateway'] == 'matrix') {
        endpoint = url;
      }
    } catch (e) {
      Logs().i(
          '[Push] No self-hosted unified push gateway present: ' + newEndpoint);
    }
    Logs().i('[Push] UnifiedPush using endpoint ' + endpoint);
    final oldTokens = <String>{};
    try {
      final fcmToken = await _firebaseMessaging.getToken();
      oldTokens.add(fcmToken);
    } catch (_) {}
    await setupPusher(
      gatewayUrl: endpoint,
      token: newEndpoint,
      oldTokens: oldTokens,
    );
    final store = matrix?.store ?? Store();
    await store.setItem(SettingKeys.unifiedPushEndpoint, newEndpoint);
    await store.setItemBool(SettingKeys.unifiedPushRegistered, true);
  }

  Future<void> _upUnregistered() async {
    Logs().i('[Push] Removing UnifiedPush endpoint...');
    final store = matrix?.store ?? Store();
    final oldEndpoint = await store.getItem(SettingKeys.unifiedPushEndpoint);
    await store.setItemBool(SettingKeys.unifiedPushRegistered, false);
    await store.deleteItem(SettingKeys.unifiedPushEndpoint);
    if (matrix != null && (oldEndpoint?.isNotEmpty ?? false)) {
      // remove the old pusher
      await setupPusher(
        oldTokens: {oldEndpoint},
      );
    }
  }

  Future<void> _onUpMessage(String message) async {
    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(json.decode(message)['notification']);
      await _onMessage(data);
    } catch (e, s) {
      Logs().e('[Push] Error while processing notification', e, s);
    }
  }

  Future<void> _onMessage(Map<String, dynamic> data) async {
    try {
      Logs().v('[Push] _onMessage');
      lastReceivedPush = DateTime.now();
      final roomId = data['room_id'];
      final eventId = data['event_id'];
      if (roomId == 'test') {
        Logs().v('[Push] Test $eventId was successful!');
        pendingTests.remove(eventId)?.complete();
        return;
      }
      if (roomId != null && eventId != null) {
        var giveUp = false;
        var loaded = false;
        final stopwatch = Stopwatch();
        stopwatch.start();
        final syncSubscription = client.onSync.stream.listen((r) {
          if (stopwatch.elapsed.inSeconds >= 30) {
            giveUp = true;
          }
        });
        final eventSubscription = client.onEvent.stream.listen((e) {
          if (e.content['event_id'] == eventId) {
            loaded = true;
          }
        });
        try {
          if (!(await eventExists(roomId, eventId)) && !loaded) {
            onPreNotify.add(PreNotify(roomId, eventId));
            do {
              Logs().v('[Push] getting ' + roomId + ', event ' + eventId);
              await client.oneShotSync();
              if (stopwatch.elapsed.inSeconds >= 60) {
                giveUp = true;
              }
            } while (!loaded && !giveUp);
          }
          Logs().v('[Push] ' +
              (giveUp ? 'gave up on ' : 'got ') +
              roomId +
              ', event ' +
              eventId);
        } finally {
          await syncSubscription.cancel();
          await eventSubscription.cancel();
        }
      } else {
        if (client.syncPending) {
          Logs().v('[Push] waiting for existing sync');
          await client.oneShotSync();
        }
        Logs().v('[Push] single oneShotSync');
        await client.oneShotSync();
      }
    } catch (e, s) {
      Logs().e('[Push] Error proccessing push message: $e', s);
    }
  }

  Future<bool> eventExists(String roomId, String eventId) async {
    final room = client.getRoomById(roomId);
    if (room == null) return false;
    return (await client.database.getEventById(client.id, eventId, room)) !=
        null;
  }

  Future<bool> sendTestMessageGUI({bool verbose = false}) async {
    try {
      await sendTestMessage().timeout(Duration(seconds: 30));
      if (verbose) {
        await FlushbarHelper.createSuccess(
                message:
                    'Push test was successful' /* matrix.l10n.pushTestSuccessful */)
            .show(matrix.context);
      }
    } catch (e, s) {
      var msg;
//      final l10n = matrix.l10n;
      if (e is SocketException) {
        msg = 'Push server is unreachable';
//        msg = verbose ? l10n.pushServerUnreachable : null;
      } else if (e is NoTokenException) {
        msg = 'Push token is unavailable';
//        msg = verbose ? l10n.pushTokenUnavailable : null;
      } else {
        msg = 'Push failed';
//        msg = l10n.pushFail;
        Logs().e('[Push] Test message failed: $e', s);
      }
      if (msg != null) {
        await FlushbarHelper.createError(message: '$msg\n\n${e.toString()}')
            .show(matrix.context);
      }
      return false;
    }
    return true;
  }

  Future<void> sendTestMessage() async {
    final store = matrix?.store ?? Store();

    if (!(await store.getItemBool(SettingKeys.unifiedPushRegistered, false)) &&
        (_fcmToken?.isEmpty ?? true)) {
      throw NoTokenException();
    }

    final random = Random.secure();
    final randomId =
        base64.encode(List<int>.generate(12, (i) => random.nextInt(256)));
    final completer = Completer<void>();
    pendingTests[randomId] = completer;

    final endpoint = (await store.getItem(SettingKeys.unifiedPushEndpoint)) ??
        AppConfig.pushNotificationsGatewayUrl;

    try {
      final resp = await http.post(
        endpoint,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(
          {
            'notification': {
              'event_id': randomId,
              'room_id': 'test',
              'counts': {
                'unread': 1,
              },
              'devices': [
                {
                  'app_id': AppConfig.pushNotificationsAppId,
                  'pushkey': _fcmToken,
                  'pushkey_ts': 12345678,
                  'data': {},
                  'tweaks': {}
                }
              ]
            }
          },
        ),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 299) {
        throw resp.body.isNotEmpty ? resp.body : resp.reasonPhrase;
      }
    } catch (_) {
      pendingTests.remove(randomId);
      rethrow;
    }

    return completer.future;
  }
}
