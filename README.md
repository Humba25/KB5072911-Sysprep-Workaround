# KB5072911 Sysprep Workaround

**Black screen and missing OOBE after Sysprep on Windows 11, and how to fix it with a script**

## The problem

When you generalize a Windows 11 installation with Sysprep (`/generalize /oobe`) and deploy it, you can run into two problems:

- The device does not boot into the OOBE setup screen after Sysprep, but straight to the regular sign-in screen (Tasks like generating a new SID fail).
- After signing in, the screen stays black. `explorer.exe` crashes on startup, and the Start menu and taskbar never appear.

On top of that, Sysprep itself often aborts because of reserved storage or AppX packages.

## The cause

Microsoft has documented the black screen in **KB5072911**:
https://support.microsoft.com/topic/d2d30684-4e2b-47f5-9899-a00a8e0acb09

If cumulative updates from July 2025 onward are installed before the first user signs in, three XAML packages (`MicrosoftWindows.Client.CBS`, `Microsoft.UI.Xaml.CBS` and `MicrosoftWindows.Client.Core`) do not register in time. Explorer starts before the packages are ready and crashes. This is exactly the situation on a patched reference system that gets sysprepped.

There is no final fix from Microsoft yet. The official workaround is to re-register the packages manually for every user, which is not practical when you deploy many devices.

## What the script does

The script runs on the reference system right before Sysprep, so the problem never shows up on the deployed devices. It works with any imaging tool.

1. **Pre-checks:** aborts if a reboot is pending, BitLocker is active, a previous Sysprep run was interrupted, or the script runs as SYSTEM (Sysprep as SYSTEM is not supported by Microsoft and can trigger the same black screen).
2. **Windows Update and reserved storage:** stops Windows Update and disables reserved storage. If reserved storage is occupied by a stuck update scenario (Sysprep error `0x80070975`), the script resets it and asks for a reboot.
3. **Hibernation and Fast Startup off:** otherwise the image capture can fail with an unclean NTFS volume.
4. **Languages and AppX packages:** removes unneeded languages and AppX packages that are installed for a single user only (Sysprep error `0x80073cf2`). If the language pack of the display language gets removed, a scheduled task reinstalls it after deployment.
5. **XAML workaround for KB5072911:** an Active Setup entry registers the three packages at the first sign-in of every user, before Explorer starts. The temporary OOBE account `defaultuser0` is skipped, so the OOBE is not slowed down.
6. **unattend.xml:** keeps drivers during generalize, sets `SkipRearm`, takes language and time zone from the device. The account is still created interactively in the OOBE.
7. **Sysprep:** asks for confirmation and runs `sysprep /generalize /oobe /shutdown`. If Sysprep fails, the script shows the new entries from `setuperr.log`.

A log of every run is written to `C:\Windows\Setup\Scripts\Logs\`.

## Files

| File | Purpose |
|---|---|
| `Start-Sysprep.cmd` | Launcher. Double-click it, it requests admin rights by itself |
| `Prepare-Sysprep.ps1` | Main script |
| `Prepare-Languages.ps1` | Called by the main script (languages and AppX packages) |

All three files must be in the same folder.

## Quick guide

1. Back up your reference system first. Sysprep cannot be undone.
2. Copy the three files to a folder on the reference system, e.g. `C:\Sysprep`.
3. Disconnect the network (unplug the cable, turn off Wi-Fi).
4. Do a dry run first. It only checks, nothing is changed:
```cmd
   C:\Sysprep\Start-Sysprep.cmd -DryRun
```
5. If everything is fine, double-click `Start-Sysprep.cmd` and confirm with `j` (yes).
6. After the shutdown, do **not** boot Windows normally. Boot straight into your capture (PXE, WinPE or whatever your imaging tool uses). If Windows boots once, the generalize run is used up.
7. Deploy the image to a test device, go through the OOBE and check that the SID is different, e.g. with [PsGetSid](https://learn.microsoft.com/sysinternals/downloads/psgetsid):
```cmd
   PsGetSid64.exe 
```

### Options

| Option | Effect |
|---|---|
| `-DryRun` | Only check and show, change nothing, no Sysprep |
| `-NoSysprep` | Prepare everything, but do not start Sysprep |
| `-KeepLanguages en-US` | Keep an additional language |

## Removing the workaround

Once Microsoft fixes KB5072911, the Active Setup entry should be removed from the image:

```cmd
reg delete "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A1B2C3D4-E5F6-47A8-9B0C-1D2E3F4A5B6C}" /f
del C:\Windows\Setup\Scripts\RegisterXamlPackages.cmd
```

Reserved storage stays disabled on deployed devices. To turn it back on:

```cmd
DIS
