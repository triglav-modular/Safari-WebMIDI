# dmgbuild settings for Web-MIDI.dmg: the app beside a link to /Applications
# on a background with an arrow from one to the other.  tools/build.sh
# passes the geometry with -D, so the background and the icons agree.
# Finder measures icon positions from the top of the view to the icon's
# centre.  Finder on macOS 27 shows its toolbar, path bar and status bar
# whatever is asked for below, which leaves about 207 of the window's 330
# points for the icons; build.sh's ICON_Y centres an icon and its name there.
import os.path

app = defines['app']
w, h = int(defines['width']), int(defines['height'])
icon_y = int(defines['icon_y'])

format = 'UDZO'
filesystem = 'HFS+'
files = [app]
symlinks = {'Applications': '/Applications'}
background = defines['background']
# dmgbuild names it .background.tiff; Finder still counted it as an item.
hide = ['.background.tiff']

window_rect = ((200, 160), (w, h))
default_view = 'icon-view'
show_toolbar = False
show_pathbar = False
show_status_bar = False
show_tab_view = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = int(defines['icon_size'])
text_size = 13
label_pos = 'bottom'
icon_locations = {
    os.path.basename(app): (int(defines['app_x']), icon_y),
    'Applications': (int(defines['apps_x']), icon_y),
}
