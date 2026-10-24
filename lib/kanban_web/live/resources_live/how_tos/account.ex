defmodule KanbanWeb.ResourcesLive.HowTos.Account do
  @moduledoc """
  Guides for managing and securing your own Stride account.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. Both guides lead with the `security`
  tag, so security navigation runs Managing Your Account → two-factor →
  API authentication.

  The account guide follows the Settings screens (`UserLive.Settings`,
  `UserLive.SettingsComponents`, `UserLive.DangerZoneComponent`). The
  two-factor guide follows the Settings → Two-factor screens, the sign-in
  challenge and the Organization requirement banner (W2241, W2242, W2347);
  `docs/TWO-FACTOR-AUTHENTICATION.md` is the technical reference behind it.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "managing-your-account",
        title: "Managing Your Account",
        description:
          "Change your name, email and password, see how single sign-on applies to you, and delete your account when you no longer need it.",
        tags: ["security", "beginner"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-10-23],
        steps: [
          %{
            title: "Opening Settings",
            content:
              "Click the **Settings** gear at the bottom of the sidebar. Settings holds your email, password and sign-in options, so Stride opens it only if you signed in within the last 10 minutes.\n\nIf it has been longer, Stride shows the sign-in page with \"You must re-authenticate to access this page.\" Sign in again, with your two-factor code too if two-factor is on, and Stride takes you to Settings.",
            image: "/images/resources/guides/managing-your-account-step-1.png",
            image_width: 476,
            image_height: 385
          },
          %{
            title: "The Settings Tabs",
            content:
              "Settings has five tabs:\n\n- **Profile**: your name and email address.\n- **Password**: change the password you sign in with.\n- **Two-factor**: add a code from an authenticator app to signing in.\n- **Single sign-on**: whether you sign in through your Organization's identity provider.\n- **Delete account**: remove your account for good.\n\nBelow the tabs, **Notifications** opens a separate page where you choose which in-app and email notifications you get. See [Notification preferences](/users/notifications).\n\nChanges you save apply to your account straight away.",
            image: "/images/resources/guides/managing-your-account-step-2.png",
            image_width: 1189,
            image_height: 392
          },
          %{
            title: "Changing Your Name or Email",
            content:
              "On **Profile**, edit **Name** or **Email** and click **Update profile**.\n\nA new name is saved at once. A new email address is not: Stride sends a link to the new address, and your email changes only when you click that link. Until then you keep signing in with the old address. The link works for 7 days.",
            image: nil
          },
          %{
            title: "Changing Your Password",
            content:
              "On **Password**, type your **New password**, type it again in **Confirm new password**, and click **Save password**.\n\nA password must be 12 to 72 characters long, and there are no other rules, so a long passphrase works well. The 72 counts bytes, so accented letters and emoji use up more of it.\n\nSaving a new password signs you out on every other device and browser. This one stays signed in.",
            image: "/images/resources/guides/managing-your-account-step-4.png",
            image_width: 980,
            image_height: 303
          },
          %{
            title: "Turning On Two-Factor",
            content:
              "The **Two-factor** tab adds a second step to signing in: a 6-digit code from an authenticator app on your phone or computer. [Setting Up Two-Factor Authentication](/resources/two-factor-authentication) walks through turning it on, saving your recovery codes, and what to do if you lose your phone.",
            image: nil
          },
          %{
            title: "Single Sign-On",
            content:
              "The **Single sign-on** tab tells you whether your account signs in through your Organization's identity provider, which then also handles multi-factor authentication.\n\n- If it does, use **Sign in with SSO** on the sign-in page instead of your password.\n- If it does not, your Organization's org-admins set single sign-on up in the org console. Once your email domain is verified there, **Sign in with SSO** works for you too.\n\nWhen Stride's plans are switched on, an account that does not belong to an Organization sees a lock on this tab instead.",
            image: "/images/resources/guides/managing-your-account-step-6.png",
            image_width: 980,
            image_height: 138
          },
          %{
            title: "Before You Can Delete Your Account",
            content:
              "Deleting your account signs you out everywhere and removes your API tokens, your memberships, and the boards in your personal workspace that only you use. Boards other people still use stay with them, boards in an Organization's workspace stay with the Organization, and the tasks and comments you added there are kept without your name.\n\nOn **Delete account**, Stride first lists anything that stops you deleting it:\n\n- A board you own that other people use. Choose one of its members in **Transfer ownership to** and click **Transfer ownership**, or click **Open its members** to change who is on it.\n- Being the last org-admin of an Organization that has other members. A Stride admin must appoint another org-admin first.\n- Being the last site admin. Make another user a site admin first.\n\nThe **Delete my account** button appears only once that list is empty.",
            image: "/images/resources/guides/managing-your-account-step-7.png",
            image_width: 980,
            image_height: 391
          },
          %{
            title: "Deleting Your Account",
            content:
              "Click **Delete my account**. In the window that opens, enter your **Password**, type `delete my account` exactly as shown, and click **Permanently delete my account**. The button stays off until the phrase matches. Stride then signs you out, and the account cannot be restored. **Cancel** closes the window without deleting anything.\n\nAfter a few wrong passwords, Stride makes you wait a few minutes before trying again.\n\nIf you have only ever signed in with single sign-on, your account may have no password. Use **Forgot?** on the sign-in page to set one first.",
            image: nil
          }
        ]
      },
      %{
        id: "two-factor-authentication",
        title: "Setting Up Two-Factor Authentication",
        description:
          "Protect your account with a 6-digit code from an authenticator app, and keep the recovery codes that get you back in.",
        tags: ["security", "beginner"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-10-08],
        steps: [
          %{
            title: "What Two-Factor Adds",
            content:
              "With two-factor authentication on, signing in takes your password and a 6-digit code from an authenticator app on your phone or computer. Someone who learns your password still cannot get into your account without that code.\n\nTwo-factor is optional, unless an Organization you belong to requires it (see When Your Organization Requires Two-Factor). The API tokens your agents use are not affected and keep working as before.",
            image: nil
          },
          %{
            title: "Before You Start",
            content:
              "You need two things:\n\n- An authenticator app, such as 1Password, Google Authenticator or Authy.\n- A safe place for ten recovery codes, such as a password manager or a printed copy kept somewhere secure. You will see them only once.",
            image: nil
          },
          %{
            title: "Open Two-Factor Settings",
            content:
              "Click the **Settings** gear at the bottom of the sidebar, then choose the **Two-factor** tab. If you have not signed in within the last 10 minutes, Stride asks you to sign in again before showing your settings.\n\nUntil two-factor is on, Stride also shows a reminder card on the first page after you sign in with your password; its **Set up two-factor authentication** button takes you to the same place. **Not now** hides the card for 10 days. The card does not appear while your Organization's two-factor banner is showing.",
            image: "/images/resources/guides/two-factor-authentication-step-3.png",
            image_width: 980,
            image_height: 230
          },
          %{
            title: "When Your Organization Requires Two-Factor",
            content:
              "An org-admin can require two-factor for every member of their Organization. Until you turn it on, a banner headed **Your Organization requires two-factor authentication** shows the date and time (in UTC) to turn it on by, with a **Set up two-factor authentication** button. Unlike the reminder card, the banner cannot be dismissed.\n\nThe org-admin chooses the grace period, from 1 to 30 days (7 unless they change it). It counts from when they turned the requirement on or from when you joined, whichever is later. After the deadline, opening a board or any other signed-in page sends you to **Settings → Two-factor** until two-factor is on. Public pages, such as these guides, stay open. While it is required, you cannot turn two-factor off.\n\nSigning in with **Sign in with SSO** through your Organization's identity provider satisfies the requirement, because the provider handles the second step. The first single sign-on sign-in to an account that already has two-factor on asks for your code once.",
            image: nil
          },
          %{
            title: "Scan the QR Code",
            content:
              "Click **Set up two-factor authentication**. Stride shows a QR code and the same **Key** as text. Scan the QR code with your authenticator app, or type the key into the app if it cannot scan.",
            image: "/images/resources/guides/two-factor-authentication-step-5.png",
            image_width: 980,
            image_height: 506
          },
          %{
            title: "Verify and Turn It On",
            content:
              "Type the code your app now shows into **6-digit code** and click **Verify and turn on**. Two-factor is on only once that code is accepted.\n\nIf you click **Cancel** or leave the page before then, two-factor stays off. Starting again creates a new key, so delete the old Stride entry from your app.",
            image: nil
          },
          %{
            title: "Save Your Recovery Codes",
            content:
              "Stride now shows ten recovery codes and the warning **Save these recovery codes now. They will not be shown again.** Each code works once, either to sign in or to turn off two-factor, if you ever lose your authenticator.\n\nWhen they are safely stored, click **I have saved these codes**.",
            image: nil
          },
          %{
            title: "Signing In",
            content:
              "Sign in with your email and password as usual. Stride then asks for the 6-digit code from your authenticator app. Enter it within five minutes, or start again from your password.\n\nIf you ticked **Keep me signed in on this device**, Stride remembers that once the code is accepted.",
            image: nil
          },
          %{
            title: "Signing In With a Recovery Code",
            content:
              "If you do not have your authenticator, click **Use a recovery code instead** on the code page and enter one of your saved codes. Spaces, dashes and capital letters do not matter.\n\nThat code is now used up. Create a fresh set as soon as you are signed in (next step).",
            image: nil
          },
          %{
            title: "Getting New Recovery Codes",
            content:
              "Under **Settings → Two-factor**, find **New recovery codes**, enter a current 6-digit code from your app and click **Generate new codes**. All of your old codes stop working straight away, so save the new ten in their place.",
            image: nil
          },
          %{
            title: "Moving to a New Phone",
            content:
              "Many authenticator apps (1Password, for example) sync to your new device, and then there is nothing to do.\n\nOtherwise, while you still have the old phone, click **Turn off two-factor**, enter a code from the old phone, and then set two-factor up again on the new one.\n\nIf your Organization requires two-factor, the **Turn off two-factor** section says so and has no button. Move the Stride entry to the new phone with your authenticator app's own transfer or sync before you give up the old one.",
            image: nil
          },
          %{
            title: "If You Lose Your Authenticator",
            content:
              "In this order:\n\n- Sign in using one of your recovery codes.\n- Go to **Settings → Two-factor** and click **Turn off two-factor**, entering another unused recovery code.\n- Set two-factor up again with your new authenticator, and save the new recovery codes.\n\nStride cannot turn off two-factor for you without one of your codes, so if you lose both your authenticator and your recovery codes you cannot get back into the account. Keep the recovery codes safe.\n\nIf your Organization requires two-factor, you cannot turn it off, and **Generate new codes** needs a code from your authenticator. Each saved recovery code still signs you in once, but there is no way to move to a new authenticator while the requirement is on.",
            image: nil
          },
          %{
            title: "If a Code Is Refused",
            content:
              "- Check your device's clock. Codes depend on the time; turn on automatic time on your phone.\n- Use the newest code. Each code works once and only for about a minute and a half.\n- Too many attempts? After repeated wrong codes Stride stops accepting codes for a while: a few minutes at first, and up to a day after many failures. Recovery codes count toward the same limit, so wait, then try again.",
            image: nil
          }
        ]
      }
    ]
  end
end
