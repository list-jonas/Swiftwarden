import os

app = defines.get("app", "dist/Swiftwarden.app")

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = defines.get("background", "scripts/dmg/background.tiff")

format = "ULFO"
window_rect = ((200, 140), (640, 452))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
hide_extensions = [os.path.basename(app)]
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
}
