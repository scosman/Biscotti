# Registering Biscotti in Microsoft Entra ID

Biscotti reads the signed-in user's Microsoft 365 calendars through Microsoft
Graph so it can label recordings with the meeting they belong to. It needs
one app registration in your tenant. This guide is for the Entra
administrator who creates it.

**What Biscotti does with access:** it signs in as the user (delegated
permissions only), reads calendars and events, and never writes. Tokens stay
on the Mac: the refresh token is stored in the user's login keychain, and
the access token is held in memory only. There is no client secret and no
Biscotti server.

## 1. Create the registration

In the [Microsoft Entra admin center](https://entra.microsoft.com) go to
**Identity → Applications → App registrations → New registration**:

| Field | Value |
|---|---|
| Name | `Biscotti (Synderys)` (any name; users see it on the consent screen) |
| Supported account types | **Accounts in this organizational directory only** (single tenant) |
| Redirect URI → platform | **Public client/native (mobile & desktop)** |
| Redirect URI → value | `msauth.com.synderys.biscotti://auth` |

Select **Register**.

The redirect must be on the mobile & desktop platform, **not Web**. A Web
redirect makes Entra expect a client secret, and sign-in fails with
`AADSTS7000218`. To fix an existing registration: **Authentication → Add a
platform → iOS / macOS** with bundle ID `com.synderys.biscotti`. Entra then
generates the same `msauth.com.synderys.biscotti://auth` URI. Delete the Web
entry.

## 2. API permissions

**API permissions → Add a permission → Microsoft Graph → Delegated
permissions.** Add:

| Permission | Why |
|---|---|
| `openid`, `profile` | The user's name and sign-in address |
| `offline_access` | A refresh token, so the user isn't asked to sign in every hour |
| `User.Read` | Who "me" is, to mark the user's own attendance |
| `Calendars.Read` | The user's calendars and events |
| `Calendars.Read.Shared` | Calendars other people have shared with the user |

Then select **Grant admin consent for <tenant>**. None of these strictly
need admin consent. Granting it up front spares users the consent screen,
and it is required if your tenant blocks user consent.

## 3. Leave the rest at defaults

- **Certificates & secrets:** none. Biscotti is a public client and uses
  PKCE instead of a secret.
- **Authentication → Allow public client flows:** leave at **No**. It
  enables device-code and password flows, which Biscotti doesn't use. Turn
  it on only if `AADSTS7000218` persists after the redirect is on the
  mobile & desktop platform.
- **Token configuration:** no optional claims are needed.

## 4. Give Biscotti the IDs

From the registration's **Overview**, copy the **Application (client) ID**
and the **Directory (tenant) ID**. Biscotti reads them, in this order, from:

1. **User defaults, including MDM managed preferences.** For one Mac:

   ```sh
   defaults write com.synderys.biscotti MicrosoftGraphClientID <application-id>
   defaults write com.synderys.biscotti MicrosoftGraphTenantID <directory-id>
   ```

   For a fleet, push the same two keys with a configuration profile: a
   Custom Settings / Application & Custom Settings payload for the
   preference domain `com.synderys.biscotti`.

2. **The app's `Info.plist`,** under the same keys, for a build that ships
   with the IDs. `Info.plist` holds `$(MICROSOFT_GRAPH_CLIENT_ID)` and
   `$(MICROSOFT_GRAPH_TENANT_ID)` placeholders, which `make build-app` and
   `make release` fill from the git-ignored `Makefile.local`:

   ```make
   MICROSOFT_GRAPH_CLIENT_ID := <application-id>
   MICROSOFT_GRAPH_TENANT_ID := <directory-id>
   ```

   `make release` refuses to build without them. A build without them (CI,
   a fresh checkout) has blank values, which count as not configured.

Quit and reopen Biscotti after setting them. **Settings → Calendars →
Microsoft 365** then shows **Connect…** instead of "Not configured". The
tenant may be the directory ID or a verified domain (`synderys.com`). The
directory ID is better, because Biscotti then also checks that the signed-in
account belongs to it. `common`, `organizations` and `consumers` are
rejected.

## 5. What users see

1. **Connect…** opens a Microsoft sign-in sheet. It shares Safari's
   cookies, so a user already signed in to Microsoft 365 in Safari may
   only need to pick their account.
2. After sign-in, the row shows the account. Biscotti refreshes tokens
   silently from then on.
3. **Development builds only:** macOS asks once per build whether Biscotti
   may use the "com.synderys.biscotti.microsoft365" keychain item. Choose
   **Always Allow**. Builds signed with a Developer ID keep their identity
   and aren't asked again.
4. If the refresh token stops working (password reset, sessions revoked,
   a new Conditional Access requirement, 90 days unused), Home shows "Your
   Microsoft 365 sign-in has expired" with **Reconnect…**. Recording is
   never blocked.

**Disconnect…** deletes the keychain item on that Mac. To end the session
server-side as well, revoke the user's sessions in Entra (**Users → user →
Revoke sessions**).

## Troubleshooting

The red text under the row shows the first line of Entra's error,
including its `AADSTS` code.

| Code | Meaning | Fix |
|---|---|---|
| `AADSTS50011` | Redirect URI mismatch | Register exactly `msauth.com.synderys.biscotti://auth` (step 1) |
| `AADSTS7000218` | Entra expects a client secret | Move the redirect from Web to mobile & desktop (step 1) |
| `AADSTS700016` | Application not found in the directory | Check the client ID and tenant ID (step 4) |
| `AADSTS90002` | Tenant not found | Check the tenant ID or domain (step 4) |
| `AADSTS50020` | The account is from another tenant | Sign in with an account in this tenant; the registration is single-tenant |
| `AADSTS65001`, `AADSTS65004` | Consent missing or declined | Grant admin consent (step 2) |
| `AADSTS53000`, `AADSTS53003` | Blocked by Conditional Access | Check the sign-in log for the policy; device-compliance policies need a managed Mac |
| `AADSTS700082`, `AADSTS70043` | Refresh token expired | **Reconnect…** |

Biscotti logs sign-in events to the unified log (subsystem
`net.scosman.biscotti`, category `GraphAuth`), without tokens:

```sh
log show --last 1h --predicate 'subsystem == "net.scosman.biscotti" AND category == "GraphAuth"'
```
