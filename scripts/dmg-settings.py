"""Finder layout consumed by dmgbuild; paths are supplied by the build script."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Meeting Notes.app"]
format = "ULFO"
filesystem = "APFS"
background = defines["background"]
window_rect = ((200, 160), (640, 400))
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
