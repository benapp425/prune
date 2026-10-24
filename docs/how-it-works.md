# How Prune works

## Scanning

Prune walks the startup disk from `/` on as many threads as the Mac has cores. Each folder is read in one or two system calls with `getattrlistbulk`, which returns names, sizes, dates and flags for many entries at once. Prune never opens a file during a scan.

A few things make the totals line up with what's really on disk:

| Situation | What Prune does |
| --- | --- |
| The system and data volumes | macOS joins them with firmlinks. Prune follows the firmlinks and skips `/System/Volumes`, so nothing is counted twice. |
| Other volumes | External disks, disk images and network shares are mount points. Prune doesn't cross them. |
| Hard links | A file with several names is counted once. |
| APFS clones | Copies made with Finder's Duplicate share storage. Prune reads each file's private size, so savings estimates don't count shared blocks. |
| iCloud files | Files offloaded to iCloud take no space here. Prune counts them separately and never lists offloaded folders, because that would download them. |
| Symbolic links | Not followed. |

A scan keeps every folder and every file of 1 MB or more. Smaller files are summed into their folder, which keeps memory use low. The File Browser lists a folder's files live when you open it, so it shows everything.

The last scan is saved in `~/Library/Application Support/Prune/last-scan.bin`, so the app opens with results. Click Scan to refresh.

## Free space

macOS reports three numbers:

- **Free**: blocks no file is using.
- **Purgeable**: space macOS frees by itself when it's needed. Most of it is usually held by local Time Machine snapshots, which keep deleted files for up to 24 hours.
- **Available**: free plus purgeable. Finder and System Settings show this one, and so does Prune.

That's why emptying the Trash can leave **Free** unchanged for a while: the snapshots still reference the deleted files, so the space moves to **Purgeable** until they expire. If you need the space right away, **Remove Snapshots…** on the Overview runs `tmutil thinlocalsnapshots`. It asks first, and backups on your Time Machine disk aren't affected.

**System Data** is used space the scan can't attribute to a folder: other system volumes, file system data and, without Full Disk Access, the folders macOS keeps private.

## Recommendations

| Category | What's included | Selected for you |
| --- | --- | --- |
| Caches | `~/Library/Caches`, caches inside app containers, web caches of Electron and Chromium apps (`Cache`, `Code Cache`, `GPUCache`…), developer tool caches (npm, pip, Homebrew, Yarn, Cargo, Gradle, Go, `~/.cache`), app logs | Yes, except caches of apps that are open, macOS's own caches, Hugging Face models and Playwright browsers |
| Downloads | Installers and archives (.dmg, .pkg, .zip…) added more than 2 weeks ago, incomplete downloads, apps never moved to Applications, anything not opened in 3 months | Installers older than 30 days and incomplete downloads |
| Developer | `node_modules` in projects with a `package.json`, Python virtual environments, folders marked with `CACHEDIR.TAG` (such as Rust's `target`), Next.js and similar build caches, Xcode DerivedData, device support files, archives, simulators, Docker's disk image | Dependencies and build files in projects untouched for 60 days, DerivedData, device support files, simulator caches |
| Large Files | Files over 250 MB you haven't opened in 6 months (both adjustable), TV app downloads, Final Cut and iMovie libraries, folders untouched for a year, iPhone and iPad backups | Never |
| Duplicates | Identical files of 1 MB or more in your own folders, matched by size, then the first and last 64 KB, then SHA-256 | Never; Select Newer Copies keeps the oldest of each |
| Uninstalled Apps | Folders in Application Support, Containers, Group Containers, Saved Application State, HTTPStorages and WebKit that belong to apps no longer installed and haven't changed in 90 days | Never |

Duplicates and Large Files only look in your own folders, not in Library, hidden folders, app bundles or project dependency folders, where copies are usually intentional.

## Removing

Selected items move to the Trash with `FileManager.trashItem`, the same way Finder does it. History records where each item came from, and **Put Back** moves it there again as long as it's still in the Trash. Undo, right after a move, does the same for the whole batch.

Prune won't move:

- anything outside your home folder, `/Users/Shared` and `/Applications`
- your home folder and its standard folders themselves (Library, Desktop, Documents, Downloads…), and Library's main folders
- keychains, preferences, Mail and Messages data
- anything inside an app bundle or other package
- containers belonging to Apple apps, and apps that ship with macOS

Prune won't let you select every copy of a duplicated file. Items in iCloud Drive or a cloud storage folder show a warning, because removing them removes them from your other devices too.

## Permissions

Prune asks for Full Disk Access so it can measure Mail, Messages, Safari and other apps' data. Without it, macOS hides those folders, and asks for access to Desktop, Documents and Downloads one at a time. Prune works either way and shows what it couldn't read.
