import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/generated/app_localizations.dart';
import 'l10n/generated/app_localizations_en.dart';

final _english = AppLocalizationsEn();
extension AppStrings on BuildContext {
  AppLocalizations get strings => AppLocalizations.of(this) ?? _english;
}

// This app uses package:material_ui; the SDK's generated Material delegate is for legacy widgets.
const appLocalizationDelegates = [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates];

const _preferenceKey = 'app_language';
const _defaultLocale = Locale('en');
final appLocale = ValueNotifier<Locale>(_defaultLocale);

/// The chosen language's strings where no BuildContext can be read yet (in initState, before the first await).
AppLocalizations get appStrings => lookupAppLocalizations(appLocale.value);

Future<void> loadAppLanguage() async {
  String? language;
  try {
    language = (await SharedPreferences.getInstance()).getString(_preferenceKey);
  } catch (_) {
    // Preferences can be unavailable in a restricted browser.
  }
  // Not chosen yet: the phone's own language when the app has it, else English.
  final device = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  appLocale.value = AppLocalizations.supportedLocales.firstWhere(
    (locale) => locale.toLanguageTag() == language,
    orElse: () => language == null
        ? AppLocalizations.supportedLocales.firstWhere((l) => l.languageCode == device, orElse: () => _defaultLocale)
        : _defaultLocale);
}

Future<void> chooseAppLanguage(BuildContext context) async {
  final choice = await showDialog<Locale>(context: context, builder: (context) => SimpleDialog(
    title: Text(context.strings.language),
    children: [for (final locale in AppLocalizations.supportedLocales)
      SimpleDialogOption(
        key: Key('app-language-${locale.toLanguageTag()}'),
        onPressed: () => Navigator.pop(context, locale),
        child: Row(children: [
          Expanded(child: Text(switch (locale.languageCode) {
            'ko' => '한국어',
            'ja' => '日本語',
            'zh' => '简体中文',
            'es' => 'Español',
            _ => 'English',
          })),
          if (locale == appLocale.value) const Icon(Icons.check),
        ]),
      ),
    ],
  ));
  if (choice == null) return;
  appLocale.value = choice;
  try {
    await (await SharedPreferences.getInstance()).setString(_preferenceKey, choice.toLanguageTag());
  } catch (_) {
    // The language still applies for this session.
  }
}
