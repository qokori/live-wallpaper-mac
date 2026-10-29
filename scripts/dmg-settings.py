# dmgbuild settings for the installer window. Run through scripts/make-dmg.sh, which passes the values with -D.
# dmgbuild writes the window's .DS_Store itself: no Finder, no AppleScript.
import os

defines = globals().get("defines", {})
app = defines["app"]
w, h, app_x, app_y, apps_x, apps_y = (int(v) for v in defines["layout"].split())

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]            # becomes .VolumeIcon.icns
background = defines["background"]       # a multi-representation TIFF: 1x and @2x
icon_size = 128
text_size = 13
window_rect = ((200, 160), (w, h))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_locations = {
    os.path.basename(app): (app_x, app_y),
    "Applications": (apps_x, apps_y),
}
