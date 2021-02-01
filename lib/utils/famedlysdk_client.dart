import 'package:famedlysdk/famedlysdk.dart';
import 'package:famedlysdk/encryption.dart';
import 'platform_infos.dart';
import 'famedlysdk_store.dart';

Client _client;

Client getClient() {
  if (_client != null) {
    return _client;
  }
  final clientName = PlatformInfos.clientName;
  final Set verificationMethods = <KeyVerificationMethod>{
    KeyVerificationMethod.numbers
  };
  if (PlatformInfos.isMobile || PlatformInfos.isLinux) {
    // emojis don't show in web somehow
    verificationMethods.add(KeyVerificationMethod.emoji);
  }
  _client = Client(
    clientName,
    enableE2eeRecovery: true,
    verificationMethods: verificationMethods,
    importantStateEvents: <String>{
      'im.ponies.room_emotes', // we want emotes to work properly
    },
    databaseBuilder: getDatabase,
    supportedLoginTypes: {
      AuthenticationTypes.password,
      if (PlatformInfos.isMobile) AuthenticationTypes.sso
    },
  );
  return _client;
}
