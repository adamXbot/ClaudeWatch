# Releasing ClaudeWatch

Releases are produced by the **`release`** job in
[`.github/workflows/build.yml`](.github/workflows/build.yml). It runs automatically
when you push a tag matching `v*`.

```sh
git tag v1.0.0
git push origin v1.0.0
```

The job:

1. Builds `ClaudeWatch.app` with the version taken from the tag.
2. **Code-signs** it with a Developer ID Application certificate (Hardened Runtime,
   secure timestamp).
3. **Notarizes** it with `notarytool` and **staples** the ticket.
4. Zips it, writes a SHA-256, and publishes a **GitHub Release** with both assets.

If the signing secrets are not configured, the job still publishes a release — but the
`.app` will be **unsigned** (the release notes say so). Add the secrets to get
signed + notarized builds; nothing else changes.

## Required repository secrets

Set these under **Settings → Secrets and variables → Actions**.

### Code signing
| Secret | What it is |
|--------|-----------|
| `MACOS_CERTIFICATE` | Your **Developer ID Application** cert + private key exported as a `.p12`, then base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PWD` | The password you set when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY` | The identity string, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `KEYCHAIN_PWD` | Any throwaway password for the ephemeral CI keychain |

### Notarization (App Store Connect API key — recommended)
Create a key at App Store Connect → Users and Access → Integrations → App Store Connect API.

| Secret | What it is |
|--------|-----------|
| `AC_API_KEY_ID` | The key ID (e.g. `2X9R4HXF34`) |
| `AC_API_ISSUER_ID` | The issuer UUID shown on the same page |
| `AC_API_KEY_P8` | The downloaded `AuthKey_XXXX.p8`, base64-encoded: `base64 -i AuthKey_XXXX.p8 \| pbcopy` |

> If `AC_API_KEY_P8` is omitted, the app is signed but **not** notarized — fine for
> personal use, but Gatekeeper will still warn other users on first open.

## Getting a Developer ID certificate

You need a paid Apple Developer account. In Xcode → Settings → Accounts → Manage
Certificates → **+** → *Developer ID Application*. Then export it (with its private
key) from **Keychain Access** as a `.p12`.

## Verifying a release locally

```sh
unzip ClaudeWatch.zip
shasum -a 256 -c ClaudeWatch.zip.sha256       # integrity
codesign --verify --strict --verbose=2 ClaudeWatch.app
spctl -a -vvv ClaudeWatch.app                  # Gatekeeper assessment
```

## Future: Sparkle auto-update

privacycommand ships in-app auto-updates via [Sparkle](https://sparkle-project.org)
(an EdDSA-signed `appcast.xml` hosted on GitHub Pages). ClaudeWatch doesn't bundle
Sparkle yet. Adding it would mean: add the Sparkle SwiftPM dependency to the app
target, generate an EdDSA key pair, embed the public key + feed URL in `Info.plist`,
and have this workflow sign each build with `sign_update` and publish the appcast.
That's a self-contained follow-up — say the word.
