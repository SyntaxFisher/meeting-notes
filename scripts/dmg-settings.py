"""Finder layout consumed by dmgbuild; paths are supplied by the build script."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
# Do not use hide_extensions: SetFile adds FinderInfo to the signed app bundle.
format = "ULFO"
filesystem = "APFS"
background = None  # dmg-layout.py references artwork inside the signed app.
window_rect = ((200, 160), (640, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
icon_size = 96
icon_locations = {"Meeting Notes.app": (170, 200), "Applications": (470, 200)}
