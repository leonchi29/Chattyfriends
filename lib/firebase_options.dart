import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web is not configured for this app.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError('This platform is not configured.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDSJ1jruyLCXDI1OOd-W45mgUtludbGSTI',
    appId: '1:534800192181:android:50df0c8ee079d07bad24fc',
    messagingSenderId: '534800192181',
    projectId: 'chatty-friends-51890',
    storageBucket: 'chatty-friends-51890.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDSJ1jruyLCXDI1OOd-W45mgUtludbGSTI',
    appId: '1:534800192181:ios:placeholder',
    messagingSenderId: '534800192181',
    projectId: 'chatty-friends-51890',
    storageBucket: 'chatty-friends-51890.firebasestorage.app',
    iosBundleId: 'com.app.chattyfriends',
  );
}
