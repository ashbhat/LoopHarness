# Releasing to TestFlight

Every push to `main` automatically builds the iOS app and uploads it to
TestFlight via the **TestFlight** GitHub Actions workflow. You can also
trigger a build manually from **Actions → TestFlight → Run workflow**.

---

## GitHub Secrets

Add these in **Settings → Secrets and variables → Actions → Repository
secrets** on the `theashbhat/LoopHarness` repo:

| Secret                        | Description                                                                                                    |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `APP_STORE_CONNECT_API_KEY`   | Base64-encoded contents of the `.p8` private key file. Generate with `base64 -i AuthKey_XXXXXXXXXX.p8`.       |
| `APP_STORE_CONNECT_KEY_ID`    | The 10-character Key ID shown when you create the key (e.g. `A1B2C3D4E5`).                                   |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID from **App Store Connect → Users and Access → Integrations → App Store Connect API**.           |
| `MATCH_PASSWORD`              | The passphrase used to encrypt/decrypt the Match certificates repository.                                      |
| `MATCH_GIT_URL`               | HTTPS or SSH URL of the private Git repo that stores your signing certificates and provisioning profiles.       |

### Optional

| Secret / Variable | Description                                                   |
| ----------------- | ------------------------------------------------------------- |
| `TEAM_ID`         | Apple Developer Team ID (10-char). Defaults to the one in your Match repo. |
| `APP_IDENTIFIER`  | Bundle identifier. Defaults to `com.bhat.intel`.             |

---

## One-Time Setup in App Store Connect

### 1. Create an App Store Connect API Key

1. Go to [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **Generate API Key**.
3. Name it (e.g. `CI-TestFlight`), set access to **Developer** (minimum
   role needed for TestFlight uploads).
4. Download the `.p8` file — **you can only download it once**.
5. Note the **Key ID** and the **Issuer ID** shown on the page.
6. Base64-encode the key for the GitHub secret:
   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
   Paste the result as the `APP_STORE_CONNECT_API_KEY` secret.

### 2. Set Up Match (Code Signing)

Match stores certificates and provisioning profiles in a private Git repo.

1. Create a **private** repo (e.g. `theashbhat/certificates`).
2. On your Mac, run:
   ```bash
   bundle exec fastlane match init
   bundle exec fastlane match appstore
   ```
   This generates the App Store distribution certificate and provisioning
   profile and pushes them to the private repo, encrypted with your
   `MATCH_PASSWORD`.
3. Add `MATCH_GIT_URL` and `MATCH_PASSWORD` as GitHub secrets.

### 3. Create the "Internal" Testers Group

1. Go to [App Store Connect → My Apps → Loop → TestFlight](https://appstoreconnect.apple.com).
2. Under **Internal Testing**, click **+** to create a new group.
3. Name it **Internal** (must match the group name in `fastlane/Fastfile`).
4. Add your internal testers (any App Store Connect user with at least the
   **App Manager**, **Developer**, or **Marketing** role is eligible for
   internal testing).

> Builds distributed to internal testers do **not** require Beta App Review.

---

## Build Numbers

- In CI, the build number is set to `GITHUB_RUN_NUMBER` (auto-incrementing
  integer tied to the workflow).
- When running locally, the lane fetches the latest TestFlight build number
  and increments by 1.

This avoids collisions: CI builds always use a unique, monotonically
increasing number, and local builds pick up from wherever TestFlight left off.

---

## Running Locally

```bash
# Install dependencies
bundle install

# Run the beta lane (requires ASC env vars — see above)
export APP_STORE_CONNECT_API_KEY="$(base64 -i path/to/AuthKey.p8)"
export APP_STORE_CONNECT_KEY_ID="YOUR_KEY_ID"
export APP_STORE_CONNECT_ISSUER_ID="YOUR_ISSUER_ID"
export MATCH_PASSWORD="your-match-password"
export MATCH_GIT_URL="https://github.com/theashbhat/certificates.git"

bundle exec fastlane ios beta
```

---

## Manual Trigger (workflow_dispatch)

1. Go to **Actions → TestFlight** in GitHub.
2. Click **Run workflow** → select the `main` branch → **Run workflow**.

---

## Out of Scope

- External TestFlight groups (requires Beta App Review)
- App Store production releases
- Android / Mac Catalyst builds
