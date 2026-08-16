# Hub WebView Authentication Design

## Purpose

This feature signs an ArzDigital app user into Hub during the first topic
request opened in a WebView. The app does not redirect through Accounts or IDP,
and no access token is placed in the URL.

## Request Flow

```text
App WebView
  GET https://hub.arzdigital.com/t/<topic>
  Authorization: Bearer <app access token>

Hub plugin
  GET https://idp.arzdigital.com/hub/v1/webview-user
  Authorization: Bearer <same access token>
  X-Hub-Signature: HMAC-SHA256(access token, DiscourseConnect secret)

IDP
  validates Hub signature and app access token
  returns the minimal Discourse identity

Hub plugin
  resolves or creates the user through DiscourseConnect
  creates the standard Discourse session cookie
  continues the original topic request as that user
```

The final page request does not redirect. If IDP is unavailable, the token is
invalid, or identity synchronization fails, Hub intentionally continues as an
anonymous visitor.

## Scope

Only a `GET` request whose path starts with `/t/` can trigger this feature. A
normal browser session is never replaced: if Hub already has a current user,
the WebView Authorization header is ignored.

## Required IDP Contract

Hub calls this endpoint only from its backend:

```http
GET https://idp.arzdigital.com/hub/v1/webview-user
Authorization: Bearer <access-token>
X-Hub-Signature: <lowercase hex HMAC-SHA256 of the raw token>
```

The HMAC key is the same secret configured in Hub as
`discourse_connect_secret` and in IDP as `DISCOURSE_SSO_SECRET`.

A successful response contains a JSON `data` object with:

```json
{
  "external_id": "629705",
  "email": "user@example.com",
  "username": "username",
  "name": "User Name",
  "avatar_url": "https://...",
  "avatar_force_update": true,
  "website": "",
  "add_groups": [],
  "remove_groups": ["verified"],
  "suppress_welcome_message": true
}
```

`external_id` is the stable mapping between IDP and Discourse. The plugin uses
DiscourseConnect's `lookup_or_create_user`, so the normal SSO user-creation,
profile synchronization, avatar, and group rules remain shared with browser
login.

## Settings

Enable the feature after deployment in Admin > Settings:

- `discourse_arz_tools_webview_auth_enabled`: master switch. Default: `false`.
- `discourse_arz_tools_webview_auth_idp_url`: IDP endpoint. Default:
  `https://idp.arzdigital.com/hub/v1/webview-user`.
- `discourse_arz_tools_webview_auth_timeout_seconds`: backend IDP timeout.
  Default: `2`; allowed range: `1` to `10`.

`discourse_arz_tools_enabled` must also remain enabled.

## Security Rules

- The app access token is accepted only in the initial WebView
  `Authorization` header.
- Hub forwards it only to the configured HTTPS IDP endpoint.
- Neither Hub nor IDP logs or persists the app access token.
- The HMAC header proves to IDP that the backend request came from Hub.
- The session created for Hub is the normal secure Discourse session cookie;
  later WebView requests do not need the app token.
- Errors deliberately do not reveal whether a token, user, or IDP service
  caused the fallback to guest access.

## Deployment and Verification

1. Deploy the plugin revision and rebuild/restart Discourse so `plugin.rb` is
   loaded.
2. In Admin > Settings, enable `discourse_arz_tools_webview_auth_enabled`.
3. Open a Hub topic in a WebView with a valid access token in the request
   header.
4. Confirm the topic shows the authenticated user and a subsequent request,
   without the Authorization header, remains logged in through the Hub cookie.
5. Confirm an invalid or expired token still shows the topic as a guest.

For plugin request specs, run from the Discourse checkout:

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec
```
