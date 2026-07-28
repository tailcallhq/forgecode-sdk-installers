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
        set bounds of volumeWindow to {100, 100, 760, 500}
        set viewOptions to icon view options of volumeWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png" of volumeFolder
        set position of item "ForgeCode.app" of volumeFolder to {180, 235}
        set position of item "Applications" of volumeFolder to {480, 235}
        close volumeWindow
        open volumeFolder
        update volumeFolder without registering applications
        delay 2
    end tell
end run
