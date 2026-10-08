defmodule KanbanWeb.ResourcesLive.HowTos.Account do
  @moduledoc """
  Guides for securing your own Stride account.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. The two-factor guide follows the
  wording of the Settings → Two-factor screens and the sign-in challenge
  (W2241, W2242); `docs/TWO-FACTOR-AUTHENTICATION.md` is the technical
  reference behind it.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "two-factor-authentication",
        title: "Setting Up Two-Factor Authentication",
        description:
          "Protect your account with a 6-digit code from an authenticator app, and keep the recovery codes that get you back in.",
        tags: ["security", "beginner"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-08],
        steps: [
          %{
            title: "What Two-Factor Adds",
            content:
              "With two-factor authentication on, signing in takes your password **and** a 6-digit code from an authenticator app on your phone or computer. Someone who learns your password still cannot get into your account without that code.\n\nTwo-factor is optional and applies only to you. The API tokens your agents use are not affected and keep working as before.",
            image: nil
          },
          %{
            title: "Before You Start",
            content:
              "You need two things:\n\n- **An authenticator app**, such as 1Password, Google Authenticator or Authy.\n- **A safe place for ten recovery codes**, such as a password manager or a printed copy kept somewhere secure. You will see them only once.",
            image: nil
          },
          %{
            title: "Open Two-Factor Settings",
            content:
              "Click the **Settings** gear at the bottom of the sidebar, then choose the **Two-factor** tab. If you have not signed in recently, Stride asks you to sign in again before showing your settings.\n\nUntil two-factor is on, Stride also shows a reminder card after you sign in; its **Set up two-factor authentication** button takes you to the same place. **Not now** hides the card for 10 days.",
            image: nil
          },
          %{
            title: "Scan the QR Code",
            content:
              "Click **Set up two-factor authentication**. Stride shows a QR code and the same **Key** as text. Scan the QR code with your authenticator app, or type the key into the app if it cannot scan.",
            image: nil
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
              "Stride now shows ten recovery codes. **Save them now — they will not be shown again.** Each code works once, either to sign in or to turn off two-factor, if you ever lose your authenticator.\n\nWhen they are safely stored, click **I have saved these codes**.",
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
              "Many authenticator apps (1Password, for example) sync to your new device, and then there is nothing to do.\n\nOtherwise, while you still have the old phone, click **Turn off two-factor**, enter a code from the old phone, and then set two-factor up again on the new one.",
            image: nil
          },
          %{
            title: "If You Lose Your Authenticator",
            content:
              "In this order:\n\n- Sign in using one of your recovery codes.\n- Go to **Settings → Two-factor** and click **Turn off two-factor**, entering another unused recovery code.\n- Set two-factor up again with your new authenticator, and save the new recovery codes.\n\nStride cannot turn off two-factor for you without one of your codes, so if you lose both your authenticator and your recovery codes you cannot get back into the account. Keep the recovery codes safe.",
            image: nil
          },
          %{
            title: "If a Code Is Refused",
            content:
              "- **Check your device's clock.** Codes depend on the time; turn on automatic time on your phone.\n- **Use the newest code.** Each code works once and only for about a minute and a half.\n- **Too many attempts?** After repeated wrong codes Stride stops accepting codes for a while: a few minutes at first, and up to a day after many failures. Recovery codes count toward the same limit, so wait, then try again.",
            image: nil
          }
        ]
      }
    ]
  end
end
