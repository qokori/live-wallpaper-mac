/// JavaScript for web wallpapers, injected at document start into every frame of the page.
///
/// It wraps `requestAnimationFrame`: callbacks run at most `frameRate` times per second and not at all while the
/// wallpaper is paused, so WebGL and canvas loops stop drawing. On pause it also freezes running CSS animations and
/// playing media, and resumes exactly those afterwards. In interactive mode the app forwards pointer events through
/// `pointer(...)`; they arrive as synthetic `pointer*`/`mouse*` events (`isTrusted` is false).
public enum WebPageScript {
    public enum PointerKind: String, Sendable {
        case move
        case down
        case up
    }

    public static func source(frameRate: Int, paused: Bool) -> String {
        """
        (() => {
          if (window.__liveWallpaper) return;
          const nativeFrame = window.requestAnimationFrame.bind(window);
          let interval = \(frameRate) > 0 ? 1000 / \(frameRate) : 0;
          let paused = \(paused);
          let last = -Infinity;
          let scheduled = false;
          let nextId = 1;
          let queue = new Map();
          let frozen = [];
          let buttons = 0;
          const schedule = () => {
            if (scheduled || paused || queue.size === 0) return;
            scheduled = true;
            nativeFrame(tick);
          };
          const tick = (now) => {
            scheduled = false;
            if (paused) return;
            if (now - last < interval - 2) { schedule(); return; }
            last = now;
            const callbacks = queue;
            queue = new Map();
            for (const callback of callbacks.values()) {
              try { callback(now); } catch (error) { setTimeout(() => { throw error; }, 0); }
            }
          };
          window.requestAnimationFrame = (callback) => {
            const id = nextId++;
            queue.set(id, callback);
            schedule();
            return id;
          };
          window.cancelAnimationFrame = (id) => { queue.delete(id); };
          const freeze = () => {
            frozen = [];
            for (const animation of (document.getAnimations ? document.getAnimations() : [])) {
              if (animation.playState === 'running') { animation.pause(); frozen.push(animation); }
            }
            for (const media of document.querySelectorAll('video, audio')) {
              if (!media.paused) { media.pause(); frozen.push(media); }
            }
          };
          const thaw = () => {
            for (const item of frozen) {
              const result = item.play();
              if (result && result.catch) result.catch(() => {});
            }
            frozen = [];
          };
          window.__liveWallpaper = {
            setPaused(value) {
              if (value === paused) return;
              paused = value;
              if (paused) { freeze(); } else { thaw(); last = -Infinity; schedule(); }
            },
            setFrameRate(fps) { interval = fps > 0 ? 1000 / fps : 0; },
            pointer(type, x, y) {
              if (type === 'down') buttons = 1;
              if (type === 'up') buttons = 0;
              const target = document.elementFromPoint(x, y) || document.documentElement;
              const init = {
                bubbles: true, cancelable: true, composed: true, view: window,
                clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons,
                pointerId: 1, pointerType: 'mouse', isPrimary: true,
              };
              const names = { move: ['pointermove', 'mousemove'], down: ['pointerdown', 'mousedown'],
                              up: ['pointerup', 'mouseup', 'click'] }[type] || [];
              for (const name of names) {
                target.dispatchEvent(name.startsWith('pointer') ? new PointerEvent(name, init) : new MouseEvent(name, init));
              }
            },
          };
        })();
        """
    }

    public static func setPaused(_ paused: Bool) -> String {
        "window.__liveWallpaper && window.__liveWallpaper.setPaused(\(paused))"
    }

    public static func setFrameRate(_ frameRate: Int) -> String {
        "window.__liveWallpaper && window.__liveWallpaper.setFrameRate(\(frameRate))"
    }

    public static func pointer(_ kind: PointerKind, x: Double, y: Double) -> String {
        "window.__liveWallpaper && window.__liveWallpaper.pointer('\(kind.rawValue)', \(x), \(y))"
    }
}
