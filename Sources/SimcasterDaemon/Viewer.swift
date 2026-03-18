import Foundation
import Hummingbird

func viewerHTML(sessionId: String, deviceName: String) -> String {
    let safeName = htmlEscape(deviceName)
    let safeId = jsEscape(sessionId)
    return """
    <!DOCTYPE html>
    <html>
    <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <title>Simcaster - \(safeName)</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { height: 100%; overflow: hidden; background: #111; }
            body {
                display: flex; flex-direction: column;
                font-family: -apple-system, system-ui, sans-serif; color: #fff;
                padding-top: env(safe-area-inset-top);
                padding-bottom: env(safe-area-inset-bottom);
            }
            .header {
                padding: 8px 16px; display: flex; justify-content: space-between; align-items: center;
                background: #1a1a1a; flex-shrink: 0; min-height: 40px;
            }
            .header h1 { font-size: 14px; font-weight: 500; opacity: 0.9; }
            .status { font-size: 11px; padding: 2px 8px; border-radius: 10px; }
            .status.ok { background: #1a3a1a; color: #6f6; }
            .status.err { background: #3a1a1a; color: #f66; }
            .status.wait { background: #3a3a1a; color: #ff6; }
            .viewer {
                flex: 1; display: flex; align-items: center; justify-content: center;
                overflow: hidden; position: relative;
            }
            #frame {
                max-height: 100%; max-width: 100%;
                object-fit: contain;
                user-select: none; -webkit-user-select: none;
                -webkit-user-drag: none; touch-action: none;
                -webkit-touch-callout: none;
                display: none;
            }
            #frame.loaded { display: block; }
            .loading {
                display: flex; flex-direction: column; align-items: center;
                justify-content: center; gap: 16px; color: #888;
            }
            .loading.hidden { display: none; }
            .spinner {
                width: 32px; height: 32px; border: 3px solid #333;
                border-top-color: #888; border-radius: 50%;
                animation: spin 0.8s linear infinite;
            }
            @keyframes spin { to { transform: rotate(360deg); } }
            .bar {
                display: flex; align-items: center; justify-content: center; gap: 16px;
                padding: 10px 16px; background: #1a1a1a; flex-shrink: 0;
            }
            .bar button {
                background: none; border: 1px solid #444; color: #ccc;
                padding: 8px 20px; border-radius: 20px; font-size: 13px;
                -webkit-tap-highlight-color: transparent; cursor: pointer;
            }
            .bar button:active { background: #333; }
            .kb-bar {
                display: flex; gap: 8px; padding: 8px 16px; background: #1a1a1a; flex-shrink: 0;
            }
            .kb-bar input {
                flex: 1; background: #333; border: 1px solid #555; color: #fff;
                padding: 8px 12px; border-radius: 8px; font-size: 14px; outline: none;
            }
            .kb-bar button {
                background: #2563eb; border: none; color: #fff;
                padding: 8px 16px; border-radius: 8px; font-size: 13px;
                -webkit-tap-highlight-color: transparent;
            }
            .fps { font-size: 10px; color: #555; position: absolute; bottom: 2px; right: 8px; }
        </style>
    </head>
    <body>
        <div class="header">
            <h1>\(safeName)</h1>
            <span class="status wait" id="status">Connecting</span>
        </div>
        <div class="viewer" id="viewer">
            <div class="loading" id="loading">
                <div class="spinner"></div>
                <div>Waiting for Simulator...</div>
            </div>
            <img id="frame" alt="" draggable="false" />
            <span class="fps" id="fps"></span>
        </div>
        <div class="bar">
            <button id="btnHome">Home</button>
            <button id="btnLock">Lock</button>
            <button id="btnShake">Shake</button>
            <button id="btnKb">Keyboard</button>
        </div>
        <div class="kb-bar" id="kbBar" style="display:none;">
            <input type="text" id="kbInput" placeholder="Tap here to type..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" />
        </div>
        <script>
        (function() {
            const S = "\(safeId)";
            const T = new URLSearchParams(location.search).get('token') || '';
            const Q = T ? '?token=' + T : '';
            const img = document.getElementById('frame');
            const statusEl = document.getElementById('status');
            const fpsEl = document.getElementById('fps');
            const loadingEl = document.getElementById('loading');
            let fc = 0, lt = Date.now(), firstFrame = true;

            // --- Frame delivery via WebSocket ---
            function connectWs() {
                const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
                const wsUrl = proto + '//' + location.host + '/ws/sessions/' + S + '/frames' + Q;
                const ws = new WebSocket(wsUrl);
                ws.binaryType = 'blob';
                ws.onopen = () => setStatus('ok', 'Live (WS)');
                ws.onmessage = (e) => {
                    const u = URL.createObjectURL(e.data);
                    img.onload = () => { URL.revokeObjectURL(u); if (firstFrame) { firstFrame = false; img.classList.add('loaded'); loadingEl.classList.add('hidden'); } };
                    img.src = u;
                    fc++;
                    const n = Date.now();
                    if (n - lt >= 1000) { fpsEl.textContent = fc + ' fps'; fc = 0; lt = n; }
                };
                ws.onclose = () => {
                    setStatus('wait', 'Reconnecting');
                    firstFrame = true; img.classList.remove('loaded'); loadingEl.classList.remove('hidden');
                    setTimeout(connectWs, 1000);
                };
                ws.onerror = () => ws.close();
            }
            connectWs();

            function setStatus(cls, text) {
                statusEl.className = 'status ' + cls;
                statusEl.textContent = text;
            }

            // --- Gesture handling ---
            let g = null;
            const TAP_THRESH = 12;

            function gStart(cx, cy) {
                const r = img.getBoundingClientRect();
                if (cx < r.left || cx > r.right || cy < r.top || cy > r.bottom) return;
                g = { sx: cx, sy: cy, nx1: (cx - r.left) / r.width, ny1: (cy - r.top) / r.height, t: Date.now() };
            }

            function gEnd(cx, cy) {
                if (!g) return;
                const r = img.getBoundingClientRect();
                const nx2 = (cx - r.left) / r.width, ny2 = (cy - r.top) / r.height;
                const dx = cx - g.sx, dy = cy - g.sy;
                const dist = Math.sqrt(dx * dx + dy * dy);
                const dur = Date.now() - g.t;
                if (dist < TAP_THRESH) {
                    fetch('/api/sessions/' + S + '/tap' + Q, {
                        method: 'POST', headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ x: g.nx1, y: g.ny1 })
                    });
                    ripple(cx, cy);
                } else {
                    fetch('/api/sessions/' + S + '/swipe' + Q, {
                        method: 'POST', headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ x1: g.nx1, y1: g.ny1, x2: nx2, y2: ny2, duration: Math.max(dur, 150) })
                    });
                }
                g = null;
            }

            // Touch events — tap, swipe, pinch
            let pinch = null;
            function touchDist(e) {
                const a = e.touches[0], b = e.touches[1];
                return Math.sqrt((a.clientX-b.clientX)**2 + (a.clientY-b.clientY)**2);
            }

            img.addEventListener('touchstart', (e) => {
                e.preventDefault();
                if (e.touches.length === 2) {
                    g = null;
                    const r = img.getBoundingClientRect();
                    const cx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                    const cy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                    pinch = {
                        startDist: touchDist(e),
                        nx: (cx - r.left) / r.width,
                        ny: (cy - r.top) / r.height,
                        time: Date.now()
                    };
                } else if (e.touches.length === 1) {
                    pinch = null;
                    const t = e.touches[0];
                    gStart(t.clientX, t.clientY);
                }
            }, { passive: false });

            img.addEventListener('touchend', (e) => {
                e.preventDefault();
                if (pinch && e.touches.length < 2) {
                    pinch = null;
                    return;
                }
                if (g && e.touches.length === 0) {
                    const t = e.changedTouches[0];
                    gEnd(t.clientX, t.clientY);
                }
            }, { passive: false });

            let lastPinchSend = 0;
            img.addEventListener('touchmove', (e) => {
                e.preventDefault();
                if (pinch && e.touches.length === 2) {
                    const now = Date.now();
                    if (now - lastPinchSend < 100) return;
                    lastPinchSend = now;
                    const curDist = touchDist(e);
                    const scale = curDist / pinch.startDist;
                    fetch('/api/sessions/' + S + '/pinch' + Q, {
                        method: 'POST', headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ x: pinch.nx, y: pinch.ny, scale: scale, duration: 200 })
                    });
                }
            }, { passive: false });

            // Mouse fallback
            img.addEventListener('mousedown', (e) => { e.preventDefault(); gStart(e.clientX, e.clientY); });
            document.addEventListener('mouseup', (e) => { if (g) { e.preventDefault(); gEnd(e.clientX, e.clientY); } });
            img.addEventListener('dragstart', (e) => e.preventDefault());

            function ripple(cx, cy) {
                const d = document.createElement('div');
                d.style.cssText = 'position:fixed;left:'+(cx-12)+'px;top:'+(cy-12)+'px;width:24px;height:24px;border:2px solid rgba(255,255,255,0.7);border-radius:50%;pointer-events:none;z-index:99;animation:rip .4s ease-out forwards;';
                document.body.appendChild(d);
                setTimeout(() => d.remove(), 400);
            }

            // Hardware buttons
            function sendButton(btn) {
                fetch('/api/sessions/' + S + '/button' + Q, {
                    method: 'POST', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({ button: btn })
                });
            }
            document.getElementById('btnHome').addEventListener('click', () => sendButton('home'));
            document.getElementById('btnLock').addEventListener('click', () => sendButton('lock'));
            document.getElementById('btnShake').addEventListener('click', () => sendButton('shake'));

            // Keyboard — debounced live typing
            const kbBar = document.getElementById('kbBar');
            const kbInput = document.getElementById('kbInput');
            let prevVal = '';
            let kbTimer = null;
            document.getElementById('btnKb').addEventListener('click', () => {
                const show = kbBar.style.display === 'none';
                kbBar.style.display = show ? 'flex' : 'none';
                if (show) { kbInput.value = ''; prevVal = ''; kbInput.focus(); }
            });
            function flushKeys() {
                kbTimer = null;
                const val = kbInput.value;
                if (val === prevVal) return;
                if (val.length > prevVal.length && val.startsWith(prevVal)) {
                    const added = val.slice(prevVal.length);
                    fetch('/api/sessions/' + S + '/key' + Q, {
                        method: 'POST', headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ chars: added })
                    });
                } else if (val.length < prevVal.length && prevVal.startsWith(val)) {
                    fetch('/api/sessions/' + S + '/key' + Q, {
                        method: 'POST', headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ backspaces: prevVal.length - val.length })
                    });
                } else {
                    if (prevVal.length > 0) {
                        fetch('/api/sessions/' + S + '/key' + Q, {
                            method: 'POST', headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ backspaces: prevVal.length })
                        });
                    }
                    if (val.length > 0) {
                        setTimeout(() => {
                            fetch('/api/sessions/' + S + '/key' + Q, {
                                method: 'POST', headers: {'Content-Type': 'application/json'},
                                body: JSON.stringify({ chars: val })
                            });
                        }, 100);
                    }
                }
                prevVal = val;
            }
            kbInput.addEventListener('input', () => {
                if (kbTimer) clearTimeout(kbTimer);
                kbTimer = setTimeout(flushKeys, 120);
            });
            kbInput.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') {
                    if (kbTimer) { clearTimeout(kbTimer); flushKeys(); }
                    setTimeout(() => {
                        fetch('/api/sessions/' + S + '/key' + Q, {
                            method: 'POST', headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ enter: true })
                        });
                    }, 150);
                    kbInput.value = ''; prevVal = '';
                }
            });
        })();
        </script>
        <style>
            @keyframes rip { 0% { transform: scale(0.5); opacity: 1; } 100% { transform: scale(2); opacity: 0; } }
        </style>
    </body>
    </html>
    """
}
