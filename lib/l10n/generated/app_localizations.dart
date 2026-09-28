import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en')
  ];

  /// No description provided for @appTitle.
  ///
  /// In de, this message translates to:
  /// **'Cat Snake'**
  String get appTitle;

  /// No description provided for @language.
  ///
  /// In de, this message translates to:
  /// **'Sprache'**
  String get language;

  /// No description provided for @germanLanguage.
  ///
  /// In de, this message translates to:
  /// **'Deutsch'**
  String get germanLanguage;

  /// No description provided for @englishLanguage.
  ///
  /// In de, this message translates to:
  /// **'Englisch'**
  String get englishLanguage;

  /// No description provided for @score.
  ///
  /// In de, this message translates to:
  /// **'Score'**
  String get score;

  /// No description provided for @highScore.
  ///
  /// In de, this message translates to:
  /// **'Highscore'**
  String get highScore;

  /// No description provided for @levelHighScore.
  ///
  /// In de, this message translates to:
  /// **'Level-Highscore'**
  String get levelHighScore;

  /// No description provided for @points.
  ///
  /// In de, this message translates to:
  /// **'Punkte'**
  String get points;

  /// No description provided for @pointsShort.
  ///
  /// In de, this message translates to:
  /// **'Pkt.'**
  String get pointsShort;

  /// No description provided for @gameOverTitle.
  ///
  /// In de, this message translates to:
  /// **'Miau – Runde vorbei!'**
  String get gameOverTitle;

  /// No description provided for @globalSubmitted.
  ///
  /// In de, this message translates to:
  /// **'Weltweit eingetragen ✓'**
  String get globalSubmitted;

  /// No description provided for @continueLabel.
  ///
  /// In de, this message translates to:
  /// **'Weiter'**
  String get continueLabel;

  /// No description provided for @backToStart.
  ///
  /// In de, this message translates to:
  /// **'Zum Start'**
  String get backToStart;

  /// No description provided for @newCatRecord.
  ///
  /// In de, this message translates to:
  /// **'Neuer Katzen-Rekord!'**
  String get newCatRecord;

  /// No description provided for @globalNameQuestion.
  ///
  /// In de, this message translates to:
  /// **'Unter welchem Namen möchtest du weltweit erscheinen?'**
  String get globalNameQuestion;

  /// No description provided for @yourName.
  ///
  /// In de, this message translates to:
  /// **'Dein Name'**
  String get yourName;

  /// No description provided for @nameHint.
  ///
  /// In de, this message translates to:
  /// **'z. B. Miezemeister'**
  String get nameHint;

  /// No description provided for @localOnly.
  ///
  /// In de, this message translates to:
  /// **'Nur lokal'**
  String get localOnly;

  /// No description provided for @submit.
  ///
  /// In de, this message translates to:
  /// **'Eintragen'**
  String get submit;

  /// No description provided for @globalSubmitSuccess.
  ///
  /// In de, this message translates to:
  /// **'Miau! Dein Rekord ist jetzt weltweit sichtbar.'**
  String get globalSubmitSuccess;

  /// No description provided for @globalSubmitFailure.
  ///
  /// In de, this message translates to:
  /// **'Der Online-Eintrag hat nicht geklappt. Dein lokaler Rekord bleibt gespeichert.'**
  String get globalSubmitFailure;

  /// No description provided for @chooseLevel.
  ///
  /// In de, this message translates to:
  /// **'Level wählen'**
  String get chooseLevel;

  /// No description provided for @bestScore.
  ///
  /// In de, this message translates to:
  /// **'Bester Score'**
  String get bestScore;

  /// No description provided for @globalLeaderboard.
  ///
  /// In de, this message translates to:
  /// **'Weltweite Bestenliste'**
  String get globalLeaderboard;

  /// No description provided for @readyTitle.
  ///
  /// In de, this message translates to:
  /// **'Bereit zur Mäusejagd?'**
  String get readyTitle;

  /// No description provided for @readySubtitle.
  ///
  /// In de, this message translates to:
  /// **'Fische schnappen · Mäuse erwischen'**
  String get readySubtitle;

  /// No description provided for @level.
  ///
  /// In de, this message translates to:
  /// **'Level'**
  String get level;

  /// No description provided for @startGame.
  ///
  /// In de, this message translates to:
  /// **'Spiel starten'**
  String get startGame;

  /// No description provided for @computerStartHint.
  ///
  /// In de, this message translates to:
  /// **'Computer: Leertaste oder Enter'**
  String get computerStartHint;

  /// No description provided for @wrapWalls.
  ///
  /// In de, this message translates to:
  /// **'Rand-Warp'**
  String get wrapWalls;

  /// No description provided for @solidWalls.
  ///
  /// In de, this message translates to:
  /// **'Feste Wände'**
  String get solidWalls;

  /// No description provided for @startFirst.
  ///
  /// In de, this message translates to:
  /// **'Spiel zuerst starten'**
  String get startFirst;

  /// No description provided for @resume.
  ///
  /// In de, this message translates to:
  /// **'Fortsetzen'**
  String get resume;

  /// No description provided for @pause.
  ///
  /// In de, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @chooseCat.
  ///
  /// In de, this message translates to:
  /// **'Katze wählen'**
  String get chooseCat;

  /// No description provided for @toggleSound.
  ///
  /// In de, this message translates to:
  /// **'Sound an/aus'**
  String get toggleSound;

  /// No description provided for @newGame.
  ///
  /// In de, this message translates to:
  /// **'Neues Spiel'**
  String get newGame;

  /// No description provided for @newShort.
  ///
  /// In de, this message translates to:
  /// **'Neu'**
  String get newShort;

  /// No description provided for @mouseBonus.
  ///
  /// In de, this message translates to:
  /// **'MAUS-BONUS'**
  String get mouseBonus;

  /// No description provided for @leaderboardSubtitle.
  ///
  /// In de, this message translates to:
  /// **'Die besten Katzenjäger pro Level'**
  String get leaderboardSubtitle;

  /// No description provided for @close.
  ///
  /// In de, this message translates to:
  /// **'Schließen'**
  String get close;

  /// No description provided for @yourPlayerName.
  ///
  /// In de, this message translates to:
  /// **'Dein Spielername'**
  String get yourPlayerName;

  /// No description provided for @offlineAvailable.
  ///
  /// In de, this message translates to:
  /// **'Offline verfügbar'**
  String get offlineAvailable;

  /// No description provided for @offlineLeaderboardMessage.
  ///
  /// In de, this message translates to:
  /// **'Die weltweite Bestenliste erscheint in der Web-App.'**
  String get offlineLeaderboardMessage;

  /// No description provided for @noConnection.
  ///
  /// In de, this message translates to:
  /// **'Gerade keine Verbindung'**
  String get noConnection;

  /// No description provided for @tryAgain.
  ///
  /// In de, this message translates to:
  /// **'Bitte versuche es gleich noch einmal.'**
  String get tryAgain;

  /// No description provided for @noEntries.
  ///
  /// In de, this message translates to:
  /// **'Noch keine Einträge'**
  String get noEntries;

  /// No description provided for @getFirstPlace.
  ///
  /// In de, this message translates to:
  /// **'Hol dir den ersten Platz!'**
  String get getFirstPlace;

  /// No description provided for @unlockAt.
  ///
  /// In de, this message translates to:
  /// **'Ab'**
  String get unlockAt;

  /// No description provided for @unlockPoints.
  ///
  /// In de, this message translates to:
  /// **'Punkten'**
  String get unlockPoints;

  /// No description provided for @keyboardControlSemantics.
  ///
  /// In de, this message translates to:
  /// **'Steuerung mit den Pfeiltasten'**
  String get keyboardControlSemantics;

  /// No description provided for @keyboardFunHint.
  ///
  /// In de, this message translates to:
  /// **'Mit den Pfoten – äh, Pfeiltasten'**
  String get keyboardFunHint;

  /// No description provided for @keyboardHint.
  ///
  /// In de, this message translates to:
  /// **'Steuerung: Pfeiltasten'**
  String get keyboardHint;

  /// No description provided for @dpadSemantics.
  ///
  /// In de, this message translates to:
  /// **'Pfoten-Steuerkreuz'**
  String get dpadSemantics;

  /// No description provided for @comboUpLeft.
  ///
  /// In de, this message translates to:
  /// **'Kombi: hoch und links'**
  String get comboUpLeft;

  /// No description provided for @comboUpRight.
  ///
  /// In de, this message translates to:
  /// **'Kombi: hoch und rechts'**
  String get comboUpRight;

  /// No description provided for @comboDownLeft.
  ///
  /// In de, this message translates to:
  /// **'Kombi: runter und links'**
  String get comboDownLeft;

  /// No description provided for @comboDownRight.
  ///
  /// In de, this message translates to:
  /// **'Kombi: runter und rechts'**
  String get comboDownRight;

  /// No description provided for @directionUp.
  ///
  /// In de, this message translates to:
  /// **'Nach oben'**
  String get directionUp;

  /// No description provided for @directionDown.
  ///
  /// In de, this message translates to:
  /// **'Nach unten'**
  String get directionDown;

  /// No description provided for @directionLeft.
  ///
  /// In de, this message translates to:
  /// **'Nach links'**
  String get directionLeft;

  /// No description provided for @directionRight.
  ///
  /// In de, this message translates to:
  /// **'Nach rechts'**
  String get directionRight;

  /// No description provided for @meadow.
  ///
  /// In de, this message translates to:
  /// **'Wiese'**
  String get meadow;

  /// No description provided for @livingRoom.
  ///
  /// In de, this message translates to:
  /// **'Wohnzimmer'**
  String get livingRoom;

  /// No description provided for @garden.
  ///
  /// In de, this message translates to:
  /// **'Garten'**
  String get garden;

  /// No description provided for @meadowDescription.
  ///
  /// In de, this message translates to:
  /// **'Entspannt · Rand-Warp · keine Hindernisse'**
  String get meadowDescription;

  /// No description provided for @livingRoomDescription.
  ///
  /// In de, this message translates to:
  /// **'Schneller · feste Wände · Möbel'**
  String get livingRoomDescription;

  /// No description provided for @gardenDescription.
  ///
  /// In de, this message translates to:
  /// **'Rasant · Rand-Warp · Beete und Teich'**
  String get gardenDescription;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
