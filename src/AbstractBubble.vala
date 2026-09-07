/*
* Copyright 2020-2025 elementary, Inc. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*
*/

public enum Notifications.CloseReason {
    EXPIRED = 1,
    DISMISSED = 2,
    /**
     * This value is unique for org.freedesktop.Notifications server interface and must not be used elsewhere.
     */
    CLOSE_NOTIFICATION_CALL = 3,
    UNDEFINED = 4
}

public class Notifications.AbstractBubble : Gtk.Window {
    public signal void closed (CloseReason reason) {
        close ();
    }

    public uint32 timeout { get; set; }

    protected Gtk.Stack content_area;

    private static Settings? transparency_settings;

    private Gtk.Revealer close_revealer;
    private Gtk.Box draw_area;
    private Gtk.Overlay overlay;

    private uint timeout_id;

    private double current_swipe_progress = 1.0;

    static construct {
        var transparency_schema = SettingsSchemaSource.get_default ().lookup ("io.elementary.desktop.wingpanel", true);
        if (transparency_schema != null && transparency_schema.has_key ("use-transparency")) {
            transparency_settings = new Settings ("io.elementary.desktop.wingpanel");
        }
    }

    construct {
        content_area = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_DOWN,
            vhomogeneous = false
        };

        draw_area = new Gtk.Box (HORIZONTAL, 0) {
            hexpand = true
        };
        draw_area.add_css_class ("draw-area");
        draw_area.append (content_area);

        var close_button = new Gtk.Button.from_icon_name ("window-close-symbolic") {
            halign = Gtk.Align.START,
            valign = Gtk.Align.START
        };
        close_button.add_css_class ("close");

        close_revealer = new Gtk.Revealer () {
            reveal_child = false,
            transition_type = Gtk.RevealerTransitionType.CROSSFADE,
            halign = Gtk.Align.START,
            valign = Gtk.Align.START,
            child = close_button,
            overflow = VISIBLE
        };

        overlay = new Gtk.Overlay () {
            child = draw_area
        };
        overlay.add_overlay (close_revealer);

        var carousel = new Adw.Carousel () {
            hexpand = true
        };
        carousel.append (new Gtk.Grid ());
        carousel.append (overlay);
        carousel.scroll_to (overlay, false);

        child = carousel;
        default_width = 332;
        resizable = false;
        add_css_class ("notification");
        // Prevent stealing focus when an app window is closed
        can_focus = false;
        focusable = false;
        set_titlebar (new Gtk.Grid ());

        carousel.page_changed.connect (on_page_changed);
        close_button.clicked.connect (() => closed (CloseReason.DISMISSED));

        var motion_controller = new Gtk.EventControllerMotion ();
        motion_controller.enter.connect (pointer_enter);
        motion_controller.leave.connect (pointer_leave);
        carousel.add_controller (motion_controller);

        accessible_role = ALERT;

        child.realize.connect (() => {
            if (Gdk.Display.get_default () is Gdk.X11.Display) {
                x11_make_notification ();
                x11_update_mutter_hints ();
            }
        });

        if (Gdk.Display.get_default () is Gdk.Wayland.Display) {
            GtkLayerShell.init_for_window (this);
            GtkLayerShell.set_layer (this, GtkLayerShell.Layer.TOP);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
        }

        carousel.notify["position"].connect (update_swipe_progress);

        transparency_settings.changed["use-transparency"].connect (update_transparency);
        update_transparency ();
    }

    private void update_transparency () requires (transparency_settings != null) {
        if (transparency_settings.get_boolean ("use-transparency")) {
            remove_css_class ("reduce-transparency");
        } else {
            add_css_class ("reduce-transparency");
        }
    }

    private void on_page_changed (Adw.Carousel carousel, uint index) {
        if (carousel.get_nth_page (index) != overlay) {
            closed (CloseReason.DISMISSED);
        }
    }

    private void update_swipe_progress (Object obj, ParamSpec pspec) {
        var carousel = (Adw.Carousel) obj;

        current_swipe_progress = carousel.position;

        if (Gdk.Display.get_default () is Gdk.X11.Display) {
            x11_update_mutter_hints ();
        }
    }

    public new void present () {
        if (timeout_id != 0) {
            Source.remove (timeout_id);
            timeout_id = 0;
        }

        if (Gdk.Display.get_default () is Gdk.X11.Display) {
            // Avoid present on X11 because it focuses the window
            base.show ();
        } else {
            base.present ();
        }

        if (timeout != 0) {
            timeout_id = Timeout.add (timeout, timeout_expired);
        }
    }

    private void pointer_enter () {
        close_revealer.reveal_child = true;

        if (timeout_id != 0) {
            Source.remove (timeout_id);
            timeout_id = 0;
        }
    }

    private void pointer_leave () {
        close_revealer.reveal_child = false;

        if (timeout != 0) {
            timeout_id = Timeout.add (timeout, timeout_expired);
        }
    }

    private bool timeout_expired () {
        closed (CloseReason.EXPIRED);
        return Source.REMOVE;
    }

    private void get_blur_margins (out int left, out int right) {
        var width = get_width ();
        var distance = (1 - current_swipe_progress) * width;
        left = (int) (16 + distance).clamp (0, width);
        right = (int) (16 - distance).clamp (0, width);
    }

    private void x11_update_mutter_hints () {
        var display = Gdk.Display.get_default ();
        if (display is Gdk.X11.Display) {
            unowned var xdisplay = ((Gdk.X11.Display) display).get_xdisplay ();

            var window = ((Gdk.X11.Surface) get_surface ()).get_xid ();
            var prop = xdisplay.intern_atom ("_MUTTER_HINTS", false);

            int left, right;
            get_blur_margins (out left, out right);

            var value = "blur=%d,%d,16,16,9".printf (left, right);

            xdisplay.change_property (window, prop, X.XA_STRING, 8, 0, (uchar[]) value, value.length);
        }
    }

    private void x11_make_notification () {
        unowned var display = Gdk.Display.get_default ();
        if (display is Gdk.X11.Display) {
            unowned var x11_surface = (Gdk.X11.Surface) get_surface ();
            var window = (x11_surface).get_xid ();
            x11_surface.set_skip_pager_hint (true);
            x11_surface.set_skip_taskbar_hint (true);

            unowned var xdisplay = ((Gdk.X11.Display) display).get_xdisplay ();
            var atom = xdisplay.intern_atom ("_NET_WM_WINDOW_TYPE", false);
            var notification_atom = xdisplay.intern_atom ("_NET_WM_WINDOW_TYPE_NOTIFICATION", false);

            // (X.Atom) 4 is XA_ATOM
            // 32 is format
            // 0 means replace
            xdisplay.change_property (window, atom, (X.Atom) 4, 32, 0, (uchar[]) notification_atom, 1);
        }
    }

}
