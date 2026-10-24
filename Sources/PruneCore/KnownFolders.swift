import Foundation

/// One-line descriptions of folders people commonly wonder about.
public enum KnownFolders {
    private static let homeRelative: [String: String] = [
        "Library": "Settings, caches and data for your apps. Finder hides it.",
        "Library/Caches": "Temporary files apps keep to start and load faster. Apps rebuild them.",
        "Library/Application Support": "Where apps keep their data: libraries, downloads, databases and settings.",
        "Library/Containers": "Data for App Store and other sandboxed apps, one folder per app.",
        "Library/Group Containers": "Data shared between apps from the same developer.",
        "Library/Logs": "Diagnostic logs written by apps and macOS. Safe to clear.",
        "Library/Mobile Documents": "iCloud Drive. Deleting something here deletes it from iCloud on all your devices.",
        "Library/CloudStorage": "Folders synced by Google Drive, Dropbox, OneDrive and similar apps.",
        "Library/Mail": "Your Mail messages and attachments.",
        "Library/Messages": "Your Messages history and attachments.",
        "Library/Developer": "Data from Xcode and developer tools.",
        "Library/Developer/Xcode/DerivedData": "Xcode build products. Rebuilt the next time you build.",
        "Library/Developer/Xcode/Archives": "Builds you archived in Xcode. Needed to read crash reports for those builds.",
        "Library/Developer/Xcode/iOS DeviceSupport": "Debug symbols copied from your iPhone. Copied again when you connect it.",
        "Library/Developer/CoreSimulator": "Simulator devices and the apps installed on them.",
        "Library/Application Support/MobileSync/Backup": "iPhone and iPad backups made by Finder.",
        "Library/Containers/com.docker.docker": "Docker Desktop and its virtual disk. Shrink it from Docker's settings.",
        "Library/Application Support/Steam": "Steam games and their downloads. Uninstall games from Steam.",
        "Library/Caches/Homebrew": "Installers Homebrew downloaded. Running brew cleanup clears it too.",
        "Library/Saved Application State": "Window positions apps restore at launch.",
        "Library/Preferences": "App settings files. Small, and needed by the apps.",
        "Library/Fonts": "Fonts you installed.",
        "Library/Keychains": "Your saved passwords and certificates.",
        "Movies/TV": "Movies and shows downloaded in the TV app. Remove downloads in the TV app.",
        "Music/Music": "Your Music library.",
        "Pictures/Photos Library.photoslibrary": "Your Photos library. Manage it in Photos.",
        "Downloads": "Files you downloaded. Old installers and archives usually aren't needed.",
        "Desktop": "Files on your desktop.",
        "Documents": "Your documents.",
        ".Trash": "The Trash. Space comes back when you empty it.",
        ".npm": "npm's download cache and npx packages. npm downloads again what it needs.",
        ".cache": "Caches for command-line tools. Tools rebuild them.",
        ".cache/huggingface": "AI models downloaded from Hugging Face. Downloaded again when needed.",
        ".cargo": "Rust's package registry and installed tools.",
        ".rustup": "Rust toolchains.",
        ".gradle": "Gradle's build cache and downloaded libraries.",
        ".m2": "Libraries Maven downloaded.",
        ".nvm": "Node.js versions installed with nvm.",
        ".vscode": "VS Code extensions.",
        ".docker": "Docker settings.",
        ".pico-sdk": "Raspberry Pi Pico toolchain and SDK.",
        ".local": "Programs and data installed for your user by command-line tools.",
        ".ftba": "FTB App: Minecraft modpack instances and downloads.",
        "go": "Go workspace and module cache.",
    ]

    private static let absolute: [String: String] = [
        "/": "Your startup disk.",
        "/System": "macOS itself. Read-only and protected; it can't be cleaned.",
        "/Applications": "Apps installed for everyone on this Mac.",
        "/Library": "Shared settings, fonts and support files for all users.",
        "/Users": "Home folders for each user.",
        "/Users/Shared": "Files shared by all users of this Mac.",
        "/private": "System data: temporary files, logs and the swap file. Managed by macOS.",
        "/private/var/folders": "Per-user temporary files and caches. macOS clears them over time.",
        "/private/var/vm": "Memory swap and sleep image. Managed by macOS.",
        "/usr": "Unix tools that ship with macOS.",
        "/opt/homebrew": "Homebrew and everything it installed.",
        "/usr/local": "Software installed outside the App Store, often by Homebrew on Intel Macs.",
    ]

    private static let byName: [String: String] = [
        "node_modules": "JavaScript packages for this project. Run npm install to bring them back.",
        ".venv": "Python virtual environment. Recreate it from requirements or pyproject.",
        "venv": "Python virtual environment. Recreate it from requirements or pyproject.",
        ".git": "Version history for this project. Deleting it loses the history.",
        "DerivedData": "Xcode build products. Rebuilt the next time you build.",
        "__pycache__": "Compiled Python files. Rebuilt automatically.",
        ".next": "Next.js build output. Rebuilt by the next build.",
        "target": "Build output. Rebuilt by the next build.",
        "Cache": "Cached data the app rebuilds.",
        "Code Cache": "Compiled scripts the app rebuilds.",
        "GPUCache": "Graphics shader cache the app rebuilds.",
        "CachedData": "Cached data the app rebuilds.",
    ]

    public static func describe(path: String) -> String? {
        if let d = absolute[path] { return d }
        let home = NSHomeDirectory()
        if path == home { return "Your home folder." }
        if path.hasPrefix(home + "/") {
            let rel = String(path.dropFirst(home.count + 1))
            if let d = homeRelative[rel] { return d }
        }
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".app") { return "An app. Moving it to the Trash uninstalls it." }
        if name.hasSuffix(".photoslibrary") { return "A Photos library. Manage it in Photos." }
        return byName[name]
    }
}
