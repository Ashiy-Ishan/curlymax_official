import 'package:google_sign_in/google_sign_in.dart';
import 'config.dart';

Future<void>? _initialization;

/// Google's account picker obtains an ID token; Supabase verifies it server-side.
Future<({String idToken, String accessToken})> nativeGoogleIdToken() async {
  if (!RegExp(
    r'^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$',
  ).hasMatch(AppConfig.googleWebClientId)) {
    throw StateError(
      'Google sign-in is not configured in this build. Use email sign-in, '
      'or ask the developer to set GOOGLE_WEB_CLIENT_ID.',
    );
  }
  try {
    final google = GoogleSignIn.instance;
    await (_initialization ??= google.initialize(
      serverClientId: AppConfig.googleWebClientId,
    ));
    final account = await google.authenticate();
    const scopes = ['email', 'profile'];
    final authorization =
        await account.authorizationClient.authorizationForScopes(scopes) ??
        await account.authorizationClient.authorizeScopes(scopes);
    final token = account.authentication.idToken;
    if (token == null || token.isEmpty) {
      throw StateError('Google did not return an identity. Please try again.');
    }
    return (idToken: token, accessToken: authorization.accessToken);
  } on GoogleSignInException catch (error) {
    if (error.code == GoogleSignInExceptionCode.canceled) {
      throw StateError(
        'Google sign-in was cancelled. You can try again or use email.',
      );
    }
    throw StateError(
      'Google sign-in could not finish. Try again or use email. '
      'If this keeps happening, the developer should check the Android OAuth '
      'client and this build’s signing certificate.',
    );
  }
}
