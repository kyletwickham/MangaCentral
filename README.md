# MangaCentral build kit

This folder builds an unsigned **MangaCentral.ipa** on GitHub's free cloud Macs.
Sideloadly then signs it with your Apple ID and installs it on your iPhone or iPad.

## One-time setup

1. Make a free account at github.com.
2. Create a new repository (the + button, then "New repository"). Name it `MangaCentral`.
   Private is fine.
3. On the new repository page, choose "uploading an existing file" and drag in
   **everything in this folder**, including the hidden `.github` folder. On a Mac or PC, unzip
   the kit first. If the `.github` folder doesn't come along (some file browsers hide it), use
   "Add file › Create new file", type `.github/workflows/build-ipa.yml` as the name, and paste
   in that file's contents.
4. Commit the upload. The build starts by itself.

## Getting the .ipa

1. Open the repository's **Actions** tab and click the latest "Build MangaCentral IPA" run.
2. When it shows a green check (about 5 to 10 minutes), scroll to **Artifacts** and download
   **MangaCentral-ipa**. It downloads as a zip; unzip it to get `MangaCentral.ipa`.
3. If it shows a red X, download **build-log** instead and send it to Claude to fix.

## Installing with Sideloadly

1. Open Sideloadly on your computer and plug in your iPhone or iPad.
2. Drag `MangaCentral.ipa` onto Sideloadly, enter your Apple ID, and start.
3. On the device: Settings › General › VPN & Device Management › trust your Apple ID.
   On iOS 16 or later, also turn on Developer Mode (Settings › Privacy & Security) when asked.

## Limits with a free Apple ID

- The app stops opening after **7 days**. Re-run Sideloadly to refresh it; your library is kept.
- Up to 3 sideloaded apps at a time.
- The friends feature uses demo friends until real syncing is set up.

## Updating

Upload changed files to the repository again. Each upload builds a new .ipa.
