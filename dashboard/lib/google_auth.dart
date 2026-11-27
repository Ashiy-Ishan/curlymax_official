import 'package:google_sign_in/google_sign_in.dart';

Future<void>? _initialization;

Future<({String idToken, String accessToken})> studioGoogleCredentials() async {
  const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  if (!RegExp(
    r'^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$',
  ).hasMatch(webClientId)) {
    throw StateError(
      'Native Google sign-in needs GOOGLE_WEB_CLIENT_ID in the public Studio build configuration. Use email sign-in meanwhile.',
    );
  }
  final google = GoogleSignIn.instance;
  await (_initialization ??= google.initialize(serverClientId: webClientId));
  final account = await google.authenticate();
  const scopes = ['email', 'profile'];
  final authorization =
      await account.authorizationClient.authorizationForScopes(scopes) ??
      await account.authorizationClient.authorizeScopes(scopes);
  final idToken = account.authentication.idToken;
  if (idToken == null || idToken.isEmpty) {
    throw StateError('Google did not return an identity. Try again.');
  }
  return (idToken: idToken, accessToken: authorization.accessToken);
}
