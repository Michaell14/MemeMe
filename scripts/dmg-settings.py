# dmgbuild settings for MemeMe.dmg (scripts/build-dmg.sh): the window Finder shows when the DMG
# opens, with MemeMe.app on the left, a link to /Applications on the right and the background from
# Resources/DMG between them. The icon positions match the arrow in Resources/DMG/background.html.
#
# Defines (dmgbuild -D): app, the MemeMe.app to pack; background, the 1x PNG (dmgbuild combines it
# with the @2x file next to it).
import os.path

app = defines["app"]
app_name = os.path.basename(app.rstrip("/"))

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (170, 196),
    "Applications": (490, 196),
}
