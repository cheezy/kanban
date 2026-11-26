# iOS App Shell

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. It describes the shell the app shows once a device is signed in:
the four tabs, the corner buttons, the Now badge and how the shell chooses
between a tab bar and a sidebar. How the device gets signed in is in
[iOS Sign-in](ios-sign-in.md).

## Which screen fills the window

`RootScreen` decides, from the update state and the sign-in phase, and
`RootView` shows what it picks:

| Screen | When |
|---|---|
| Update required | The server answered 426, whatever else holds. |
| Sign in | Signed out, signing in, or signed in to a plan without the app (the locked panel). |
| The background alone | The Keychain or `/api/me` has not answered yet. |
| The shell | Signed in, and the plan includes the app or the server could not say. |

Whenever the screen stops being the shell, `AppRouter.follow(_:)` clears what
the shell held: the selected tab, every tab's stack, any open sheet, the
person's name and the badge. A sign-out from any tab therefore leaves nothing of
the person on screen, and an answer that set out before the sign-out is dropped.

## The tabs

The shell has four tabs: **Now**, **Review**, **Boards** and **Agents**. In a
compact width, as on a phone or an iPad in a narrow split view, they sit in a
tab bar. In a regular width they are the rows of a `NavigationSplitView`
sidebar. Each tab has its own `NavigationStack`, whose path `AppRouter` keeps
per tab:

- Switching tabs keeps each tab's stack.
- Selecting the tab already selected takes it back to its first screen.
- `push(_:on:)` adds a screen to a tab without leaving the selected one.
- `show(_:on:)` opens a tab on one screen, as a deep link will.

The screens the tabs will hold are still to be built, so each tab shows only its
title.

## The corner buttons and the badge

**New task** and the person's avatar, which opens **Settings**, sit in the top
corner of Now on a phone and above the sidebar's tabs on an iPad, where every
tab can reach them. They are a row in the screen, above the large title, rather
than navigation bar items, because bar items do not grow with the text size.
Each tab's first screen hides the navigation bar; the screens pushed after it
show theirs, with the back button (`TabRoot(tab:isPushed:)`, until each route's
own screen is built). On an iPad the first screen shows its empty bar only while the
sidebar is hidden, because the button that brings the sidebar back is then in
that bar. Each corner button is a 44-point target. The two buttons each open a sheet with a **Close** button and the
sheet's title until its own screen is built; both are in the sheet's content
for the same reason, and because the audit fails the contrast of a glass bar
button. The avatar shows the person's initials from `GET /api/me`, and VoiceOver
reads it as Settings.

The Now tab's badge is `summary.waiting` from `GET /api/me/decisions`: every
item waiting on the person, counted before the list's cap of 100. A count of
zero hides the badge. On a phone it is the tab bar's badge; in the sidebar the
row draws the count as a pill of ink on surface, which reads the same on the
selected row and the other rows, in light and dark, because a list badge fails
the contrast audit on the selected row. VoiceOver reads the count as the tab's
value, as it reads a badge.

Each sidebar row is a plain button that draws its own selection, as the design
does: `stride-orange-ink` text on a `stride-orange-soft` background, with the
selected trait for VoiceOver. The list's own selection sometimes fills the row
with the tint and draws white text on it, which in dark, where the tint is
light, falls far below 4.5:1. The shell asks for both again each time the app
becomes active, and a failed answer leaves what it already shows.

## Seeing and testing it

Start a debug build with `-StrideStubSignIn allow` and press **Sign in**: the
shell then reads the fixtures in `mobile/shared/fixtures/`, so Now shows a badge
of 4 and the avatar reads "Alex Example". `AppRouterTests` covers the screen
choice, the stacks and the badge, and `ShellUITests` opens every tab in light
and dark, the two sheets and the German tab names at the largest text size,
auditing each for accessibility, and hides the iPad's sidebar and brings it
back.
