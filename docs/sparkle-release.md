# Sparkle Release Setup

## GitHub Actions releases (ad-hoc signed)

The repo ships `.github/workflows/release-packages.yml` for GitHub-hosted release packaging.

- It runs on `macos-15`.
- It builds the app with ad-hoc signing (`CODE_SIGN_IDENTITY=-`), no Apple Developer account required.
- It packages a styled DMG with the repo-tracked installer background artwork.
- It creates or updates the matching GitHub Release for a `v*` tag and leaves it in draft by default.
- When a `SPARKLE_PRIVATE_ED_KEY` secret is configured, it also generates and uploads `appcast.xml` for in-app Sparkle update checks.
- It is safe to rerun after a partially failed release upload.

> **注意：** 此工作流不进行 Apple 代码签名和公证。用户首次打开需右键 → 打开，或运行：
> ```bash
> xattr -d com.apple.quarantine /Applications/TRAE\ FLOW.app
> ```
> Sparkle 更新通过 EdDSA 签名验证 appcast 真实性，确保更新来源可信。

### Generate Sparkle keys

Run once to create the EdDSA key pair:

```bash
python3 -c "
import base64
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives import serialization
import os
key = ed25519.Ed25519PrivateKey.generate()
pub = key.public_key()
priv = base64.b64encode(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())).decode()
pub_b64 = base64.b64encode(pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()

os.makedirs('.sparkle-keys', exist_ok=True)
with open('.sparkle-keys/eddsa_private_key', 'w') as f: f.write(priv + '\n')
print(f'Public:  {pub_b64}')
print(f'Private: {priv}')
"
```

- Public key → set in `Config/LocalSecrets.xcconfig` as `SPARKLE_PUBLIC_ED_KEY`
- Private key → add to GitHub Secrets as `SPARKLE_PRIVATE_ED_KEY`

### Required repository secrets

The unsigned workflow only needs Sparkle secrets. Set these in `Settings -> Secrets and variables -> Actions`:

| Secret | Purpose |
| --- | --- |
| `SPARKLE_PRIVATE_ED_KEY` | Private EdDSA key for signing `appcast.xml` |

> The public key (`SPARKLE_PUBLIC_ED_KEY`) is already embedded in `Config/LocalSecrets.xcconfig` and compiled into the app.
>
> Important: when writing `SPARKLE_APPCAST_URL` into an `.xcconfig`, do not use a raw `https://...` literal. xcconfig treats `//` as the start of a comment, so compose the URL with a slash helper such as `_XC_SLASH = /`.

### Trigger the workflow

1. Bump `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` in Xcode project settings.
2. Push a tag:
   ```bash
   git tag v0.23.1 && git push origin v0.23.1
   ```
3. After CI completes, review and publish the draft Release on GitHub.

> **Note:** `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` only resolves for the latest PUBLISHED release. Keep releases as drafts until ready, then publish.

### 如果将来有了付费 Apple Developer 账号

## Local Sparkle release flow

If you want the full local release path including Sparkle appcast generation and website update:

1. Copy `Config/LocalSecrets.example.xcconfig` to `Config/LocalSecrets.xcconfig`.
2. Fill in:
   - `SPARKLE_APPCAST_URL`
   - `SPARKLE_PUBLIC_ED_KEY`

   Example:

```xcconfig
_XC_SLASH = /
SPARKLE_APPCAST_URL = https:$(_XC_SLASH)/github.com/<owner>/<repo>/releases/latest/download/appcast.xml
SPARKLE_PUBLIC_ED_KEY = YOUR_PUBLIC_ED_KEY
```
3. Generate Sparkle signing keys if you have not already:

```bash
./scripts/generate-keys.sh
```

4. Store notarization credentials locally:

```bash
xcrun notarytool store-credentials "TraeFlow" \
  --apple-id "your@email.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

5. Create the notarized DMG, appcast, and release assets:

```bash
./scripts/create-release.sh
```

## Notes

- `Config/LocalSecrets.xcconfig` is intentionally gitignored.
- `scripts/package-release.sh` is the shared build + sign + notarize packaging entrypoint used by both local release tooling and GitHub Actions.
- `scripts/create-styled-dmg.sh` now defaults to the repo-tracked installer artwork at `docs/images/trae-flow-dmg-installer-background.png`; set `TRAE_FLOW_DMG_BACKGROUND_SOURCE` if you need to preview a different background locally.
- `scripts/package-release.sh` now compares the build against the latest earlier published GitHub release and fails if `CFBundleVersion` did not increase.
- `scripts/create-release.sh` infers the GitHub repo from `origin` by default; set `TRAE_FLOW_GITHUB_REPO=owner/repo` if you need to override it.
