import Foundation

/// One-line descriptions of folders people commonly wonder about.
public enum KnownFolders {
    private static let homeRelative: [String: String] = [
        "Library": "Settings, caches and data for your apps. Hidden in Finder by default.",
        "Library/Caches": "Temporary files apps use to load faster. Apps re-create them as needed.",
        "Library/Application Support": "Data apps store for themselves, such as libraries, databases and downloaded content.",
        "Library/Containers": "Data for App Store and other sandboxed apps, one folder per app.",
        "Library/Group Containers": "Data shared between apps from the same developer.",
        "Library/Logs": "Diagnostic logs written by apps and macOS.",
        "Library/Mobile Documents": "iCloud Drive. Removing items here also removes them from your other devices.",
        "Library/CloudStorage": "Folders synced by Google Drive, Dropbox, OneDrive and similar apps.",
        "Library/Mail": "Your Mail messages and attachments.",
        "Library/Messages": "Your Messages history and attachments.",
        "Library/Developer": "Data from Xcode and developer tools.",
        "Library/Developer/Xcode/DerivedData": "Xcode build products, rebuilt the next time you build.",
        "Library/Developer/Xcode/Archives": "Builds archived in Xcode. Needed to symbolicate their crash reports.",
        "Library/Developer/Xcode/iOS DeviceSupport": "Debug symbols copied from connected devices.",
        "Library/Developer/CoreSimulator": "Simulator devices and the apps installed on them.",
        "Library/Application Support/MobileSync/Backup": "iPhone and iPad backups made by Finder.",
        "Library/Containers/com.docker.docker": "Docker Desktop and its virtual disk.",
        "Library/Application Support/Steam": "Steam games and downloads. Uninstall games in Steam.",
        "Library/Caches/Homebrew": "Packages downloaded by Homebrew.",
        "Library/Saved Application State": "Window positions apps restore at launch.",
        "Library/Preferences": "Settings files for your apps.",
        "Library/Fonts": "Fonts you installed.",
        "Library/Keychains": "Your saved passwords and certificates.",
        "Movies/TV": "Movies and shows downloaded in the TV app.",
        "Music/Music": "Your Music library.",
        "Pictures/Photos Library.photoslibrary": "Your Photos library.",
        "Downloads": "Files downloaded from the internet.",
        "Desktop": "Files on your desktop.",
        "Documents": "Your documents.",
        ".Trash": "Items in the Trash. Empty the Trash to free this space.",
        ".npm": "Package cache for npm.",
        ".cache": "Caches for command-line tools.",
        ".cache/huggingface": "Models downloaded from Hugging Face.",
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
        "/": "Startup disk.",
        "/System": "macOS system files. Read-only.",
        "/Applications": "Apps installed for everyone on this Mac.",
        "/Library": "Shared settings, fonts and support files for all users.",
        "/Users": "Home folders for each user.",
        "/Users/Shared": "Files shared by all users of this Mac.",
        "/private": "System data, including temporary files, logs and swap. Managed by macOS.",
        "/private/var/folders": "Temporary files and caches, cleared by macOS over time.",
        "/private/var/vm": "Swap and sleep image. Managed by macOS.",
        "/usr": "Unix tools that ship with macOS.",
        "/opt/homebrew": "Homebrew and everything it installed.",
        "/usr/local": "Software installed outside the App Store.",
    ]

    private static let byName: [String: String] = [
        "node_modules": "JavaScript packages for this project. Restore with npm install.",
        ".venv": "Python virtual environment.",
        "venv": "Python virtual environment.",
        ".git": "Version history for this project.",
        "DerivedData": "Xcode build products.",
        "__pycache__": "Compiled Python files.",
        ".next": "Next.js build output.",
        "target": "Build output.",
        "Cache": "Cached web content.",
        "Code Cache": "Cached scripts.",
        "GPUCache": "Cached graphics shaders.",
        "CachedData": "Cached data.",
    ]

    public static func describe(path: String) -> String? {
        if let d = absolute[path] { return d }
        let home = AppPaths.home
        if path == home { return "Home folder." }
        if path.hasPrefix(home + "/") {
            let rel = String(path.dropFirst(home.count + 1))
            if let d = homeRelative[rel] { return d }
        }
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".app") { return "Application." }
        if name.hasSuffix(".photoslibrary") { return "Photos library." }
        return byName[name]
    }
}
