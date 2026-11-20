# Universal Links and App Links

A link to a Stride page opens the Stride app instead of the browser when the
phone has the app installed and the page is one the app shows. iOS calls these
universal links and Android calls them App Links. Both work only when this site
publishes a file saying which app may handle its links. Stride serves both
files (W2764, design §6.20 in
[NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md)):

| Path | For | Content |
|---|---|---|
| `/.well-known/apple-app-site-association` | iOS | `applinks.details`, with the app id and the paths that open the app |
| `/.well-known/assetlinks.json` | Android | One `handle_all_urls` statement, with the package name and certificate fingerprints |

Both are public JSON (`application/json`), served to anyone without signing in.
They go through the router's `:well_known` pipeline next to the audit signing
keys, which fetches no session, sets no cookie, checks no CSRF token and never
redirects. Apple and Google refuse a file behind a redirect, so these routes
must never move to the `:browser` pipeline. The Apple file has no extension.
Both send `cache-control: public, max-age=3600`.

`KanbanWeb.AppLinksController` builds both files.

## Which links open the app

Only these six pages open the app. Every other link stays in the browser.

| Page | Path |
|---|---|
| Review queue | `/review` |
| Agents | `/agents` |
| Board | `/boards/:id` |
| Goal | `/boards/:id/goals/:goal_id` |
| Task | `/boards/:id/tasks/:task_id/edit` |
| Target | `/targets/:id` |

The Apple file lists them as `components`, which Apple reads in order, where
the first pattern that matches decides. In a pattern `*` matches any run of
characters, `/` included, and `?` exactly one. So `/boards/?*` on its own
would also match `/boards/new` and `/boards/7/settings`. Each wildcard is
therefore preceded by `exclude` entries for the routes it would otherwise
catch, and no entry is a bare `*`. The controller test reads the served list
and checks it against every GET route in the router, so a new route that
one of the patterns would catch fails that test until the list excludes it.

The Android file has no paths. An Android app declares the paths it handles in
the intent filters of its own manifest. This file only says which signed app
may handle this host's links.

## Environment variables

`config/runtime.exs` reads these variables in every environment. Each value is
trimmed, and a value that is empty or only whitespace counts as unset. Each
platform is listed only when all of its variables are set; with none set, both
files list no apps.

| Variable | Platform | Value |
|---|---|---|
| `STRIDE_IOS_TEAM_ID` | iOS | The 10-character Apple team id, in capitals |
| `STRIDE_IOS_BUNDLE_ID` | iOS | The iOS app's bundle id, such as `com.example.stride` |
| `STRIDE_ANDROID_PACKAGE` | Android | The Android app's package name |
| `STRIDE_ANDROID_CERT_FINGERPRINTS` | Android | The SHA-256 fingerprints of the app's signing certificates, comma-separated, each as 32 hex pairs joined by colons (`AA:BB:…`). Case does not matter. List the Play app signing certificate and, for builds you install yourself, the upload certificate |

The Apple app id is the team id and the bundle id joined by a dot. These cases
stop the boot with an error that names the variable and never prints its
value:

- One of a platform's variables is set without the other.
- A value does not have its shape.

Every value here is public: Apple and Google publish nothing secret in these
files. Never put a signing key, a keystore password or any other secret in
these variables. These are separate from `APNS_TEAM_ID` and `APNS_TOPIC`
([Push Notifications](push-notifications.md)), so links work on a server that
sends no pushes.

In tests, `config/test.exs` sets fake ids for both platforms. In development,
nothing is set, so both files list no apps.

## Checking a deployment

After setting the variables, fetch both files and check the ids:

```bash
curl -i https://<host>/.well-known/apple-app-site-association
curl -i https://<host>/.well-known/assetlinks.json
```

Each answers `200` with `application/json` and no `location` or `set-cookie`
header. Then run each file through its platform's validator: Apple's App
Search API Validation Tool or `swcutil` on a Mac for the Apple file, and
Google's Statement List Generator and Tester for the Android file.
