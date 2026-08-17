![My Context Menu Tools](Assets/Logo%20Banner.png)

# My Context Menu Tools

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

My Context Menu Tools is a Windows 11 File Explorer context-menu extension for adding personal commands and modern-menu entries for apps that still only install legacy registry context-menu verbs.

The top-level Explorer entry is **My Tools**. Its subitems and cascading submenus are data-driven from:

```text
%LOCALAPPDATA%\MyContextMenuTools\tools.jsonc
```

The config format is JSON with comments (`.jsonc`) and supports modular preset includes so useful integrations can live in separate files.

## Schema

```jsonc
{
  "menuTitle": "My Tools",
  "menuTooltip": "Custom commands and legacy app integrations",
  "menuIcon": "C:\\Path\\To\\icon.png",
  "items": [
    {
      "include": "Presets\\7zip.jsonc"
    },
    {
      "id": "developer-tools",
      "title": "Developer Tools",
      "icon": "C:\\Path\\To\\icon.svg",
      "children": [
        {
          "id": "make-backup-file",
          "title": "Make .bak file",
          "action": "makeBackupFile",
          "appliesTo": ["files"]
        },
        {
          "id": "touch-file",
          "title": "Touch file",
          "action": "touchFile",
          "appliesTo": ["files"]
        },
        {
          "id": "copy-sha256",
          "title": "Copy SHA-256 to clipboard",
          "action": "copySha256ToClipboard",
          "appliesTo": ["files"]
        },
        {
          "type": "separator"
        },
        {
          "id": "open-terminal-admin-here",
          "title": "Open in Terminal (Admin)",
          "command": "wt.exe",
          "arguments": "-d {container}",
          "workingDirectory": "{container}",
          "verb": "runas",
          "appliesTo": ["folders", "folderBackgrounds", "desktopBackground"]
        },
        {
          "id": "copy-folder-tree",
          "title": "Copy folder tree to clipboard",
          "command": "cmd.exe",
          "arguments": "/d /c title Copying folder tree to clipboard & echo Scanning this folder and all subfolders... & echo The folder tree will be copied to the clipboard when complete. & echo. & (tree /f /a | clip.exe)",
          "workingDirectory": "{container}",
          "appliesTo": ["folders", "folderBackgrounds", "desktopBackground"]
        },
        {
          "id": "find-largest-files",
          "title": "Find largest files here",
          "command": "powershell.exe",
          "arguments": "-NoExit -NoProfile -Command \"$Host.UI.RawUI.WindowTitle='Finding largest files'; Write-Host ('Scanning ' + (Get-Location) + ' and all subfolders...'); Write-Host 'Results will appear when the scan completes. Large drives may take several minutes.'; Write-Host; $count=0; Get-ChildItem -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $count++; if (($count % 1000) -eq 0) { Write-Progress -Activity 'Scanning files' -Status ($count.ToString('N0') + ' files found') }; $_ } | Sort-Object Length -Descending | Select-Object -First 20 | ForEach-Object { '{0,12:N2} MB  {1}' -f ($_.Length / 1MB), $_.FullName }; Write-Progress -Activity 'Scanning files' -Completed\"",
          "workingDirectory": "{container}",
          "appliesTo": ["folders", "folderBackgrounds", "desktopBackground"]
        }
      ]
    }
  ]
}
```

Items with `children` describe hierarchy in the config. On versions of Windows 11 that predate fixes enabling deeper context-menu hierarchies, nested leaves are flattened at runtime while keeping their configured titles. Items with `command` or `action` become verbs.

The optional `verb` field is passed to Windows Shell execution. Set it to `"runas"` to show the standard UAC prompt and launch the command as administrator.

Set `icon` or `menuIcon` to `"__none"` to suppress the icon. Omitting `icon` continues to use the extension's default glyph.

Built-in file actions include `makeBackupFile`, `touchFile`, and `copySha256ToClipboard`. Backup names progress from `<original>.bak` to `<original>.bak (2)` as needed. A single-file SHA-256 action copies only the hash; multiple files copy one `hash  path` line per file.

Items can be modularized with `{ "include": "relative\\path.jsonc" }` or `{ "$include": "relative\\path.jsonc" }`. Include paths are resolved relative to the file that contains them, and an included file can be a single item object, an array of item objects, or an object with an `items` array.

Divider lines can be represented with `{ "type": "separator" }` or `{ "separator": true }`. On versions of Windows 11 that predate fixes for `ECF_ISSEPARATOR` rendering in the modern context menu, those entries are ignored at runtime. The parser keeps accepting them so configs can leave separators in place and enable them when the platform behavior is available.

Command placeholders:

Standalone placeholder values in `arguments` are quoted automatically when needed. Do not add another pair of quotes around a standalone placeholder; legacy forms such as `"{container}"` are normalized at runtime.

| Placeholder | Meaning |
| --- | --- |
| `%1` or `{path}` | First selected file or folder |
| `%*` or `{paths}` | All selected files/folders |
| `{parent}` | Parent directory of the first selected item |
| `{container}` | Parent directory for files, or the selected/background folder for folders and backgrounds |
| `{name}` | File or folder name of the first selected item |
| `{stem}` | File or folder name of the first selected item without its final extension |
| `{id}` | Item id |

Filtering:

| Field | Behavior |
| --- | --- |
| `appliesTo` | `"files"`, `"folders"`, `"folderBackgrounds"`, `"desktopBackground"`, `"backgrounds"`, `"all"`, or an array such as `["files", "folders"]` |
| omitted `appliesTo` | Applies to all file types, but not folders |
| `includeExtensions` | Only show for these file extensions |
| `excludeExtensions` | Show for all otherwise-matching extensions except these |

Folder background and Desktop background menus are registered through the packaged `Directory\Background` shell target. `desktopBackground` matches when Explorer supplies the Desktop folder path for that background invocation; `backgrounds` targets both regular folder backgrounds and the Desktop background.

`IExplorerCommand::GetIcon` is documented as returning an icon resource string, for example `shell32.dll,-249`. For reliable Explorer rendering on Windows versions that predate fixes for SVG icon handling in this shell API, items without an icon use the theme-neutral purple-to-pink extension glyph bundled in `Assets\Extension.ico`. Config items may still point at `.svg` or `.png`, but SVGs should have same-name `.ico` sidecars for older builds, for example `Tool.svg`, `Tool.ico`, and optionally `Tool.dark.ico`. The bundled config uses `__appicon` to reference `Assets\AppIcon.ico`.

## Build and setup

On a clean Windows machine, install the build prerequisites with:

```powershell
.\scripts\Install-BuildPrerequisites.ps1
```

The script uses `winget`, reuses a working Visual Studio installation when one is already present, and installs only the missing pieces:

| Tooling | Needed for | Notes |
| --- | --- | --- |
| PowerShell | All scripts | Windows PowerShell 7+ |
| Visual Studio Build Tools 2022 | Native C++ compilation | Installed from `Microsoft.VisualStudio.2022.BuildTools` with the C++ Build Tools workload, MSVC for the selected architecture, and Windows 11 SDK 26100. The SDK supplies the headers, libraries, and `rc.exe` resource compiler used by `Build.ps1`. |
| NuGet CLI | Native library restore | Installed from `Microsoft.NuGet`. `Build.ps1` restores pinned Microsoft WIL and C++/WinRT packages from `packages.config`. |
| Windows App Development CLI | Debug package registration | Installed from `Microsoft.WinAppCli`; its `winapp.exe` creates the debug package identity used by the registration scripts. |

`winget` is supplied by Microsoft's App Installer. If it is unavailable, install or update App Installer from the Microsoft Store. The prerequisite script does not download or invoke the Visual Studio installer directly.

The native OS architecture is selected by default. On ARM64 Windows, run the script again with `-Architecture x64` if you also want to produce x64 builds. To inspect the current machine without installing anything, use:

```powershell
.\scripts\Install-BuildPrerequisites.ps1 -CheckOnly
```

For the guided one-stop setup path, run:

```powershell
.\scripts\Setup-Wizard.ps1
```

The wizard offers to install missing prerequisites through the same script, then can build the binaries, install or update the default config and presets, scan for supported apps, validate the config, and register the debug package. Detected 7-Zip commands default to their own top-level **7-Zip** entry, while smaller presets such as Notepad++ remain under **My Tools**. It skips rebuilding by default when build outputs are newer than source inputs. For repeatable runs, pass `-NonInteractive` plus any skip switches such as `-SkipRegistration`; use `-SkipPrerequisites` when package installation must be managed separately. Non-interactive mode preserves an existing config and validates without prompting for fixes.

```powershell
.\scripts\Build.ps1
.\scripts\Install-DefaultConfig.ps1
.\scripts\Ensure-AppContextMenuPresets.ps1
.\scripts\Validate-ToolsConfig.ps1
.\scripts\Register-DebugPackage.ps1
```

The native extension uses WIL resource wrappers and HRESULT helpers, implements its COM objects with C++/WinRT, and parses configuration with `Windows.Data.Json`. WIL failures are written to the `MyContextMenuTools.ExplorerCommand` TraceLogging provider and to `OutputDebugString`.

`Register-DebugPackage.ps1` defaults to `-ExplorerRestartMode Automatic`, which tries the gentle path first for 10 seconds and prompts before escalating to the old forceful double-restart behavior. Use `-ExplorerRestartMode Gentle` to avoid Explorer restarts entirely, `-ExplorerRestartMode ClearCache` when menu or icon changes need Explorer's cache cleared, or `-ExplorerRestartMode Force` to restart before unregistering and again after registration.

Build and setup commands default to the native OS architecture. Pass `-Architecture x64` or `-Architecture arm64` only when you need to build a specific target.

Build and setup commands default to `-PerformanceVerb Enabled`, which adds a disabled informational item showing how long each top-level menu took to load. Use `-PerformanceVerb Disabled` with `Build.ps1`, `Setup-Wizard.ps1`, `Register-DebugPackage.ps1`, or `Manage-ContextMenuExtensions.ps1` to build packages without that item.

## Presets and validation

Preset files live under `config\presets` and are copied to `%LOCALAPPDATA%\MyContextMenuTools\Presets` by `Install-DefaultConfig.ps1`. To scan for supported apps that still rely on legacy context-menu verbs and add matching modular includes to the user config, run:

```powershell
.\scripts\Ensure-AppContextMenuPresets.ps1
```

The scanner currently supports 7-Zip and Notepad++. It customizes copied preset files to the detected install paths. When called directly, it adds detected presets under **My Tools**; the setup wizard instead promotes 7-Zip to its own top-level entry. The 7-Zip preset uses `7zG.exe`, including 7-Zip's `-ad` dialog switch for the legacy-style "Add to archive..." and "Extract files..." dialogs, so long-running archive operations show 7-Zip's GUI progress UI rather than a hidden console process. CRC/SHA commands are commented out by default; use **Edit 7-Zip config** to open the deployed preset and uncomment that block.

If you add a preset for your own use case, please consider submitting a pull request so others can benefit from it too.

After editing presets or config, run:

```powershell
.\scripts\Validate-ToolsConfig.ps1 -OfferFixes
```

The validator checks configured executables, searches common install locations such as `%ProgramFiles%\7-Zip`, offers to replace incorrect paths, and prompts for a manual path when an executable cannot be found.

## Separate top-level entries

The default registration exposes **My Tools**, and the setup wizard promotes detected 7-Zip commands to a separate top-level **7-Zip** entry. Other presets can also be promoted with extension profiles. Profiles are separate debug packages backed by separate JSONC files under `%LOCALAPPDATA%\MyContextMenuTools\Extensions`.

```powershell
# Show full instructions for managing optional top-level extension profiles
.\scripts\Manage-ContextMenuExtensions.ps1 -Help

# Show app-owned top-level extension profiles. With no profiles, this prints next-step examples.
.\scripts\Manage-ContextMenuExtensions.ps1 -Action List

# Show built-in presets that can be promoted to top-level entries.
# Preset names display lowercase, but -Preset accepts 7Zip / NotepadPlusPlus / SuperDelete.
.\scripts\Manage-ContextMenuExtensions.ps1 -Action ListPresets

# Promote detected 7-Zip commands to their own top-level "7-Zip" entry
.\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset 7Zip

# Add lock-aware deletion helpers as their own top-level file verb
.\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset SuperDelete -Targets files

# Refresh an existing profile package and its compiled config snapshot
.\scripts\Manage-ContextMenuExtensions.ps1 -Action Refresh -Id 7zip

# Add a custom top-level entry backed by a modular include
.\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Id archive-tools -Title "Archive Tools" -Include "..\Presets\7zip.jsonc" -Icon "%ProgramFiles%\7-Zip\7zFM.exe"

# Remove a profile and unregister its debug package
.\scripts\Manage-ContextMenuExtensions.ps1 -Action Remove -Id 7zip

# Find removable MSIX/AppX context menu packages that were not created by this project
.\scripts\Manage-ContextMenuExtensions.ps1 -Action ScanExternal

# Remove one external package reported by ScanExternal
.\scripts\Manage-ContextMenuExtensions.ps1 -Action RemoveExternal -ExternalPackageFullName "Package_1.0.0.0_x64__publisherid"
```

Each generated package uses deterministic profile CLSIDs recognized by `MyContextMenuToolsExplorerCommand.dll`, so the same runtime can load either the default `tools.jsonc` or a per-profile config file.

Profile creation and refresh generate a compiled snapshot beside the profile config, for example `slot-01.compiled.json`. `Register-DebugPackage.ps1` also refreshes existing profile snapshots so promoted presets get the same first-load optimization as the default **My Tools** menu.

`ScanExternal` reads registered MSIX/AppX package manifests and lists packages outside this project that declare `windows.fileExplorerContextMenus`. `RemoveExternal` removes exactly one package returned by that scan using `Remove-AppxPackage`.

The Super Delete preset uses Windows Restart Manager to find processes that hold locks on the selected file. Its copy verb shows the locking process ID numbers in the menu and copies them to the clipboard; its delete verb asks for confirmation before terminating those processes and deleting the file.

This project intentionally runs user-configured commands as the current user. Treat `tools.jsonc` as executable configuration.

## License

This project is licensed under the [MIT License](LICENSE). Third-party dependency notices are listed in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).

This is an independent project and is not affiliated with or endorsed by Microsoft, 7-Zip, or Notepad++. Product names and trademarks belong to their respective owners.
