# Cat Snake Analytics

## Current Firebase prerequisite

The Firebase project `cat-snake` does not currently have Google Analytics
enabled. The public web app configuration therefore has no GA4 measurement ID.
The game safely falls back when Analytics is unavailable, but no events can be
received until this project-level prerequisite is completed.

In the Firebase console:

1. Open **Cat Snake → Project settings → Integrations**.
2. In **Google Analytics**, choose **Enable Google Analytics**.
3. Select the intended Google Analytics account or create the requested GA4
   property. Do not guess here: the account/property owner must make this
   choice.
4. Finish the integration wizard.
5. In Google Analytics open **Admin → Data streams → Web** and verify that the
   Cat Snake stream uses
   `https://mexx-music.github.io/cat-snake-web/`.
6. Refresh the FlutterFire web configuration (`flutterfire configure`) and
   verify that `lib/firebase_options.dart` contains the resulting `G-...`
   measurement ID. With recent web SDKs this value can be fetched dynamically,
   but keeping it in the config is the reliable fallback for GitHub Pages.

## Events

The initial landing uses GA4's normal automatic `page_view`. Cat Snake does not
send a duplicate `landing_open` event.

### `game_start`

Sent exactly once when a real round starts:

- `level_name`: `meadow`, `living_room`, or `garden`
- `level_index`: `1`, `2`, or `3`
- `board_layout`: `standard` or `phone_portrait`
- `language`: `de` or `en`

### `game_over`

Sent exactly once when a real round ends:

- `level_name`
- `level_index`
- `score`
- `snake_length`
- `round_duration_seconds`
- `end_reason`: `wall`, `self`, or `obstacle`

The duration counts only active round time. Manual pauses, the leaderboard
overlay, and time in the browser background are excluded. Promo scenes always
use a no-op analytics service and never send events.

No player name, email address, Firebase UID, free text, or UTM value is copied
into an Analytics event or user property.

## Campaign links

The existing standard links remain unchanged. GA4 reads the campaign fields
from the landing page URL:

```text
https://mexx-music.github.io/cat-snake-web/?utm_source=telegram&utm_medium=channel&utm_campaign=catsnake_test01
```

```text
https://mexx-music.github.io/cat-snake-web/?utm_source=tiktok&utm_medium=organic&utm_campaign=launch01
```

Optional `utm_content` and `utm_term` can be appended. Never put names, email
addresses, account IDs, or other personal data into UTM values.

## Realtime and DebugView verification

This check requires Analytics to be enabled, the updated measurement ID to be
deployed, and the live GitHub Pages build to be online.

1. In Chrome, enable Analytics debug mode with the Google Analytics Debugger
   extension, or connect the site through Google Tag Assistant.
2. Open the Telegram test URL above in that debug browser.
3. Open **GA4 → Admin → DebugView** (or Firebase → Analytics → DebugView).
4. Confirm the automatic `page_view`.
5. Start one real round and confirm one `game_start` with the expected level,
   layout, and language parameters.
6. End the round and confirm one `game_over` with score, duration, snake length,
   and end reason.
7. In **GA4 → Reports → Realtime**, confirm the same events without relying on
   debug mode.
8. After standard processing, open **Reports → Acquisition → Traffic
   acquisition** and verify:
   - Session source: `telegram`
   - Session medium: `channel`
   - Session campaign: `catsnake_test01`

If the three campaign dimensions are not populated after a real deployed test,
stop before adding a custom UTM parser and diagnose the web stream/tag first.

## GA4 custom definitions

In **GA4 → Admin → Custom definitions**, create these event-scoped definitions:

| Display name | Scope | Event parameter |
| --- | --- | --- |
| Level name | Event | `level_name` |
| Board layout | Event | `board_layout` |
| End reason | Event | `end_reason` |

Create these event-scoped custom metrics:

| Display name | Event parameter | Unit |
| --- | --- | --- |
| Score | `score` | Standard |
| Snake length | `snake_length` | Standard |
| Round duration | `round_duration_seconds` | Seconds |

## Funnel

In **GA4 → Explore → Funnel exploration**, create a closed funnel:

1. `page_view`
2. `game_start`
3. `game_over`

Break down or filter the exploration using Session source, Session medium, and
Session campaign. For the Telegram test campaign use `telegram`, `channel`, and
`catsnake_test01` respectively.
