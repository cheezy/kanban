defmodule KanbanWeb.ResourcesLive.HowTos.OrgAdmin do
  @moduledoc """
  Guides for an Organization's org-admins: the org console, the audit log,
  the security policy, single sign-on and SCIM provisioning.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits right after
  `HowTos.Organizations`, and every guide leads with the `organizations` tag,
  so navigation runs on from the member guides: accepting an invitation →
  the console → audit log → security policy → single sign-on → SCIM.

  The guides follow the `/org` LiveViews (`OrgLive.Console`,
  `OrgLive.AuditLog`, `OrgLive.Security`, `OrgLive.SSO`, `OrgLive.SCIM`).
  `docs/organizations.md`, `docs/organization-security-policies.md`,
  `docs/single-sign-on.md` and `docs/scim-provisioning.md` are the technical
  references behind them.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "administering-your-organization",
        title: "Administering Your Organization",
        description:
          "For org-admins: open the Organization console, see your details, remove members, and create, rename and archive workspaces.",
        tags: ["organizations", "admin"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Who This Guide Is For",
            content:
              "This guide is for org-admins. If you are one, the sidebar shows **Organization**, which opens the Organization console. Members don't see the link, and opening the console without being an org-admin sends you back to your boards.\n\nSome changes are made by Stride staff rather than org-admins: creating an Organization, changing its details, and appointing or removing org-admins.",
            image: nil
          },
          %{
            title: "The Organization Console",
            content:
              "The console has three tabs:\n\n- **Details**: your Organization's name, address and contact.\n- **Members**: everyone in the Organization.\n- **Workspaces**: where the Organization's boards live.\n\nThe buttons at the top open the other org-admin pages: **Security**, **Single sign-on**, **SCIM provisioning** and **Audit log**. The rest of this group covers each of them.",
            image: "/images/resources/guides/administering-your-organization-step-2.png",
            image_width: 1191,
            image_height: 352
          },
          %{
            title: "Details",
            content:
              "**Details** shows the **Name**, **Address**, **City and country**, **Contact name**, **Contact email** and **Contact phone** Stride has on file. They are read-only here. To change them, ask Stride staff.",
            image: nil
          },
          %{
            title: "Members",
            content:
              "**Members** lists everyone in the Organization, org-admins first, with each person's role: **Org-admin** or **Member**. **Disabled** marks an account that can't sign in, and **Unconfirmed** one that hasn't confirmed its email address yet.\n\n**Remove** takes a member out of the Organization. They leave every one of its workspaces, lose their board memberships and API tokens there, and their open tasks are unassigned. If your Organization uses single sign-on, a removed person can sign in again through it until your identity provider stops them.",
            image: "/images/resources/guides/administering-your-organization-step-4.png",
            image_width: 981,
            image_height: 228
          },
          %{
            title: "Org-Admins",
            content:
              "Org-admins have no **Remove** button. Stride staff appoint and remove org-admins.\n\nAn Organization that has other members always keeps at least one enabled org-admin, so someone can always manage it. Stride refuses to remove, disable or delete its last one until another org-admin is appointed.",
            image: nil
          },
          %{
            title: "Workspaces",
            content:
              "On **Workspaces**, type a **New workspace name** and click **Create workspace**. No two workspaces in the Organization can share a name, ignoring capitals.\n\n- **Rename** changes a workspace's name. Type the new one in **Workspace name** and click **Save**, or **Cancel**.\n- **Archive** removes a workspace that no longer holds any boards. Boards can't be moved out of a workspace, so their owners must delete them first. Archiving revokes the workspace's API tokens and open invitations, frees its name, and can't be undone.",
            image: "/images/resources/guides/administering-your-organization-step-6.png",
            image_width: 981,
            image_height: 245
          },
          %{
            title: "Inside a Workspace",
            content:
              "Who is in each workspace, invitations, workspace tokens and exports are managed from the workspace itself. [Working in a Workspace](/resources/working-in-a-workspace) covers those pages.",
            image: nil
          }
        ]
      },
      %{
        id: "reading-the-organization-audit-log",
        title: "Reading the Organization Audit Log",
        description:
          "For org-admins: find security events in your Organization's audit log, filter them, and export them as CSV or JSON.",
        tags: ["organizations", "admin"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "What the Audit Log Records",
            content:
              "The audit log keeps a record of security events in your Organization: changes to the Organization and its security policy, org-admins being appointed, members and workspaces being added or removed, single sign-on, domain and SCIM events, and refused requests. Only org-admins can open it.",
            image: nil
          },
          %{
            title: "Opening the Audit Log",
            content:
              "In the Organization console, click **Audit log**. **Organization audit log** lists events newest first, with the **Time (UTC)**, **Action**, **Actor**, **IP** and **Details** of each. All times are in UTC. **Back to Organization** returns to the console.",
            image: nil
          },
          %{
            title: "Filtering",
            content:
              "Choose an **Action** to see one kind of event. The list offers only the actions that have happened in your Organization, and **All actions** shows everything again. Set **From (UTC)** and **To (UTC)** to limit the dates.\n\n**Clear filters** removes them all. There is no filter by person, on purpose.",
            image: "/images/resources/guides/reading-the-organization-audit-log-step-3.png",
            image_width: 1162,
            image_height: 190
          },
          %{
            title: "Paging",
            content:
              "The log shows 50 events at a time. Click **Older events** to go further back, and use the newest-page button to return to the top. Changing a filter starts again from the newest events.",
            image: nil
          },
          %{
            title: "Actions Outside Your Organization",
            content:
              "Some events are made by people who aren't in your Organization, such as Stride staff appointing an org-admin. Their events still appear, but **Outside your Organization** replaces their name, and their email and IP address are not shown.\n\nEvents with no person behind them, such as a SCIM sync from your identity provider, show no actor.",
            image: "/images/resources/guides/reading-the-organization-audit-log-step-5.png",
            image_width: 1162,
            image_height: 312
          },
          %{
            title: "Exporting",
            content:
              "Click **Export CSV** or **Export JSON** to download the events that match your filters. An export holds at most the 50,000 newest matching events, so narrow the dates for a longer history.\n\nYou can export 10 times an hour, and each export is itself recorded in the log.",
            image: nil
          },
          %{
            title: "How Long Events Are Kept",
            content:
              "Events are kept forever unless your Organization sets a retention period. [Setting Your Organization's Security Policy](/resources/organization-security-policy) explains how.",
            image: nil
          }
        ]
      },
      %{
        id: "organization-security-policy",
        title: "Setting Your Organization's Security Policy",
        description:
          "For org-admins: require two-factor authentication for every member, choose a grace period, and decide how long audit events are kept.",
        tags: ["organizations", "admin"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Opening the Security Policy",
            content:
              "In the Organization console, click **Security**. Only org-admins can open or change this page. Both of its settings are saved together with **Save security policy**.",
            image: nil
          },
          %{
            title: "Requiring Two-Factor",
            content:
              "Under **Two-factor authentication**, tick **Require two-factor authentication for every member** and set the grace period: from 1 to 30 days, 7 unless you change it. Then click **Save security policy**.\n\nEach member's grace period counts from when you turned the requirement on or from when they joined, whichever is later.",
            image: "/images/resources/guides/organization-security-policy-step-2.png",
            image_width: 742,
            image_height: 251
          },
          %{
            title: "What Members See",
            content:
              "Until they turn two-factor on, members see a banner with their deadline that they can't dismiss. After the deadline, every signed-in page sends them to their two-factor settings until it is on. While it is required, they can't turn two-factor off. [Setting Up Two-Factor Authentication](/resources/two-factor-authentication) is the guide to send them.\n\nMembers who sign in through single sign-on are not affected, because your identity provider handles the second step. API tokens keep working either way.",
            image: nil
          },
          %{
            title: "Changing the Grace Period",
            content:
              "Shortening the grace period while the requirement is on restarts everyone's clock from that moment, so nobody's deadline jumps into the past. Lengthening it simply moves the deadlines later. Turning the requirement off and on again also restarts the clock.",
            image: nil
          },
          %{
            title: "Audit Log Retention",
            content:
              "Under **Audit log retention**, enter how many days to keep your Organization's audit events, from 90 to 3650, and click **Save security policy**. A daily job then removes older events.\n\nLeave the field empty, as its **Keep forever** placeholder says, to keep every event.",
            image: "/images/resources/guides/organization-security-policy-step-5.png",
            image_width: 742,
            image_height: 257
          }
        ]
      },
      %{
        id: "setting-up-single-sign-on",
        title: "Setting Up Single Sign-On",
        description:
          "For org-admins: verify your email domains, connect an OpenID Connect or SAML identity provider, and let your people sign in with it.",
        tags: ["organizations", "admin"],
        content_type: "guide",
        reading_time: 7,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "How Single Sign-On Works",
            content:
              "With single sign-on, people whose email address is on one of your verified domains sign in through your identity provider, which also handles their multi-factor authentication. Someone new gets an account and joins your Organization as a member. Single sign-on never makes anyone an org-admin.\n\nMembers who have a password can still sign in with it. Stride has no setting that limits your Organization to single sign-on.\n\nIn the Organization console, click **Single sign-on** to set it up. Only org-admins can open this page.",
            image: nil
          },
          %{
            title: "Verifying a Domain",
            content:
              "Under **Verified domains**, enter an **Email domain** such as your company's and click **Add domain**. Stride shows a **TXT record name**, which is `_stride-verification.` followed by the domain, and a **TXT record value**, which starts with `stride-verification=`.\n\nAdd that TXT record with your DNS provider, then click **Verify**. The domain is marked **Verified**, or **Not verified** until the record is found. DNS changes can take a while to appear, so try again later if it isn't found yet. Only one Organization can verify a domain.",
            image: "/images/resources/guides/setting-up-single-sign-on-step-2.png",
            image_width: 742,
            image_height: 202
          },
          %{
            title: "Keeping a Domain Verified",
            content:
              "Keep the TXT record in place. Stride checks it every day, and after 3 checks in a row without it, the domain is no longer verified and single sign-on stops for its addresses. People already in your Organization stay members.\n\n**Remove** deletes a domain, and its people can no longer use single sign-on.",
            image: nil
          },
          %{
            title: "Connecting an OpenID Connect Provider",
            content:
              "Under **OpenID Connect identity provider**, copy the **Redirect URI** into a new application in your identity provider. Then enter the provider's **Issuer URL** (a public https address), **Client ID** and **Client secret**, tick **Allow sign-in through this identity provider**, and click **Save connection**.\n\nOnce saved, the client secret is never shown again. Leave the field blank to keep it when you change something else.",
            image: "/images/resources/guides/setting-up-single-sign-on-step-4.png",
            image_width: 742,
            image_height: 510
          },
          %{
            title: "Connecting a SAML Provider",
            content:
              "If your identity provider only speaks SAML 2.0, use **SAML identity provider** instead. Give your provider Stride's **Stride entity ID** and **Assertion consumer service URL**, or click **Download Stride's SP metadata** to give it a metadata file.\n\nThen paste the provider's **Identity provider metadata XML**, which fills in the rest, or enter its **Identity provider entity ID**, **Single sign-on URL** and **Signing certificates (PEM)**. Stride keeps up to two certificates, so you can rotate them. Tick **Allow sign-in through this SAML identity provider** and click **Save SAML connection**.",
            image: "/images/resources/guides/setting-up-single-sign-on-step-5.png",
            image_width: 742,
            image_height: 529
          },
          %{
            title: "How People Sign In",
            content:
              "On the sign-in page, people enter their address in **Work email for single sign-on** and click **Sign in with SSO**. Stride sends them to your identity provider and back.\n\nSigning in this way satisfies your Organization's two-factor requirement.",
            image: nil
          },
          %{
            title: "When Someone Leaves",
            content:
              "Removing someone from your Organization doesn't stop them signing in again through single sign-on, which would add them back. Remove or disable them in your identity provider too, or let SCIM do it: see [Provisioning Users With SCIM](/resources/provisioning-users-with-scim).",
            image: nil
          }
        ]
      },
      %{
        id: "provisioning-users-with-scim",
        title: "Provisioning Users With SCIM",
        description:
          "For org-admins: let your identity provider add people, keep workspace memberships in step with its groups, and remove access when it deprovisions someone.",
        tags: ["organizations", "admin"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "What SCIM Does",
            content:
              "SCIM lets your identity provider manage your Organization's people for you:\n\n- It adds people, who must have an address on one of your verified domains. See [Setting Up Single Sign-On](/resources/setting-up-single-sign-on).\n- Each of your workspaces is a group in your provider. Adding someone to the group adds them to the workspace, and removing them removes them from the workspace and its boards.\n- When your provider deprovisions someone, they lose their place in the Organization at once.\n\nCreating, renaming and archiving workspaces stays in the Organization console. In the console, click **SCIM provisioning** to set it up. Only org-admins can open this page.",
            image: nil
          },
          %{
            title: "The SCIM Base URL",
            content:
              "**SCIM base URL** shows the address to enter in your identity provider's SCIM settings, together with a token from the next step.",
            image: "/images/resources/guides/provisioning-users-with-scim-step-2.png",
            image_width: 742,
            image_height: 371
          },
          %{
            title: "Creating a Token",
            content:
              "Under **Create a SCIM token**, enter a **Token name**, such as the name of your identity provider, and click **Create token**.\n\n**Your new SCIM token** appears once. Click **Copy** and paste it into your identity provider straight away: Stride keeps only a fingerprint of it, so it can't be shown again. A SCIM token can add, change and remove your people, so give it only to your identity provider.",
            image: nil
          },
          %{
            title: "Managing Tokens",
            content:
              "**SCIM tokens** lists every token, who created it, when it was last used, and whether it is **Active** or **Revoked**.\n\n**Revoke** stops a token at once, and it can't be restored. To rotate a token, create the new one, give it to your identity provider, then revoke the old one.",
            image: nil
          },
          %{
            title: "Org-Admins and Deprovisioning",
            content:
              "Your identity provider can't deprovision your Organization's last enabled org-admin while it has other members. Stride refuses, and the person stays until Stride staff appoint another org-admin.",
            image: nil
          }
        ]
      }
    ]
  end
end
