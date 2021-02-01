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

import 'package:famedlysdk/famedlysdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../components/matrix.dart';

class BackgroundSyncPlugin with WidgetsBindingObserver {
  final Client client;

  BackgroundSyncPlugin._(this.client) {
    if (kIsWeb) return;
    final wb = WidgetsBinding.instance;
    wb.addObserver(this);
    didChangeAppLifecycleState(wb.lifecycleState);
  }

  static BackgroundSyncPlugin _instance;

  factory BackgroundSyncPlugin.clientOnly(Client client) {
    _instance ??= BackgroundSyncPlugin._(client);
    return _instance;
  }

  factory BackgroundSyncPlugin(MatrixState matrix) =>
      BackgroundSyncPlugin.clientOnly(matrix.client);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Logs().v('AppLifecycleState = $state');
    final foreground = state != AppLifecycleState.detached &&
        state != AppLifecycleState.paused;
    client.backgroundSync = foreground;
    client.syncPresence = foreground ? null : PresenceType.unavailable;
    client.requestHistoryOnLimitedTimeline = !foreground;
  }
}
