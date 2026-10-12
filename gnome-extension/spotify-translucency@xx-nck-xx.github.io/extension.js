// Spotify Translucency: GNOME Shell part.
//
// 1. Sets Spotify's window opacity (from ~/.config/spotify-translucency/config,
//    OPACITY=<10-100>, re-read live whenever the file changes).
// 2. Fixes translucency being lost when Spotify covers a whole monitor
//    (fullscreen, or maximized on a monitor without the top bar): GNOME then
//    hands the window straight to the display ("direct scanout"/unredirect),
//    which skips compositing and therefore the opacity. While a translucent
//    Spotify window covers a monitor we ask the compositor not to do that.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const DEFAULT_OPACITY = 79;
const WINDOW_SIGNALS = [
    'notify::wm-class', 'notify::fullscreen', 'notify::maximized-horizontally',
    'notify::maximized-vertically', 'notify::minimized', 'position-changed',
    'size-changed', 'workspace-changed', 'shown',
];

export default class SpotifyTranslucency extends Extension {
    enable() {
        this._alpha = 255;
        this._inhibited = false;
        this._tracked = new Map();      // MetaWindow -> {windowIds, actor, actorIds}

        this._configFile = Gio.File.new_for_path(GLib.build_filenamev(
            [GLib.get_user_config_dir(), 'spotify-translucency', 'config']));
        this._readConfig();
        this._configMonitor = this._configFile.monitor_file(Gio.FileMonitorFlags.NONE, null);
        this._configMonitor.connect('changed', () => {
            this._readConfig();
            this._updateAll();
        });

        this._displayIds = [
            global.display.connect('window-created', (_d, w) => this._track(w)),
            global.display.connect('restacked', () => this._updateInhibit()),
        ];
        this._monitorsId = global.backend.get_monitor_manager().connect(
            'monitors-changed', () => this._updateAll());

        for (const actor of global.get_window_actors())
            this._track(actor.meta_window);
    }

    disable() {
        this._configMonitor?.cancel();
        this._configMonitor = null;
        this._displayIds?.forEach(id => global.display.disconnect(id));
        this._displayIds = null;
        if (this._monitorsId)
            global.backend.get_monitor_manager().disconnect(this._monitorsId);
        this._monitorsId = 0;
        for (const w of [...this._tracked.keys()])
            this._untrack(w, true);
        this._setInhibited(false);
        this._tracked = null;
    }

    _readConfig() {
        let pct = DEFAULT_OPACITY;
        try {
            const [, bytes] = this._configFile.load_contents(null);
            const m = new TextDecoder().decode(bytes).match(/^OPACITY=(\d+)\s*$/m);
            if (m)
                pct = Math.min(100, Math.max(10, Number(m[1])));
        } catch (_e) {
            // no config yet: keep the default
        }
        this._alpha = Math.round(pct * 255 / 100);
    }

    _isSpotify(w) {
        const cls = `${w.get_wm_class() ?? ''} ${w.get_wm_class_instance?.() ?? ''}`.toLowerCase();
        return cls.includes('spotify');
    }

    _track(w) {
        if (!w || this._tracked.has(w) || w.get_window_type() !== Meta.WindowType.NORMAL)
            return;
        const entry = {windowIds: [], actor: null, actorIds: []};
        this._tracked.set(w, entry);
        for (const sig of WINDOW_SIGNALS)
            entry.windowIds.push(w.connect(sig, () => this._update(w)));
        entry.windowIds.push(w.connect('unmanaged', () => this._untrack(w, false)));
        this._update(w);
    }

    _untrack(w, restore) {
        const entry = this._tracked.get(w);
        if (!entry)
            return;
        entry.windowIds.forEach(id => w.disconnect(id));
        entry.actorIds.forEach(id => entry.actor.disconnect(id));
        if (restore && this._isSpotify(w))
            this._applyAlpha(entry.actor, 255);
        this._tracked.delete(w);
        this._updateInhibit();
    }

    // Opacity goes on the actor's children (the window surface), not the
    // window actor itself, so GNOME's open/close/minimize animations, which
    // animate the window actor's opacity, don't overwrite it.
    _applyAlpha(actor, alpha) {
        actor?.get_children().forEach(child => {
            if (child.opacity !== alpha)
                child.opacity = alpha;
        });
    }

    _update(w) {
        const entry = this._tracked?.get(w);
        if (!entry || !this._isSpotify(w)) {
            this._updateInhibit();
            return;
        }
        const actor = w.get_compositor_private();
        if (actor && actor !== entry.actor) {
            entry.actorIds.forEach(id => entry.actor.disconnect(id));
            entry.actor = actor;
            entry.actorIds = [
                actor.connect('child-added', () => this._applyAlpha(actor, this._alpha)),
                actor.connect('destroy', () => {
                    entry.actor = null;
                    entry.actorIds = [];
                }),
            ];
        }
        this._applyAlpha(entry.actor, this._alpha);
        this._updateInhibit();
    }

    _updateAll() {
        for (const w of this._tracked.keys())
            this._update(w);
        this._updateInhibit();
    }

    _coversMonitor(w) {
        if (w.minimized || !w.showing_on_its_workspace?.() || !w.get_compositor_private()?.visible)
            return false;
        if (w.fullscreen)
            return true;
        const frame = w.get_frame_rect();
        const mon = global.display.get_monitor_geometry(w.get_monitor());
        return frame.x <= mon.x && frame.y <= mon.y &&
            frame.x + frame.width >= mon.x + mon.width &&
            frame.y + frame.height >= mon.y + mon.height;
    }

    _updateInhibit() {
        if (!this._tracked)
            return;
        const translucent = this._alpha < 255;
        const need = translucent &&
            [...this._tracked.keys()].some(w => this._isSpotify(w) && this._coversMonitor(w));
        this._setInhibited(need);
    }

    _setInhibited(on) {
        if (on === this._inhibited)
            return;
        this._inhibited = on;
        const compositor = global.compositor;
        if (compositor?.disable_unredirect) {
            if (on)
                compositor.disable_unredirect();
            else
                compositor.enable_unredirect();
        } else if (on) {
            Meta.disable_unredirect_for_display(global.display);
        } else {
            Meta.enable_unredirect_for_display(global.display);
        }
    }
}
