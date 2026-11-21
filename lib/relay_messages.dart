import 'l10n/generated/app_localizations.dart';

/// The error a screen should show for a bridge `status` message, or null when there is nothing to show.
///
/// A refused service call is answered twice: a `status` error and a failed `service_response` with the
/// same id. The caller of that service already handles the failed response (a lag probe, for example,
/// simply stops measuring), so the `status` copy is not shown again. The remote relay's fixed English
/// refusals are shown in the app's language.
String? statusErrorIn(Map<String, dynamic> event, AppLocalizations s) {
  if (event['level'] != 'error') return null;
  final id = event['id'];
  if (id is String && id.startsWith('request_')) return null;
  return relayMessageIn('${event['msg']}', s);
}

/// A fixed English remote message, from the relay, the account server or the app's own remote code, in
/// the app's language. Any other text (a robot's own error, an installer line) is returned unchanged.
String relayMessageIn(String message, AppLocalizations s) {
  final text = switch (message) {
      'This service is unavailable over remote access.' => s.remoteServiceBlocked,
      'This topic is read-only over remote access.' => s.remoteReadOnly,
      'Remote speed limit exceeded (0.25 m/s, 0.6 rad/s).' => s.remoteSpeedLimit,
      'Use a valid map goal with the default navigation behavior.' => s.remoteBadGoal,
      'This command is unavailable over remote access.' ||
      'Unsupported remote action.' ||
      'Invalid velocity command.' ||
      'Invalid robot answer.' =>
        s.remoteCommandBlocked,
      'Remote access paused. Reconnect when you return to the app.' =>
        s.rtSessionPaused,
      'Your account changed. Please try again.' ||
      'Your account changed. Please restore again.' ||
      'Purchase account changed.' =>
        s.rtAccountChanged,
      'The remote service returned an invalid response.' =>
        s.rtInvalidResponse,
      'Check your email to verify your account, then sign in.' ||
      'Verify your email and sign in again.' =>
        s.rtVerifyEmail,
      'Sign in again. Check your email and password.' =>
        s.rtSignInAgainCheck,
      'Too many attempts. Please wait a minute and try again.' ||
      'Too many attempts. Try again in a minute.' ||
      'Please wait before trying again.' ||
      'Try again later.' =>
        s.rtTooManyAttempts,
      'Could not complete this request. Check your details and try again.' ||
      'Invalid request.' ||
      'Invalid sign-in request.' =>
        s.rtRequestFailed,
      'Could not reach the remote service. Check your internet connection.' =>
        s.rtUnreachable,
      'Remote access is being prepared. You can still connect locally.' ||
      'Remote access is being configured.' =>
        s.rtPreparing,
      'Remote sign-in is unavailable. Please try again later.' =>
        s.rtSignInUnavailable,
      'Sign-in was canceled.' =>
        s.rtSignInCanceled,
      'Could not start your session.' =>
        s.rtSessionStartFailed,
      'Could not securely save your sign-in on this device.' =>
        s.rtVaultFailed,
      'Sign in to continue.' ||
      'Sign in again to continue.' ||
      'Sign in again.' ||
      'Refresh your sign-in and try again.' ||
      'Not authorized.' =>
        s.rtSignInToContinue,
      'Invalid robot address.' =>
        s.rtInvalidAddress,
      'Could not connect. The robot may be offline or in use.' =>
        s.rtConnectFailed,
      'Your remote session ended.' ||
      'Your remote session ended. Reconnect from My robots.' ||
      'Remote connection closed.' =>
        s.rtSessionEnded,
      'Your 30-minute remote session ended. Reconnect from My robots.' ||
      'Remote session time limit.' =>
        s.rtSessionTimeLimit,
      'Remote control is preparing. Try again.' =>
        s.rtControlPreparing,
      'Remote preview supports differential drive only.' =>
        s.rtDiffDriveOnly,
      'Remote usage limit reached.' =>
        s.rtUsageLimit,
      'Access revoked.' =>
        s.rtAccessRevoked,
      'Stopped by a viewer.' =>
        s.rtStoppedByViewer,
      'Too many remote topics.' =>
        s.rtTooManyTopics,
      'Slow remote connection.' ||
      'Remote link is too delayed.' =>
        s.rtSlowLink,
      'Robot went offline.' ||
      'The robot is offline.' =>
        s.rtRobotOffline,
      'Robot removed.' ||
      'Robot not found.' ||
      'Unknown robot.' ||
      'Not found.' =>
        s.rtRobotRemoved,
      'Robot reconnected.' =>
        s.rtRobotReconnected,
      'Remote robot limit changed.' =>
        s.rtRobotLimitChanged,
      'App closed.' =>
        s.rtAppClosed,
      'Use at least 12 password characters.' =>
        s.rtPasswordLength,
      'This robot is shared with the beta limit of 10 people.' =>
        s.rtSharedLimit,
      'Too many remote sessions. Sign out and try again.' =>
        s.rtTooManySessions,
      'Too many open invitations for this robot.' =>
        s.rtTooManyInvites,
      'Registration is busy. Try again later.' ||
      'Robot capacity is full. Try registering later.' =>
        s.rtRegistrationBusy,
      'The registration expired.' ||
      'This registration code is invalid or expired.' =>
        s.rtRegistrationExpired,
      'Usage month changed. Please try again.' =>
        s.rtUsageMonthChanged,
      'This is your own robot.' =>
        s.rtOwnRobot,
      'This account has reached the beta limit of 10 robots.' =>
        s.rtRobotLimit,
      'Start the robot agent before registering.' =>
        s.rtStartAgent,
      'This reset link has expired. Request a new one.' =>
        s.rtResetExpired,
      'That password is not correct.' =>
        s.rtWrongPassword,
      'This account was deleted.' =>
        s.rtAccountDeleted,
      'This invitation code is invalid or expired.' =>
        s.rtInviteInvalid,
      'Enter your password to confirm.' =>
        s.rtEnterPasswordConfirm,
      'Enter your email and password.' =>
        s.rtEnterEmailPassword,
      'Enter your email address.' =>
        s.rtEnterEmail,
      'Enter the registration code shown on the robot computer.' =>
        s.rtEnterCode,
      'Enter the invitation code.' =>
        s.rtEnterInvite,
      'Enter a robot name (1–60 characters).' =>
        s.rtRobotName,
      'Choose viewer or operator.' =>
        s.rtChooseRole,
      'Choose a stronger password.' =>
        s.rtStrongerPassword,
      'Choose a password you have not used before.' =>
        s.rtNewPassword,
      'Could not send the email. Try again later.' =>
        s.rtEmailFailed,
      'Could not delete the sign-in yet.' ||
      'Provider sign-out did not complete.' =>
        s.rtDeleteLater,
      'Remote purchase benefits are unavailable.' ||
      'Remote purchase benefits are being prepared.' =>
        s.rtPurchasesUnavailable,
      'Could not read the private key. Paste the whole key (-----BEGIN ... PRIVATE KEY----- to the END line) and its passphrase if it has one.' =>
        s.rtKeyUnreadable,
      'Could not reach the robot computer over SSH. Check that SSH is on (port 22).' =>
        s.rtSshUnreachable,
      'The robot computer was not confirmed. Nothing was installed.' =>
        s.rtHostNotConfirmed,
      'Could not sign in with this key. Check the user name and that the key is allowed on the robot computer.' =>
        s.rtSshKeyRejected,
      'Could not sign in to the robot computer. Check the user name and password.' =>
        s.rtSshPasswordRejected,
      'The connection to the robot computer was lost during setup.' =>
        s.rtSetupLost,
      'Setup did not finish. Try again.' =>
        s.rtSetupUnfinished,
      'The robot returned an invalid registration.' =>
        s.rtSetupInvalid,
      _ => null,
    };
  if (text != null) return text;
  final sudoNeedsPassword = RegExp(r'^sudo asks (.+) for a password\. Enter it under \"sudo password\"\.$').firstMatch(message);
  if (sudoNeedsPassword != null) return s.rtSudoNeedsPassword(sudoNeedsPassword.group(1)!);
  final sudoRefused = RegExp(r'^(.+) cannot use sudo with this password\. Use an administrator account\.$').firstMatch(message);
  if (sudoRefused != null) return s.rtSudoRefused(sudoRefused.group(1)!);
  return message;
}
