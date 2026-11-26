# The Stride Mobile Apps

> **Coming soon.** The Stride apps for iPhone, iPad and Android are not
> released yet, and they are not in the App Store or on Google Play. This guide
> describes how they will work, from the parts of Stride that are already
> built. The screens may change before the first release.

The Stride apps will be for the people who own, work on and review boards:
they will let you act on what your agents are waiting for from your phone or
tablet. They are not for agents. Agents keep using the API with their API
token, and the apps will never use one. The design behind the apps is in
[Native Mobile Apps, Phase 1](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).

## What the apps do

- **Now** will list the decisions waiting on you, ordered by how much each one
  holds up: reviews, tasks an agent released, claims that expired, goals whose
  `after_goal` hook failed, and Ready columns that are empty while an agent is
  idle.
- **Review** will show a task's review verdicts first, then the acceptance
  criteria, the security review, the behaviour matrix and the changed files,
  with the flagged ones first. You will approve or request changes from there.
- **Boards** will show each board's column counts and idle agents, and let you
  move several Backlog tasks to Ready in one step.
- **Agents** will show what each agent is working on and how its goals are
  moving.
- **Capture** will add a work task or a defect to a board's Backlog.
- **Targets and Goals** will show whether your delivery targets are on track
  and how each goal's tasks are moving.

You will not approve anything straight from a notification: a notification
will open the app on the decision. The apps will not create accounts, so you sign
up on the web first. Six kinds of Stride link will open the app instead of the
browser once it is installed
([which links open the app](universal-links.md#which-links-open-the-app)).

## Signing in

**Sign in** in the app will open a secure browser window on Stride's own
sign-in page, so the app never sees your password. The window shares Safari's
sign-ins, and your Organization's single sign-on and two-factor rules apply
exactly as they do on the web. On an iPhone or iPad, set a passcode first: the
app keeps a key for your approvals that needs one.

After you sign in, Stride shows a confirmation that names the device and the
email you are signed in as, with **Allow** and **Cancel**. Choose **Allow** only
if you just started signing in from the Stride app on that device. If the page
says "This sign-in request isn't valid", go back to the app and start signing
in again.

A device stays signed in while you use it. One you have not used for 30 days
will ask you to sign in again, and every device signs in again at least every
90 days. Developers can read the whole flow in
[Device sign-in: the OAuth flow](api/oauth.md).

## Notifications and quiet hours

The apps will send push notifications for the events you choose:

- **Decisions only**, the default, pushes when a review is requested, a task is
  released, a claim expires or a goal's hook fails.
- **Every event** adds a review being recorded, a goal being completed, a
  target's status changing and being mentioned.

Each of those eight can also be switched on or off on its own, in the Push
column of your notification preferences on the web, and in the app's Settings
once the app is out.

A push shows only the kind of event, the task's identifier and title, a
target's name and date, and counts. It never shows review notes, hook output,
code, comment text or who acted. Your Organization can also hide task titles
from pushes, so they read, for example, "W2701 is ready for review"
([the settings page](organization-security-policies.md#the-settings-page)).

**Quiet hours** are off until you turn them on. Then they run from 22:00 to
07:00 unless you choose other times. They follow the time zone in your push
settings, which is set from your first device and does not move when you
travel. A push due during quiet hours is held, not sent later, and if
decisions are still waiting when quiet hours end, one summary push tells you
how many
([quiet hours](push-notifications.md#quiet-hours)).

## Reviewing on a phone

A review will show what the reviewer found before the code: the summary, the
verdicts, the acceptance criteria, the security review, the behaviour matrix,
and the changed files with the flagged ones first. Opening a file will show its
diff with the reviewer's notes on the lines they are about. You will only see
reviews on boards you can change.

Approving will need Face ID, a fingerprint or your device passcode. The device
signs the approval with a key it keeps for that, and Stride checks the
signature, so an approval needs that device's key as well as your sign-in. A
retried approval or change request, such as one sent again on a poor
connection, is only recorded once.

### The size limit

A phone can approve a change of up to 10 files and 500 changed lines. A larger
change, or one whose size Stride cannot tell, is a large change: the app will
ask you to approve it on a tablet or on the web. You can still request changes
on the phone, whatever the size, and a tablet can approve any change. Stride
decides this on the server, not in the app
([size and approvable_here](api/me_reviews.md#size-and-approvable_here)).

Every approval and change request, on the web or in the app, is written to your
Organization's audit log as **Review approved** or **Review changes
requested**, with where it was made and the size of the change, never the notes
or the title.

## The status screens

- **Targets** will list every delivery target you can see, with its status (on
  track, at risk, missed or complete), its target date, its estimated
  completion, its task counts and whether you own it. The status is the web's,
  worked out in your phone's time zone.
- **A target** will show its goals and, when it is at risk, why: an estimate
  that slipped past the target date, or goals whose agents are stuck or dormant.
- **A goal** will show its tasks grouped by column, with the agent on each and
  how long it has been in its column.
- **Goals** will list every goal on your boards, filtered to open, done or no
  target, with how many of its reviews are waiting on you and whether its hook
  failed.

### Why only a target's owner opens it

On the web, a target's page opens only for the person who owns it, and the app
will never show more than the web does. So you will see every target you can
see in the Targets list, but only its owner can open it. For anyone else the
target answers "not found", which does not even say that it exists
([owner only](api/me_targets.md#owner-only)).

## Devices and revoking

Each phone or tablet you sign in is a device, named on the confirmation page.
You will see your devices in the app's Settings, and on the web in the Devices
section of your account settings, which appears once you have a device signed
in, or while the mobile app preview is on for you. Revoke a device there if you
lose it or stop using it. Signing out in the app will revoke that device too.

Your Organization's admins can see and revoke a member's devices from the
member's **Devices** button on the Organization page. Revoking a device signs
it out at once and closes its live connection. Each revocation is written to the
audit log as **Device revoked**, with whether you signed out, you or an admin
revoked it, or Stride revoked it because a token was used twice
([what a revocation records](api/me_devices.md#what-a-revocation-records)).

## The Organization plan

The apps are part of the Organization plan
([plans](organizations.md#plans)). Anyone with a Stride account can sign in.
Without the plan, the app will show what it does, that it is part of the
Organization plan, and a link to the pricing page. Stride checks the plan on
every request, and a board outside your Organization never appears in the app.
You can always see your devices and sign out, with or without the plan.

Where plans are not enforced, as on a self-hosted Stride, everything in the app
will be unlocked.

## For operators and developers

- [The person API: /api/me](api/me.md) and
  [Device sign-in: the OAuth flow](api/oauth.md) describe what the apps call.
- [iOS Sign-in](ios-sign-in.md) covers how the iOS app signs a device in.
- [Push Notifications](push-notifications.md) covers the push senders and the
  settings that turn each platform on.
- [Universal Links and App Links](universal-links.md) covers the files that
  let Stride links open the app.
- [The mobile app preview](feature-flags.md#the-mobile-app-preview) is the
  feature flag that shows the web's app controls before the apps ship.
