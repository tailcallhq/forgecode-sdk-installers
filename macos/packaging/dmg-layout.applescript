on run argv
    if (count of argv) is not 1 then error "usage: dmg-layout.applescript MOUNT_PATH"
    set mountPath to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        set volumeFolder to folder mountPath
        open volumeFolder
        set volumeWindow to container window of volumeFolder
        set current view of volumeWindow to icon view
        set toolbar visible of volumeWindow to false
        set statusbar visible of volumeWindow to false
        -- Window bounds include the title bar (28 pt on modern macOS), so add
        -- it on top of the 660x440 background/content area; otherwise the
        -- bottom of the background is clipped. The content area carries extra
        -- vertical slack so icon labels/footer stay visible even when Finder
        -- chrome (path/status bar) shrinks it.
        set bounds of volumeWindow to {100, 100, 760, 568}
        set viewOptions to icon view options of volumeWindow
        set arrangement of viewOptions to not arranged
        -- Icon size must match the slot size baked into the background
        -- artwork's neuron/icon geometry (generate-assets.swift).
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        -- The background file must NOT be a dot-file at the volume root:
        -- when Finder is not showing hidden files (the default, and what CI
        -- runners use), it cannot resolve such an item and `set background
        -- picture` fails with -10006. The file is named plainly here and made
        -- invisible afterwards via `chflags hidden` in create-dmg.sh.
        set background picture of viewOptions to file "background.png" of volumeFolder
        set position of item "ForgeCode.app" of volumeFolder to {180, 210}
        set position of item "Applications" of volumeFolder to {480, 210}
        -- Park support files outside the visible window area so they never
        -- appear in the drag-and-drop layout, even when Finder is configured
        -- to show hidden files (same technique as create-dmg).
        set position of item "background.png" of volumeFolder to {900, 130}
        close volumeWindow
        open volumeFolder
        -- Re-apply the icon positions after the close/reopen cycle: Finder
        -- re-derives icon coordinates when the window reopens and, at detach
        -- time, flushes them to .DS_Store shifted down by the title-bar
        -- height (+27 pt observed), which pushed the icons below the wire
        -- endpoints baked into the background. Setting the positions again in
        -- the reopened window makes Finder persist the exact values.
        set position of item "ForgeCode.app" of volumeFolder to {180, 210}
        set position of item "Applications" of volumeFolder to {480, 210}
        update volumeFolder without registering applications
        delay 2
    end tell
end run
