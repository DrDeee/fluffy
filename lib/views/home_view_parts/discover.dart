import 'dart:async';

import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:adaptive_page_layout/adaptive_page_layout.dart';
import 'package:famedlysdk/famedlysdk.dart';
import 'package:fluffychat/components/avatar.dart';
import 'package:fluffychat/components/default_app_bar_search_field.dart';
import 'package:future_loading_dialog/future_loading_dialog.dart';
import 'package:fluffychat/components/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/l10n.dart';

class Discover extends StatefulWidget {
  final String alias;

  final String server;

  const Discover({
    Key key,
    this.alias,
    this.server,
  }) : super(key: key);
  @override
  _DiscoverState createState() => _DiscoverState();
}

class _DiscoverState extends State<Discover> {
  Future<PublicRoomsResponse> _publicRoomsResponse;
  Timer _coolDown;
  String _genericSearchTerm;

  void _search(BuildContext context, String query) async {
    _coolDown?.cancel();
    _coolDown = Timer(
      Duration(milliseconds: 500),
      () => setState(() {
        _genericSearchTerm = query;
        _publicRoomsResponse = null;
      }),
    );
  }

  Future<String> _joinRoomAndWait(
    BuildContext context,
    String roomId,
    String alias,
  ) async {
    if (Matrix.of(context).client.getRoomById(roomId) != null) {
      return roomId;
    }
    final newRoomId = await Matrix.of(context)
        .client
        .joinRoomOrAlias(alias?.isNotEmpty ?? false ? alias : roomId);
    await Matrix.of(context)
        .client
        .onRoomUpdate
        .stream
        .firstWhere((r) => r.id == newRoomId);
    return newRoomId;
  }

  void _joinGroupAction(BuildContext context, PublicRoom room) async {
    if (await showOkCancelAlertDialog(
          context: context,
          okLabel: L10n.of(context).joinRoom,
          title: '${room.name} (${room.numJoinedMembers ?? 0})',
          message: room.topic ?? L10n.of(context).noDescription,
        ) ==
        OkCancelResult.cancel) {
      return;
    }
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => _joinRoomAndWait(
        context,
        room.roomId,
        room.canonicalAlias ?? room.aliases.first,
      ),
    );
    if (success.error == null) {
      await AdaptivePageLayout.of(context)
          .pushNamedAndRemoveUntilIsFirst('/rooms/${success.result}');
    }
  }

  @override
  void initState() {
    _genericSearchTerm = widget.alias;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final server = _genericSearchTerm?.isValidMatrixId ?? false
        ? _genericSearchTerm.domain
        : widget.server;
    _publicRoomsResponse ??= Matrix.of(context)
        .client
        .searchPublicRooms(
          server: server,
          genericSearchTerm: _genericSearchTerm,
        )
        .catchError((error) {
      if (widget.alias == null) {
        throw error;
      }
      return PublicRoomsResponse.fromJson({
        'chunk': [],
      });
    }).then((PublicRoomsResponse res) {
      if (widget.alias != null &&
          !res.chunk.any((room) =>
              (room.aliases?.contains(widget.alias) ?? false) ||
              room.canonicalAlias == widget.alias)) {
        // we have to tack on the original alias
        res.chunk.add(PublicRoom.fromJson(<String, dynamic>{
          'aliases': [widget.alias],
          'name': widget.alias,
        }));
      }
      return res;
    });
    return ListView(
      children: [
        Padding(
          padding: EdgeInsets.all(12),
          child: DefaultAppBarSearchField(
            hintText: L10n.of(context).search,
            prefixIcon: Icon(Icons.search_outlined),
            onChanged: (t) => _search(context, t),
            padding: EdgeInsets.zero,
          ),
        ),
        FutureBuilder<PublicRoomsResponse>(
            future: _publicRoomsResponse,
            builder: (BuildContext context,
                AsyncSnapshot<PublicRoomsResponse> snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text(snapshot.error.toString()));
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return Center(child: CircularProgressIndicator());
              }
              final publicRoomsResponse = snapshot.data;
              if (publicRoomsResponse.chunk.isEmpty) {
                return Center(
                  child: Text(
                    'No public groups found...',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.all(12),
                physics: NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: publicRoomsResponse.chunk.length,
                itemBuilder: (BuildContext context, int i) => Material(
                  elevation: 2,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    onTap: () => _joinGroupAction(
                      context,
                      publicRoomsResponse.chunk[i],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Avatar(
                              Uri.parse(
                                  publicRoomsResponse.chunk[i].avatarUrl ?? ''),
                              publicRoomsResponse.chunk[i].name),
                          Text(
                            publicRoomsResponse.chunk[i].name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            L10n.of(context).countParticipants(
                                publicRoomsResponse.chunk[i].numJoinedMembers ??
                                    0),
                            style: TextStyle(fontSize: 10.5),
                            maxLines: 1,
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            publicRoomsResponse.chunk[i].topic ??
                                L10n.of(context).noDescription,
                            maxLines: 4,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
      ],
    );
  }
}