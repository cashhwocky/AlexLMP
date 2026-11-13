#!/usr/bin/env python3
"""AlexLMP: Google sign-in window for YouTube Music on Linux.

Opens Google's normal sign-in page in a small window (WebKitGTK, the same
engine GNOME uses for its own Google sign-in). Every sign-in starts fresh, so
you can pick or add any Google account. When YouTube Music has loaded signed
in, prints its cookies on one line and exits 0. Closing the window exits 1.
"""
import sys

import gi

LOGIN_URL = (
    "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube"
    "&passive=true&continue=https%3A%2F%2Fmusic.youtube.com%2F"
)
COOKIE_URL = "https://music.youtube.com/"
UA = ("Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:133.0) "
      "Gecko/20100101 Firefox/133.0")

GTK4 = False
try:
    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    from gi.repository import GLib, Gtk, WebKit2 as WebKit
except (ValueError, ImportError):
    try:
        gi.require_version("Gtk", "3.0")
        gi.require_version("WebKit2", "4.0")
        from gi.repository import GLib, Gtk, WebKit2 as WebKit
    except (ValueError, ImportError):
        gi.require_version("Gtk", "4.0")
        gi.require_version("WebKit", "6.0")
        from gi.repository import GLib, Gtk, WebKit
        GTK4 = True

loop = GLib.MainLoop()
result = {"cookies": None}


def cookie_text(cookies):
    parts = []
    for c in cookies or []:
        name = c.get_name() if hasattr(c, "get_name") else c.name
        value = c.get_value() if hasattr(c, "get_value") else c.value
        parts.append(f"{name}={value}")
    return "; ".join(parts)


def finish(cookies=None):
    result["cookies"] = cookies
    if loop.is_running():
        loop.quit()


if GTK4:
    session = WebKit.NetworkSession.new_ephemeral()
    web = WebKit.WebView(network_session=session)
    cookie_manager = session.get_cookie_manager()
else:
    context = WebKit.WebContext.new_ephemeral()
    web = WebKit.WebView.new_with_context(context)
    cookie_manager = context.get_cookie_manager()

settings = web.get_settings()
settings.set_user_agent(UA)
settings.set_enable_javascript(True)


def on_cookies(manager, res, _data=None):
    try:
        text = cookie_text(manager.get_cookies_finish(res))
    except Exception:  # noqa: BLE001
        return
    if "SAPISID=" in text:
        finish(text)


def on_load(view, event):
    uri = view.get_uri() or ""
    if event == WebKit.LoadEvent.FINISHED and uri.startswith("https://music.youtube.com"):
        cookie_manager.get_cookies(COOKIE_URL, None, on_cookies, None)


web.connect("load-changed", on_load)

win = Gtk.Window(title="Sign in to YouTube Music")
win.set_default_size(480, 720)
if GTK4:
    win.set_child(web)
    win.connect("close-request", lambda *_: (finish(None), False)[1])
    win.present()
else:
    win.add(web)
    win.connect("delete-event", lambda *_: (finish(None), False)[1])
    win.show_all()

web.load_uri(LOGIN_URL)
loop.run()

if result["cookies"]:
    print(result["cookies"], flush=True)
    sys.exit(0)
sys.exit(1)
