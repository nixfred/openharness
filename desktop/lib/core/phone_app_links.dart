/// The Harness phone app in its stores: the bar a phone's browser shows
/// (`web/shell/web_store_banner.dart`) and the download codes in Add Phone
/// (`widgets/add_phone_dialog.dart`). One place, so a store listing that moves
/// moves both.
const kAppStoreUrl =
    'https://apps.apple.com/us/app/harness-like-a-boss/id6812264068';

/// The Play listing of package `ai.autonomous.harness.android` — the phone
/// app's `applicationId` (mobile `android/app/build.gradle.kts`).
const kGooglePlayUrl =
    'https://play.google.com/store/apps/details?id=ai.autonomous.harness.android';

/// The phone app, whichever phone opens it: the website sends an iPhone to
/// [kAppStoreUrl] and an Android phone to [kGooglePlayUrl], and anything else
/// to a page with both. Add Phone's one download code, instead of one per store.
const kPhoneAppUrl = 'https://harness.autonomous.ai/app';
