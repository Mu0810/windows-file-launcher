# Windows File Launcher

A native macOS app that runs compatible Windows `.exe` and `.msi` files through Wine. It can store Wine's Windows C: drive on your Mac or on a writable external drive that supports symbolic links, such as an APFS drive.

## Build on your Mac

Use an Apple silicon Mac with macOS 14 or later, Xcode Command Line Tools with Swift 6, and Go 1.20 or later. From the repository folder, run:

```sh
./build.sh
open ".build/Windows File Launcher.app"
```

The build generates its own 32-bit and 64-bit Windows test programs and ad-hoc signs the Mac app for local use. Wine is installed separately.

## Run a Windows file

1. Click **Choose Wine** and select a compatible Wine app or executable. If no Wine runtime is found, the launcher can download a checksum-verified Wine Staging build. Intel Wine requires Rosetta on Apple silicon.
2. Select or drop a Windows `.exe` or `.msi`. Keep any companion installer files beside it.
3. Use **Storage** to choose where Wine creates its Windows C: drive, then click **Run Windows File**.

Use **Test Wine** to check 32-bit and 64-bit execution. For Inno Setup installers, **Run with Installer Log** captures additional diagnostic output. Compatibility depends on the selected Wine runtime and Windows program. Wine programs run with your macOS account's file access.
