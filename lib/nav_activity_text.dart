import 'l10n/generated/app_localizations.dart';
import 'nav_activity.dart';

/// [a] in the app language.
String navActivityText(AppLocalizations s, NavActivity a) => switch (a) {
  NavActivity.planning => s.navActPlanning,
  NavActivity.following => s.navActFollowing,
  NavActivity.clearing => s.navActClearing,
  NavActivity.spinning => s.navActSpinning,
  NavActivity.backingUp => s.navActBackingUp,
  NavActivity.waiting => s.navActWaiting,
  NavActivity.drivingOnHeading => s.navActDriving,
  NavActivity.recovering => s.navActRecovering,
};
