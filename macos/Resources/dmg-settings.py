# dmgbuild settings for Medic.dmg, used by tools/macapp.sh. It passes
# -D app=PATH -D background=PATH. Positions match macos/Art/draw.swift.
import os.path

app = defines["app"]  # noqa: F821, dmgbuild provides defines
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 180), "Applications": (470, 180)}

format = "UDZO"
filesystem = "HFS+"
background = defines["background"]  # noqa: F821
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
