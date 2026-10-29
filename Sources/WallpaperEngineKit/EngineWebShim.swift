import Foundation

/// JavaScript that gives a Wallpaper Engine web wallpaper the host it expects.
///
/// The page registers `window.wallpaperPropertyListener` with `applyUserProperties`, `applyGeneralProperties` and
/// `setPaused`. Once the page has loaded (or later, when it registers the listener late) it gets the settings of
/// `project.json` with their default values and the frame rate, and `setPaused` follows our pause. The audio and media
/// registration functions exist, so a page that calls them does not break, but they are never called back: no audio
/// spectrum and no media information is produced.
public enum EngineWebShim {
    /// `{"key": {"value": …}}` from the project's settings, as JavaScript.
    public static func propertiesLiteral(_ properties: [EngineProject.Property]) -> String {
        let items = properties.compactMap { property -> String? in
            guard let value = property.valueJSON, let key = jsonString(property.key) else { return nil }
            return "\(key): {value: \(value)}"
        }
        return "{" + items.joined(separator: ", ") + "}"
    }

    private static func jsonString(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), var json = String(data: data, encoding: .utf8) else { return nil }
        json.removeFirst()
        json.removeLast()
        // A script block: keep a closing tag in a value from ending it.
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }

    public static func source(properties: [EngineProject.Property], frameRate: Int, paused: Bool) -> String {
        """
        (() => {
          if (window.__engineShim) return;
          const properties = \(propertiesLiteral(properties));
          let fps = \(frameRate);
          let paused = \(paused);
          let listener;
          let loaded = false;
          const call = (target, name, argument) => {
            try { if (target && typeof target[name] === 'function') target[name](argument); }
            catch (error) { setTimeout(() => { throw error; }, 0); }
          };
          const deliver = (target) => {
            call(target, 'applyGeneralProperties', { fps });
            call(target, 'applyUserProperties', properties);
            if (paused) call(target, 'setPaused', true);
          };
          Object.defineProperty(window, 'wallpaperPropertyListener', {
            configurable: true,
            get: () => listener,
            set: (value) => { listener = value; if (loaded) setTimeout(() => deliver(value), 0); },
          });
          const quiet = () => {};
          for (const name of ['wallpaperRegisterAudioListener', 'wallpaperRegisterMediaStatusListener',
                              'wallpaperRegisterMediaPropertiesListener', 'wallpaperRegisterMediaThumbnailListener',
                              'wallpaperRegisterMediaPlaybackListener', 'wallpaperRegisterMediaTimelineListener']) {
            window[name] = quiet;
          }
          window.addEventListener('load', () => { loaded = true; setTimeout(() => deliver(listener), 0); });
          window.__engineShim = {
            setPaused(value) {
              if (value === paused) return;
              paused = value;
              if (loaded) call(listener, 'setPaused', value);
            },
            setFrameRate(value) {
              fps = value;
              if (loaded) call(listener, 'applyGeneralProperties', { fps });
            },
          };
        })();
        """
    }

    public static func setPaused(_ paused: Bool) -> String {
        "window.__engineShim && window.__engineShim.setPaused(\(paused))"
    }

    public static func setFrameRate(_ frameRate: Int) -> String {
        "window.__engineShim && window.__engineShim.setFrameRate(\(frameRate))"
    }
}
