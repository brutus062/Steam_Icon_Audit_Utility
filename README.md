# Steam Desktop Icon Audit & Recovery Utility

A robust, high-performance PowerShell utility designed to audit installed Steam games and ensure that every game has its corresponding high-resolution desktop `.ico` file present in the Steam client's `steam\games` directory.

If an icon is missing, the utility retrieves the authoritative 40-character SHA-1 icon hash directly from Steam's local binary database and downloads the `.ico` file straight from Valve's official edge Content Delivery Network (CDN).

---

## Key Features

* **Dynamic Environment Detection**: Automatically discovers the Steam installation path via the Windows Registry (`HKCU` / `HKLM`) and identifies all configured library folders across multiple storage drives using `libraryfolders.vdf`.
* **Zero Web Scraping & No API Keys**: Bypasses the need for third-party websites (such as SteamDB, which enforce Cloudflare bot mitigation) or Steam Web API keys by reading Steam's local product database directly.
* **Native Binary Cache Parser (Format 29)**: Directly parses Valve's `appcache\appinfo.vdf` binary dictionary pool using exact `clienticon` token index matching. Evaluates an entire library of hundreds of games in under 20 milliseconds with 100% determinism.
* **Intelligent Asset Distinction**: Differentiates between genuine desktop icon files (`clienticon` / `.ico`) and web thumbnails (`icon` / `.jpg`). Identifies older legacy titles (such as *Peggle Extreme*) where the publisher never supplied a Windows desktop icon, avoiding false download errors.
* **Safe Interactive Console**: Built strictly according to the Standard Interactive PowerShell Style, featuring colour-coded logging, standard 1-based numbered menus, input confirmations (`Y/n`), and safe exit options (`E/ENTER`).

---

## Prerequisites

1. **Operating System**: Windows 10 or Windows 11.
2. **PowerShell Version**: PowerShell 7.0 or higher (`pwsh.exe`).
3. **Execution Permissions**: Elevated privileges (**Run as Administrator**) to allow writing to protected Steam directories if installed under `Program Files`.
4. **Steam Client**: Steam must be installed with at least one active game library.

---

## Installation & Setup

1. Save the script file as `Audit_Steam_gameid_icons.ps1`.
2. Launch an elevated **PowerShell 7** terminal (Run as Administrator).
3. Execute the script:

```powershell
pwsh.exe -File ".\Audit_Steam_gameid_icons.ps1"
```

---

## How It Works Under the Hood

```
+-------------------------------------------------------------+
| 1. Dynamic Discovery                                        |
|    - Registry lookup -> Steam root path                     |
|    - libraryfolders.vdf -> All storage drives & libraries   |
|    - appmanifest_*.acf -> Enumerates all installed AppIDs   |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
| 2. Deterministic Binary Parsing                             |
|    - Reads appcache\appinfo.vdf (Format 29)                 |
|    - Resolves 64-bit String Pool pointer at byte offset 8   |
|    - Locates dictionary token index for 'clienticon'        |
|    - Extracts 40-char SHA-1 hash for each installed AppID   |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
| 3. Local Audit & CDN Acquisition                            |
|    - Checks <SteamPath>\steam\games\<hash>.ico              |
|    - Verified on disk  -> [+] VERIFIED                      |
|    - Missing on disk   -> Downloads from Valve edge CDN:    |
|      cdn.cloudflare.steamstatic.com/.../<appid>/<hash>.ico  |
|    - No .ico in record -> [*] NO ICON FILE (By developer)   |
+-------------------------------------------------------------+
```

---

## Menu Options

```text
==============================================================================
 STEAM CLIENT ICON AUDIT & RECOVERY UTILITY
==============================================================================
 Detected Steam Path : I:\Steam
 Icon Target Folder  : I:\Steam\steam\games
 Existing .ico Files : 80
==============================================================================

 1. Audit Installed Games & Icons (Report Only)
 2. Audit & Download Missing Game Icons (Auto-Recovery)
 3. Re-detect / Customise Steam Directory
 E. Exit Utility (Default)
```

### 1. Audit Installed Games & Icons (Report Only)
Performs an audit across all discovered library folders without modifying any files on disk. Outputs a tabulated summary showing which icons are verified, missing, or unavailable.

### 2. Audit & Download Missing Game Icons (Auto-Recovery)
Prompts for confirmation (`Y/n`), runs the audit, and automatically downloads any missing `.ico` files directly into your `<SteamPath>\steam\games\` folder.

### 3. Re-detect / Customise Steam Directory
Allows you to manually override or re-detect your primary Steam installation directory if running a non-standard portable setup.

### E / ENTER: Exit Utility
Exits the application cleanly.

---

## Status Indicators Explained

| Indicator | Status Text | Description |
| :--- | :--- | :--- |
| `[+]` Green | `VERIFIED` | The authoritative `.ico` file is present in `steam\games\`. |
| `[+]` Green | `DOWNLOADED` | The missing `.ico` file was successfully retrieved from the CDN and placed on disk. |
| `[-]` Red | `MISSING` | The game has a registered desktop icon, but the `.ico` file is absent from your folder. |
| `[-]` Red | `DL FAILED` | An error occurred while attempting to download the `.ico` file from Valve's CDN. |
| `[*]` Yellow | `NO ICON FILE` | The publisher never uploaded a Windows `.ico` asset to Steamworks (e.g. legacy titles). |

---

## Technical Specifications

* **Icon URL Format**: `https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/{AppId}/{Hash}.ico`
* **Local Cache Format**: Valve Binary KeyValues format 29 (`0x07564429`) with pooled dictionary indexing.
* **File Encoding**: Latin-1 / ASCII binary stream matching with ordinal byte comparison (`[System.StringComparison]::Ordinal`).
* **Performance**: Under 20 milliseconds to parse 400+ game records and build an in-memory `O(1)` hash table.