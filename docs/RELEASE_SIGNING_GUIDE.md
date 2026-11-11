# 🍎 Apple Code Signing & Notarization Setup Guide

This guide walks you through setting up Apple Developer credentials and GitHub Secrets so that GitHub Actions can automatically sign, notarize, staple, and publish releases for **Graviton** (`Graviton.dmg` and `Graviton.zip`).

Once configured, users downloading Graviton will **never** see macOS Gatekeeper quarantine warnings ("is damaged", "unidentified developer").

---

## 📋 Required GitHub Secrets

You will add the following 5 secrets in your GitHub repository:
👉 **Repository Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Description | Example / Format |
|---|---|---|
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `Developer ID Application.p12` | Long base64 string (`MIIK...`) |
| `APPLE_CERTIFICATE_PASSWORD` | Password you set when exporting the `.p12` | Plaintext password |
| `APPLE_API_KEY_ID` | 10-character Key ID from App Store Connect | e.g. `2X9R4HXF34` |
| `APPLE_API_ISSUER` | Issuer ID UUID from App Store Connect | e.g. `57246542-96fe-1a63-e053-0824d011072a` |
| `APPLE_API_KEY` | Full contents of the `AuthKey_*.p8` private key file | `-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----` |

---

## 🛠️ Step 1: Create Developer ID Application Certificate

1. Go to [Apple Developer: Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
2. Click the **+** (Create a Certificate) button.
3. Select **Developer ID Application** under Software (⚠️ *Do NOT choose "Apple Development" or "Mac App Distribution"*).
4. Follow the prompt to upload a **Certificate Signing Request (CSR)**:
   - On your Mac, open **Keychain Access**.
   - Menu: **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority...**
   - Enter your email and name, select **Saved to disk**, and click **Continue**.
5. Upload this CSR file on the Apple Developer website and click **Continue**.
6. Download the generated certificate (`developerID_application.cer`).
7. Double-click the downloaded `.cer` file to install it into your macOS **login** Keychain.

---

## 🔐 Step 2: Export `.p12` and Encode in Base64

1. Open **Keychain Access** on your Mac.
2. Select **login** keychain and go to the **My Certificates** tab.
3. Locate **Developer ID Application: Your Name (Team ID)**.
4. Expand it to ensure the private key is attached underneath.
5. Right-click the certificate and select **Export "Developer ID Application: ..."**.
6. Format: **Personal Information Exchange (.p12)**. Save it as `developer_id.p12`.
7. Enter a strong password when prompted (this password becomes `APPLE_CERTIFICATE_PASSWORD`).
8. Convert the `.p12` file to a Base64 string and copy it to your clipboard:
   ```bash
   base64 -i developer_id.p12 | pbcopy
   ```
9. Paste this string as the `APPLE_CERTIFICATE_BASE64` secret in GitHub.
10. Add `APPLE_CERTIFICATE_PASSWORD` with the password you chose in step 7.

---

## 🔑 Step 3: Create App Store Connect API Key (for Notarization)

Apple's `notarytool` uses App Store Connect API keys to notarize outside-the-store binaries without 2FA issues:

1. Sign in to [App Store Connect: Keys](https://appstoreconnect.apple.com/access/integrations/api).
2. Go to the **Users and Access → Integrations → App Store Connect API** tab.
3. Click the **+** button to generate a new key:
   - **Name**: `Graviton Notarization` (or any name you prefer).
   - **Access**: **Developer** (or **App Manager**).
4. Note the **Issuer ID** at the top of the page (copy this as `APPLE_API_ISSUER`).
5. Note the **Key ID** next to your newly created key (copy this as `APPLE_API_KEY_ID`).
6. Click **Download API Key** to download the `AuthKey_<KeyID>.p8` file.
   > ⚠️ *Note: You can only download this file once. Keep it safe.*
7. Open the downloaded `.p8` file in a text editor, copy its entire contents (including `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----`), and save it as `APPLE_API_KEY` in GitHub Secrets.

---

## 🚀 Step 4: Triggering the Release

Once the 5 secrets are configured in GitHub:

### Option A: Create a Git Tag (Standard Release)
```bash
git checkout main # or develop
git tag v1.1.0
git push origin v1.1.0
```

### Option B: Manual Trigger via GitHub Actions Tab
1. Open your repository on GitHub.
2. Go to the **Actions** tab.
3. Select **Release** workflow from the left sidebar.
4. Click **Run workflow**, enter `v1.1.0`, and click **Run workflow**.

---

## ✅ Step 5: What the CI Workflow Does Automatically

1. Launches a clean macOS 14 runner.
2. Decodes and imports your Developer ID certificate into a temporary keychain.
3. Compiles the release binary (`swift build -c release`).
4. Signs `Graviton.app` with `Developer ID Application`, Hardened Runtime, timestamp, and entitlements.
5. Packages `Graviton.dmg` and signs the DMG container itself.
6. Uploads the DMG to Apple Notary Service (`xcrun notarytool submit --wait`).
7. Once Apple approves the notarization, staples the notarization ticket into `Graviton.dmg` (`xcrun stapler staple`).
8. Publishes the release to GitHub Releases with attached `Graviton.dmg` and `Graviton.zip`.
9. Securely deletes the temporary keychain and private keys.
