# TestFlight CI/CD

Automated TestFlight publishing via **Fastlane** + **GitHub Actions**.

Pushes to `main` (or manual `workflow_dispatch`) trigger a build of the iOS
app, upload it to App Store Connect, and distribute the build to TestFlight
testers.

---

## How it works

```
push to main
  └─ .github/workflows/testflight.yml
       ├─ checkout (full history for changelog)
       ├─ select Xcode
       ├─ bundle install (Fastlane)
       └─ fastlane ios beta
            ├─ App Store Connect API key auth
            ├─ import distribution certificate from secrets
            ├─ download provisioning profiles from ASC
            ├─ increment build number (GITHUB_RUN_NUMBER)
            ├─ generate changelog from git commits
            ├─ archive Loop_iOS scheme for App Store
            ├─ upload IPA to TestFlight
            └─ distribute to tester groups (if configured)
```

After a successful upload the workflow tags the commit
`testflight/<run_number>` so the next build's changelog starts from that
point.

---

## Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `ASC_KEY_ID` | App Store Connect API **Key ID** (10-char, e.g. `ABC1234DEF`). |
| `ASC_ISSUER_ID` | App Store Connect **Issuer ID** (UUID from *Users and Access → Integrations → App Store Connect API*). |
| `ASC_KEY_CONTENT` | The `.p8` private key file contents, **base64-encoded**. Encode with `base64 -i AuthKey_XXX.p8`. |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID. |
| `IOS_DISTRIBUTION_CERTIFICATE_P12` | The iOS/Apple Distribution certificate + private key exported as a `.p12`, **base64-encoded**. Encode with `base64 -i Certificates.p12`. |
| `IOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |

### Optional secrets

| Secret | Description |
|--------|-------------|
| `TESTFLIGHT_GROUPS` | Comma-separated TestFlight group names for external distribution (e.g. `"Beta Testers,QA"`). When set, Fastlane submits the build for Beta App Review and distributes to those groups. When empty/unset, the build is uploaded to TestFlight but only available to internal testers (your App Store Connect team). |

---

## Creating the App Store Connect API Key

1. Go to [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **Generate API Key**.
3. Name it (e.g. `CI-TestFlight`), set role to **App Manager** (minimum
   for TestFlight uploads).
4. Download the `.p8` file — you can only download it **once**.
5. Note the **Key ID** and **Issuer ID** shown on the page.
6. Base64-encode the key:
   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
7. Store the three values as GitHub secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_KEY_CONTENT`.

---

## Exporting the distribution certificate

1. Open **Keychain Access** on a Mac that has the distribution cert.
2. Find `Apple Distribution: <Your Name> (<Team ID>)` under *My Certificates*.
3. Right-click → **Export…** → save as `.p12` with a password.
4. Base64-encode:
   ```bash
   base64 -i Certificates.p12 | pbcopy
   ```
5. Store in GitHub secrets: `IOS_DISTRIBUTION_CERTIFICATE_P12` (the
   base64 string) and `IOS_CERTIFICATE_PASSWORD` (the password).

> **Tip:** If the certificate was created via Xcode's automatic signing,
> the private key lives in your login keychain. Make sure you export
> both the certificate **and** its private key (Keychain Access shows a
> disclosure triangle).

---

## Provisioning profiles

Fastlane uses the `sigh` action to **automatically download** the correct
App Store provisioning profiles from App Store Connect using the API key.
You do not need to manage profiles as secrets.

If profiles don't exist yet, create them in the
[Apple Developer portal](https://developer.apple.com/account/resources/profiles/list)
for:

- `com.bhat.intel` (App Store distribution)
- `com.bhat.intel.LoopShare` (App Store distribution, for the share extension)

---

## Changelog generation

The TestFlight "What to Test" notes are auto-generated from git commits:

1. **Tag-based** (preferred): If a `testflight/*` tag exists (created
   automatically by the workflow on each successful deploy), the changelog
   contains all commits between that tag and `HEAD`.
2. **Fallback**: If no tags exist (first deploy), the last 50 commits are
   used.

Merge commits are excluded for readability. Each entry shows the commit
subject and short hash.

---

## Tester distribution

- **Internal testers** (your ASC team) always see new builds once
  processing completes — no extra config needed.
- **External testers** require `TESTFLIGHT_GROUPS` to be set. Fastlane
  calls `distribute_external: true` and submits the build for Beta App
  Review. Apple typically reviews these within 24-48 hours. Group names
  must match exactly what's configured in App Store Connect under
  *TestFlight → External Testing*.

---

## Running locally

```bash
# Install dependencies
bundle install

# Set required env vars (or export them)
export ASC_KEY_ID="..."
export ASC_ISSUER_ID="..."
export ASC_KEY_CONTENT="$(base64 -i path/to/AuthKey.p8)"
export APPLE_TEAM_ID="..."
export IOS_DISTRIBUTION_CERTIFICATE_P12="$(base64 -i path/to/cert.p12)"
export IOS_CERTIFICATE_PASSWORD="..."

# Run the lane
bundle exec fastlane ios beta

# Or with a custom build number:
bundle exec fastlane ios beta build_number:999
```

> On a local Mac with Xcode automatic signing already configured, you can
> skip the certificate/profile env vars and Fastlane will use your local
> keychain. Set at minimum the `ASC_*` variables for the upload step.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `No matching provisioning profiles found` | Create App Store distribution profiles for both bundle IDs in the Apple Developer portal. |
| `The certificate has an invalid issuer` | The P12 doesn't contain an Apple Distribution cert. Re-export from Keychain Access. |
| `Could not find App Store Connect API key` | Verify `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_CONTENT` are set correctly. The content must be base64-encoded. |
| `Build number already exists` | App Store Connect rejects duplicate build numbers. Trigger a new workflow run (the run number auto-increments). |
| Changelog is empty | Push a `testflight/*` tag or ensure there are commits since the last tag. |
