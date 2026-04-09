# Microsoft Graph Provisioning Bot

This folder contains a small PowerShell bot that provisions Microsoft 365 / Microsoft Entra users in a tenant you control.

It does not create consumer `outlook.com` accounts.

## Files

- `graph-provisioning-bot.ps1`: lists subscribed SKUs and provisions single users or bulk CSV batches through Microsoft Graph.
- `bulk-users.sample.csv`: sample input file for bulk provisioning.
- `chrome-profile-launcher.ps1`: creates isolated Chrome profile folders like `Name1`, `Name2`, then opens each one with startup URLs.
- `chrome_profile_launcher.py`: Python version of the Chrome profile launcher. This is the simplest way to run it.
- `chrome-profiles.env.sample`: sample `.env` values for the Chrome launcher.
- `playwright-click-navigation.helper.js`: reusable helper that detects same-tab navigation, popup navigation, or no navigation after a click.
- `playwright-click-navigation.demo.spec.js`: neutral Playwright demo spec that exercises the helper against local static HTML.
- `playwright-click-navigation.patch.txt`: patch template showing how to wire the helper into your own Playwright test.

## Playwright Helper

Reusable helper:

```js
const {
  clickAndDetectNavigation,
} = require("./playwright-click-navigation.helper");
```

Neutral demo test:

```powershell
npx playwright test .\playwright-click-navigation.demo.spec.js
```

The demo test runs only against local files in `playwright-demo\` and covers:
- a same-tab link
- a popup link
- a button that changes the page without navigation

## Chrome Launcher

Put these values in `.env`:

```env
CHROME_PROFILE_BASE_NAME=Work
CHROME_PROFILE_RANGE=[4,7]
CHROME_PROFILE_ROOT=chrome-profiles
CHROME_START_URLS=https://contactout.com/;https://outlook.com/
# CHROME_LAUNCH_LOG_FILE=chrome-profile-launcher.log
# CHROME_PROXY_FILE=chrome-proxy-list.txt
# CURRENT_PROXY=0
# CHROME_PROXY_STRATEGY=range
# CHROME_PROXY_START_INDEX=0
# CHROME_PROXY_RANDOM_SEED=123
```

Run:

```powershell
python .\chrome_profile_launcher.py
```

That creates folders like `chrome-profiles\Work4`, `chrome-profiles\Work5`, `chrome-profiles\Work6`, and `chrome-profiles\Work7`, then opens a Chrome window for each one with `contactout.com` and `outlook.com` as the first tabs.

By default the Python launcher also appends each launch to `chrome-profile-launcher.log`, including the timestamp, profile name, and proxy assignment such as `Work41 | proxy[12] http://1.2.3.4:50100`. You can change that path with `CHROME_LAUNCH_LOG_FILE` or `--log-file`.

When the Python launcher is using HTTP proxies with credentials, it starts a small local loopback proxy helper for each launched profile. Chrome connects to that local helper, and the helper injects the upstream proxy credentials from `CHROME_PROXY_FILE`, so you do not need to type the username/password popup manually.

If older Chrome windows must stay open, set `CHROME_UNIQUE_PROFILE_PER_LAUNCH=1`. Then each run uses a fresh `--user-data-dir` inside `CHROME_SESSION_PROFILE_ROOT\<ProfileName>\<launch-tag>`, so `chrome-profiles` still shows plain folders like `Harry71` while each run gets its own isolated session.

If you want the on-disk structure to look exactly like `chrome-profiles\Harry56\...`, leave `CHROME_UNIQUE_PROFILE_PER_LAUNCH=0`. In that mode the launcher reuses `chrome-profiles\<ProfileName>` directly, so an existing folder opens as the same saved Chrome profile.

For a single profile only, use:

```env
CHROME_PROFILE_RANGE=[5]
```

That opens only `chrome-profiles\Work5`.

You can still use `CHROME_PROFILE_COUNT=3` if you want `Work1` through `Work3`, but `CHROME_PROFILE_RANGE` takes priority when both are set.

To launch each profile through its own proxy, add `CHROME_PROXY_FILE` and place one proxy URL per line in that file. When `CURRENT_PROXY` is not set, the Python launcher now supports three mapping strategies:

- `CHROME_PROXY_STRATEGY=range` (default): the selected profile range consumes a slice of the proxy file starting at `CHROME_PROXY_START_INDEX`.
- `CHROME_PROXY_STRATEGY=profile`: the absolute profile number maps to the proxy file, so `Work41` uses proxy line 41 by default.
- `CHROME_PROXY_STRATEGY=cycle`: the selected profile range walks forward through the proxy file and wraps around when needed.
- `CHROME_PROXY_STRATEGY=random`: each launched profile gets a random proxy from the file. If there are enough proxies, the launcher avoids duplicates within that run.

`CHROME_PROXY_START_INDEX` is optional and zero-based. It lets you start the `range`, `cycle`, or `random` pool from any line in a larger proxy file.

If you want the random mapping to be repeatable for debugging, set `CHROME_PROXY_RANDOM_SEED` to a fixed integer.

To launch a whole profile range through one selected proxy, set `CURRENT_PROXY` to a zero-based index from that proxy file. Example: `CURRENT_PROXY=0` uses the first proxy line for every profile in `CHROME_PROFILE_RANGE`, and `CURRENT_PROXY=89` uses the 90th proxy line. When the selected proxy includes credentials, the Python launcher automatically forwards those credentials through the local helper so Chrome avoids the native auth popup.

For a larger pool like `Harry41` through `Harry50`, these two setups are usually the most useful:

```env
CHROME_PROFILE_BASE_NAME=Harry
CHROME_PROFILE_RANGE=[41,50]
CHROME_PROXY_FILE=chrome-proxy-list.txt
CHROME_PROXY_STRATEGY=profile
```

Or, if you want that range to use a specific 10-line slice from a bigger proxy file:

```env
CHROME_PROFILE_BASE_NAME=Harry
CHROME_PROFILE_RANGE=[41,50]
CHROME_PROXY_FILE=chrome-proxy-list.txt
CHROME_PROXY_STRATEGY=range
CHROME_PROXY_START_INDEX=40
```

If you do not want any profile-to-proxy alignment at all and just want random proxies from the whole file:

```env
CHROME_PROFILE_BASE_NAME=Harry
CHROME_PROFILE_RANGE=[41,50]
CHROME_PROXY_FILE=chrome-proxy-list.txt
CHROME_PROXY_STRATEGY=random
```

Optional examples:

```powershell
python .\chrome_profile_launcher.py
python .\chrome_profile_launcher.py --profile-range [5]
python .\chrome_profile_launcher.py --profile-range [8,10] https://example.com
python .\chrome_profile_launcher.py --log-file .\logs\chrome-launches.log
python .\chrome_profile_launcher.py --proxy-file .\chrome-proxy-list.txt
python .\chrome_profile_launcher.py --proxy-file .\chrome-proxy-list.txt --current-proxy 0
python .\chrome_profile_launcher.py --proxy-file .\chrome-proxy-list.txt --proxy-strategy profile --profile-range [41,50]
python .\chrome_profile_launcher.py --proxy-file .\chrome-proxy-list.txt --proxy-strategy range --proxy-start-index 40 --profile-range [41,50]
python .\chrome_profile_launcher.py --proxy-file .\chrome-proxy-list.txt --proxy-strategy random --profile-range [41,50]
```

## What It Can Do

- authenticate with Microsoft Graph using the client credentials flow
- list available commercial SKUs in your tenant
- create a cloud-only user
- bulk create users from CSV
- optionally set `usageLocation`
- optionally assign a license by `skuId` or `skuPartNumber`

## Prerequisites

1. Register an app in Microsoft Entra ID.
2. Create a client secret for that app.
3. Add Microsoft Graph application permissions:
   - `User.ReadWrite.All` for creating users
   - `LicenseAssignment.Read.All` for `ListSkus`
   - `LicenseAssignment.ReadWrite.All` if you want to assign licenses
4. Grant admin consent to those permissions.
5. Use a verified domain from your tenant for the user's `userPrincipalName`.

## Environment Variables

The script automatically loads `.env` from the same folder as `graph-provisioning-bot.ps1` when those values are not already provided as parameters or session environment variables.

You can either set these in your PowerShell session:

```powershell
$env:GRAPH_TENANT_ID = "your-tenant-id"
$env:GRAPH_CLIENT_ID = "your-app-client-id"
$env:GRAPH_CLIENT_SECRET = "your-app-client-secret"
```

Or put them in `.env`:

```env
GRAPH_TENANT_ID=your-tenant-id
GRAPH_CLIENT_ID=your-app-client-id
GRAPH_CLIENT_SECRET=your-app-client-secret
```

## Usage

List available SKUs:

```powershell
.\graph-provisioning-bot.ps1 -Action ListSkus
```

Create a user without a license:

```powershell
.\graph-provisioning-bot.ps1 `
  -Action CreateUser `
  -DisplayName "Jane Doe" `
  -UserPrincipalName "jane.doe@contoso.onmicrosoft.com"
```

Create a user and assign a license by SKU part number:

```powershell
.\graph-provisioning-bot.ps1 `
  -Action CreateUser `
  -DisplayName "Jane Doe" `
  -UserPrincipalName "jane.doe@contoso.onmicrosoft.com" `
  -UsageLocation "US" `
  -SkuPartNumber "ENTERPRISEPACK"
```

Create a user and assign a license by SKU ID:

```powershell
.\graph-provisioning-bot.ps1 `
  -Action CreateUser `
  -DisplayName "Jane Doe" `
  -UserPrincipalName "jane.doe@contoso.onmicrosoft.com" `
  -UsageLocation "US" `
  -SkuId "6fd2c87f-b296-42f0-b197-1e91e994b900"
```

Return JSON instead of PowerShell objects:

```powershell
.\graph-provisioning-bot.ps1 -Action ListSkus -OutputJson
```

Bulk provision from CSV:

```powershell
.\graph-provisioning-bot.ps1 `
  -Action BulkCreateUsers `
  -CsvPath ".\bulk-users.sample.csv"
```

Bulk provision from CSV with default license settings applied to rows that omit them:

```powershell
.\graph-provisioning-bot.ps1 `
  -Action BulkCreateUsers `
  -CsvPath ".\users.csv" `
  -UsageLocation "US" `
  -SkuPartNumber "ENTERPRISEPACK"
```

## CSV Columns

Supported headers:

- `DisplayName` required unless provided as a command-line fallback
- `UserPrincipalName` required unless provided as a command-line fallback
- `Alias` optional
- `Password` optional
- `UsageLocation` optional
- `SkuId` optional
- `SkuPartNumber` optional
- `ForceChangePasswordNextSignIn` optional, accepts `true` or `false`
- `DisabledPlanIds` optional, semicolon- or comma-separated GUIDs

Each row is processed independently. If one row fails, the script continues with the rest of the batch and returns a summary plus per-row results. For bulk runs, the script exits with code `2` when any row fails.

## Notes

- If you do not pass `-Alias`, the script derives it from the part of `userPrincipalName` before `@`.
- If you do not pass `-Password`, the script generates a strong random password.
- `UsageLocation` is required before license assignment.
- For bulk CSV runs, command-line user fields act as defaults for rows that leave those columns blank.
- If the assigned license includes Exchange Online, Microsoft creates the mailbox asynchronously and it can take time to appear.
- If user creation succeeds but a later licensing step fails, the user remains in the directory and the script reports that partial success.

## Typical Flow

1. Run `-Action ListSkus`.
2. Pick the `skuPartNumber` or `skuId` you want.
3. Run `-Action CreateUser` or `-Action BulkCreateUsers` with `-UsageLocation` and the SKU.
