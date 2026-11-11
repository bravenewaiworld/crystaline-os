Crystaline OS writes this file. Don't edit it: your changes are undone the next time the Brick starts.

This SD card belongs to a TrimUI Brick running Crystaline OS. It holds your
games, saves and settings.

FOLDERS

roms/     Your games. Any folder layout works: Specular (the game menu)
          recognises each game's system by itself. A folder per system (gba,
          ps1, ...) still keeps things tidy, and is needed for disc images
          (.cue, .chd), which several systems share. Save states are kept
          beside the games, in hidden .states folders.
bios/     BIOS files. Don't rename them: emulators look for each one by its
          exact name.
saves/    Your game saves, named after their games and in matching folders:
          roms/gba/Golden Sun.gba saves to saves/gba/Golden Sun.srm.
updates/  Crystaline OS update files (.update). See updates/README.txt.
backups/  Only after installing Crystaline OS to the Brick's internal storage:
          the copy of TrimUI's system made then. It is your way back to it, so
          don't delete it. See backups/README.txt.
logs/     Reports of installs, updates and card repairs, and Specular's log
          (specular.log).
config/   Your settings.
cache/    Box art and game lists. Safe to delete: they are rebuilt
          automatically.
Other folders belong to Specular; those that need it have a README.txt.

GOING BACK TO TRIMUI'S SYSTEM

If you never installed Crystaline OS to the Brick's internal storage (there is
no backups/ folder on this card), TrimUI's system is still on the Brick,
unchanged: turn the Brick off, take this card out, and turn it on again.
Otherwise, see backups/README.txt.

DON'T FORMAT THIS CARD

When you plug this card into a PC, it may show extra drives it can't open, or
say a drive needs formatting. Always answer No or Cancel: those parts hold
Crystaline OS itself. Formatting the drive that shows this file erases your
games, saves and backups.
