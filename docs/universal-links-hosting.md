# Universal Link hosting

`meeting-notes.jonabihl.dev` serves the association file for the signed macOS app and a generic fallback page. It contains no recordings, transcripts, meeting database or credentials. Keep the domain and `/meeting/<id>` route stable so links in old conversations keep working.

## Public endpoints

- `/.well-known/apple-app-site-association`: HTTP 200, `application/json`, no redirects. Associates the app with `/meeting/*` using the public application identifier in `hosting/apple-app-site-association`.
- `/meeting/<id>`: the same generic page for every ID. Its button constructs a native `meetingnotes://meeting/<id>` URL in the browser, preserving an optional passage (`p`) or time (`t`). Nothing opens automatically.
- `/`: the generic page without a meeting button.
- `/robots.txt`: disallows indexing. Responses also send `X-Robots-Tag`.

## Hosting requirements

Use an HTTPS host that serves the association file publicly without authentication or redirects. The files and reference server in `hosting/` are independent of the macOS app; they add no app runtime dependency. Deployment paths, service configuration and networking are environment-specific.

The fallback page loads only its own stylesheet and script, with no analytics, remote fonts or meeting lookup. Preserve its referrer policy to avoid forwarding meeting URLs when following other links. Do not log meeting URLs or enable browser network-error reporting for them. Configure any reverse proxy or CDN consistently, including removal of `NEL` and `Report-To` response headers. HTTPS requests and link previews still send their URLs to the hosting service and any intermediaries; an HTTPS link is not exclusively local to the Mac.

Keep association-file caching short enough to support updates and serve fallback pages with `Cache-Control: no-store`. Back up deployment configuration before changes and preserve unrelated services. Removing the host breaks HTTPS fallbacks and future app-association checks.

## Verification

```sh
python3 -m unittest discover -s hosting -p 'test_*.py'
node --check hosting/open.js
curl -i https://meeting-notes.jonabihl.dev/.well-known/apple-app-site-association
curl -i https://app-site-association.cdn-apple.com/a/v1/meeting-notes.jonabihl.dev
```

The Apple CDN response must contain the same app ID and components. CDN, DNS and device-association caches can delay changes. A valid CDN response does not establish app signing or client navigation behavior: test the signed app and real links on macOS separately.
