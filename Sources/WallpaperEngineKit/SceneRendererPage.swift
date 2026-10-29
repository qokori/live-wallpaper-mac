/// The page that draws a scene: WebGL2, one textured quad per layer, parallax from the pointer. It reads `scene.json`
/// and `t/<n>` from the same address (see `SceneAssets`) and reports to the app through `webkit.messageHandlers.scene`.
public enum SceneRendererPage {
    public static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}canvas{display:block;width:100vw;height:100vh}</style>
    </head><body><canvas id="c"></canvas><script>
    (() => {
      const post = (message) => { try { webkit.messageHandlers.scene.postMessage(message); } catch (e) {} };
      const status = { drawn: 0, unknownModes: [], failed: [], videos: 0, canvas: [0, 0], parallax: [0, 0] };
      const api = window.__lwScene = {
        status: () => { status.videosPlaying = videos.filter((entry) => !entry.video.paused).length; return JSON.stringify(status); },
        setMouse(x, y) { target = [x, y]; },
        setScaling(mode) { scaling = mode; layoutDirty = true; dirty = true; if (scene) draw(); },
        // One step of the loop by hand (the page's own loop waits for the screen to ask for frames).
        // Which of the page's own blend modes a `colorBlendMode` number means (for checking numbers against previews).
        setModeMap(map) { modeMap = map; dirty = true; if (scene) draw(); },
        step(seconds) { if (scene) advance(seconds); },
      };
      let modeMap = { 1: 1, 31: 2 };
      let target = [0.5, 0.5], smooth = [0.5, 0.5], scaling = 'fill', layoutDirty = true, dirty = true;
      const fail = (message) => { status.error = String(message); post({ type: 'error', message: String(message) }); };
      const gl = document.getElementById('c').getContext('webgl2', { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'low-power' });
      if (!gl) { fail('WebGL2 недоступен'); return; }
      const canvas = gl.canvas;

      const compile = (type, source) => {
        const shader = gl.createShader(type);
        gl.shaderSource(shader, source); gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
        return shader;
      };
      const program = gl.createProgram();
      gl.attachShader(program, compile(gl.VERTEX_SHADER, `#version 300 es
        in vec2 p; uniform vec4 uAB; uniform vec2 uT; uniform vec2 uS; uniform vec2 uShift; uniform vec4 uView; out vec2 vUv;
        void main() {
          vec2 l = p * uS;
          vec2 w = vec2(uAB.x * l.x + uAB.z * l.y, uAB.y * l.x + uAB.w * l.y) + uT + uShift;
          gl_Position = vec4(w * uView.zw + uView.xy, 0.0, 1.0);
          vUv = vec2(p.x + 0.5, 0.5 - p.y);
        }`));
      gl.attachShader(program, compile(gl.FRAGMENT_SHADER, `#version 300 es
        precision highp float; in vec2 vUv; uniform sampler2D uTex; uniform vec4 uTint; uniform int uMode; out vec4 o;
        void main() {
          vec4 c = texture(uTex, vUv);
          vec3 rgb = c.rgb * uTint.rgb;
          float a = c.a * uTint.a;
          if (uMode == 1) o = vec4(mix(vec3(1.0), rgb, a), 1.0);
          else if (uMode == 2 || uMode == 3) o = vec4(rgb * a, 1.0);
          else o = vec4(rgb, a);
        }`));
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) { fail(gl.getProgramInfoLog(program)); return; }
      gl.useProgram(program);
      const u = (name) => gl.getUniformLocation(program, name);
      const loc = { ab: u('uAB'), t: u('uT'), s: u('uS'), shift: u('uShift'), view: u('uView'), tint: u('uTint'), mode: u('uMode'), tex: u('uTex') };
      const buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-.5, -.5, .5, -.5, -.5, .5, .5, .5]), gl.STATIC_DRAW);
      const attribute = gl.getAttribLocation(program, 'p');
      gl.enableVertexAttribArray(attribute);
      gl.vertexAttribPointer(attribute, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(loc.tex, 0);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);

      let scene, textures = [], layers = [], videos = [], rect = [0, 0, 1, 1];

      const makeTexture = () => {
        const texture = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        return texture;
      };
      const loadTexture = async (info) => {
        const texture = makeTexture();
        const result = { texture, info, ok: false };
        // Pictures load side by side: bind again after every wait, another one may have been bound meanwhile.
        const bind = () => gl.bindTexture(gl.TEXTURE_2D, texture);
        if (info.kind === 'raw') {
          const bytes = new Uint8Array(await (await fetch(info.url)).arrayBuffer());
          bind();
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, info.w, info.h, 0, gl.RGBA, gl.UNSIGNED_BYTE, bytes);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
          result.ok = true;
        } else if (info.kind === 'image') {
          const image = new Image();
          image.src = info.url;
          await image.decode();
          bind();
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
          gl.generateMipmap(gl.TEXTURE_2D);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
          result.ok = true;
        } else {
          const video = document.createElement('video');
          video.muted = true; video.defaultMuted = true; video.loop = true; video.playsInline = true;
          video.preload = 'auto'; video.disableRemotePlayback = true;
          video.src = info.url;
          await new Promise((resolve, reject) => {
            video.addEventListener('loadeddata', resolve, { once: true });
            video.addEventListener('error', () => reject(new Error('видео не открылось')), { once: true });
            setTimeout(() => reject(new Error('видео не загрузилось за 20 с')), 20000);
          });
          // A video that has not played yet hands over an empty picture: let it show one frame, then stop it again
          // (a wallpaper that starts paused must not play).
          try {
            await video.play();
            await new Promise((resolve) => {
              if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(() => resolve());
              else video.addEventListener('timeupdate', () => resolve(), { once: true });
              setTimeout(resolve, 2000);
            });
          } catch (error) { /* the first frame may still come */ }
          video.pause();
          bind();
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
          result.video = video; result.time = -1;
          status.muted = video.muted;
          videos.push(result);
          status.videos += 1;
          result.ok = true;
        }
        return result;
      };

      const uploadVideos = () => {
        for (const entry of videos) {
          const video = entry.video;
          if (video.readyState < 2 || video.currentTime === entry.time) continue;
          entry.time = video.currentTime;
          gl.bindTexture(gl.TEXTURE_2D, entry.texture);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
          entry.uploaded = gl.getError() === gl.NO_ERROR;
          status.uploads = (status.uploads || 0) + 1; status.uploaded = entry.uploaded;
          status.videoState = [video.readyState, video.videoWidth, video.videoHeight, video.currentTime, video.paused];
          dirty = true;
        }
      };

      const layout = () => {
        const ratio = Math.min(window.devicePixelRatio || 1, 2);
        let w = Math.max(1, Math.round(innerWidth * ratio)), h = Math.max(1, Math.round(innerHeight * ratio));
        const cap = Math.max(scene.width, scene.height) / Math.max(w, h);
        if (cap < 1) { w = Math.max(1, Math.round(w * cap)); h = Math.max(1, Math.round(h * cap)); }
        if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
        status.canvas = [w, h];
        const sx = w / scene.width, sy = h / scene.height;
        let fx = sx, fy = sy;
        if (scaling === 'fill') fx = fy = Math.max(sx, sy);
        else if (scaling === 'fit') fx = fy = Math.min(sx, sy);
        const rw = scene.width * fx, rh = scene.height * fy;
        rect = [Math.round((w - rw) / 2), Math.round((h - rh) / 2), Math.round(rw), Math.round(rh)];
        layoutDirty = false;
      };

      const blendFor = (layer) => {
        const mapped = modeMap[layer.mode];
        if (mapped) return mapped;
        if (layer.mode !== 0 && !status.unknownModes.includes(layer.mode)) status.unknownModes.push(layer.mode);
        return 0;
      };

      const draw = () => {
        if (layoutDirty) layout();
        gl.disable(gl.SCISSOR_TEST);
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.clearColor(0, 0, 0, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.viewport(rect[0], rect[1], rect[2], rect[3]);
        gl.enable(gl.SCISSOR_TEST);
        gl.scissor(rect[0], rect[1], rect[2], rect[3]);
        gl.clearColor(scene.clear[0], scene.clear[1], scene.clear[2], 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform4f(loc.view, -1, -1, 2 / scene.width, 2 / scene.height);
        const p = scene.parallax;
        const k = p.enabled ? 2 * p.amount * p.influence : 0;
        // The camera follows the pointer, so layers move the other way, the deeper ones more.
        const dx = -(smooth[0] - 0.5) * k * scene.width, dy = (smooth[1] - 0.5) * k * scene.height;
        for (const layer of layers) {
          const entry = textures[layer.tex];
          if (!entry || !entry.ok || (entry.video && !entry.uploaded)) continue;
          const m = layer.m;
          gl.uniform4f(loc.ab, m[0], m[1], m[2], m[3]);
          gl.uniform2f(loc.t, m[4], m[5]);
          gl.uniform2f(loc.s, layer.size[0], layer.size[1]);
          gl.uniform2f(loc.shift, dx * layer.depth[0], dy * layer.depth[1]);
          const mode = blendFor(layer);
          gl.uniform1i(loc.mode, mode);
          gl.uniform4f(loc.tint, layer.color[0] * layer.brightness, layer.color[1] * layer.brightness, layer.color[2] * layer.brightness, layer.alpha);
          if (mode === 1) { gl.enable(gl.BLEND); gl.blendFunc(gl.DST_COLOR, gl.ZERO); }
          else if (mode === 2) { gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_COLOR); }
          else if (mode === 3) { gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE); }
          else if (layer.blending === 0) { gl.disable(gl.BLEND); }
          else if (layer.blending === 2) { gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE); }
          else { gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA); }
          gl.bindTexture(gl.TEXTURE_2D, entry.texture);
          gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        }
        status.drawn += 1;
        status.parallax = [dx, dy];
        dirty = false;
      };

      let previous = performance.now(), started = false;
      const tick = (now) => {
        requestAnimationFrame(tick);
        advance(Math.min(0.1, Math.max(0, (now - previous) / 1000)));
        previous = now;
      };
      const advance = (dt) => {
        // Videos start with the first frame the wallpaper is allowed to draw; a paused wallpaper keeps them stopped.
        if (!started) { started = true; for (const entry of videos) { const r = entry.video.play(); if (r && r.catch) r.catch(() => {}); } }
        const p = scene.parallax;
        if (p.enabled && (Math.abs(target[0] - smooth[0]) > 1e-4 || Math.abs(target[1] - smooth[1]) > 1e-4)) {
          const f = p.delay > 0 ? 1 - Math.exp(-dt / p.delay) : 1;
          smooth = [smooth[0] + (target[0] - smooth[0]) * f, smooth[1] + (target[1] - smooth[1]) * f];
          dirty = true;
        }
        uploadVideos();
        if (dirty || layoutDirty) draw();
      };
      addEventListener('resize', () => { layoutDirty = true; dirty = true; });

      (async () => {
        try {
          scene = await (await fetch('scene.json')).json();
          layers = scene.layers;
          textures = await Promise.all(scene.textures.map((info, i) =>
            loadTexture(info).catch((error) => { status.failed.push(info.url + ': ' + error.message); return { ok: false }; })));
          uploadVideos();
          draw();
          requestAnimationFrame(tick);
          post({ type: 'ready' });
        } catch (error) { fail(error && error.message || error); }
      })();
    })();
    </script></body></html>
    """
}
