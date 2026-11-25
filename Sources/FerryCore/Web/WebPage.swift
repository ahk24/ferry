import Foundation

/// The page the phone sees. Self-contained: no external scripts, styles or fonts, because the
/// phone may be on its own hotspot with no internet.
enum WebPage {
    static func html(macName: String) -> String {
        let escaped = macName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return template.replacingOccurrences(of: "{{MAC}}", with: escaped)
    }

    static let locked = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="light dark"><title>Ferry</title>
    <style>body{font:17px/1.45 -apple-system,system-ui,Roboto,sans-serif;margin:0;padding:32px 20px;text-align:center}</style>
    </head><body><h1>Ferry</h1><p>This link has expired. Scan the code shown in Ferry on your Mac again.</p></body></html>
    """

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Ferry</title>
    <style>
      :root { --bg:#f2f2f7; --card:#fff; --text:#1c1c1e; --muted:#6c6c70; --accent:#1868db; --ok:#1f8a3a; --bad:#c62828; --line:#e3e3e8; }
      @media (prefers-color-scheme: dark) {
        :root { --bg:#000; --card:#1c1c1e; --text:#f2f2f7; --muted:#9a9aa0; --accent:#4a90ff; --ok:#4cc46a; --bad:#ff6b6b; --line:#2c2c2e; }
      }
      * { box-sizing:border-box; }
      body { margin:0; background:var(--bg); color:var(--text); font:16px/1.4 -apple-system,system-ui,Roboto,"Segoe UI",sans-serif; }
      main { max-width:560px; margin:0 auto; padding:20px 16px 40px; }
      h1 { font-size:28px; margin:8px 0 2px; }
      h2 { font-size:19px; margin:0; }
      .sub { color:var(--muted); margin:0 0 18px; }
      .card { background:var(--card); border-radius:16px; padding:18px; margin-bottom:16px; }
      .hint { color:var(--muted); font-size:14px; margin:6px 0 14px; }
      .row { display:flex; align-items:center; justify-content:space-between; gap:12px; }
      .btn { display:inline-block; border:0; border-radius:12px; padding:12px 18px; font:inherit; font-weight:600;
             background:var(--line); color:var(--text); text-decoration:none; text-align:center; cursor:pointer; }
      .btn.primary { background:var(--accent); color:#fff; width:100%; padding:16px; font-size:17px; }
      .btn.small { padding:8px 14px; font-size:15px; white-space:nowrap; }
      .list { list-style:none; margin:12px 0 0; padding:0; }
      .list li { display:flex; align-items:center; gap:12px; padding:12px 0; border-top:1px solid var(--line); }
      .name { flex:1; min-width:0; overflow-wrap:anywhere; }
      .name small { display:block; color:var(--muted); font-size:13px; margin-top:2px; }
      progress { width:100%; height:6px; margin-top:6px; accent-color:var(--accent); }
      .state { font-size:14px; color:var(--muted); white-space:nowrap; }
      .ok { color:var(--ok); } .bad { color:var(--bad); white-space:normal; }
      .status { color:var(--bad); text-align:center; font-size:14px; }
    </style>
    </head>
    <body>
    <main>
      <h1>Ferry</h1>
      <p class="sub">Connected to <b>{{MAC}}</b></p>

      <section class="card">
        <h2>Send to the Mac</h2>
        <p class="hint">Any kind of file. They're saved to the Mac's Downloads folder.</p>
        <label class="btn primary" for="pick" id="pickLabel">Choose files</label>
        <button class="btn" id="cancelUp" hidden style="width:100%;margin-top:10px">Cancel sending</button>
        <input id="pick" type="file" multiple hidden>
        <ul id="uploads" class="list"></ul>
      </section>

      <section class="card">
        <div class="row"><h2>From the Mac</h2><button id="all" class="btn small" hidden>Download all</button></div>
        <p id="empty" class="hint">Nothing shared yet. On the Mac, drop files onto Ferry's menu bar icon and choose "Phone's browser". They'll appear here.</p>
        <ul id="files" class="list"></ul>
      </section>

      <p id="status" class="status"></p>
    </main>
    <script>
    const K = new URLSearchParams(location.search).get('k');
    const $ = id => document.getElementById(id);
    const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const size = n => { const u = ['B','KB','MB','GB','TB']; let i = 0; while (n >= 1000 && i < 4) { n /= 1000; i++; } return (i ? n.toFixed(1) : n) + ' ' + u[i]; };
    const rid = () => Math.random().toString(36).slice(2);
    let files = [], shown = '';
    let currentXHR = null, uploadsCancelled = false;
    $('cancelUp').onclick = () => { uploadsCancelled = true; if (currentXHR) currentXHR.abort(); };

    async function refresh() {
      try {
        const r = await fetch('/api/state?k=' + K, { cache: 'no-store' });
        if (!r.ok) throw new Error();
        const s = await r.json();
        $('status').textContent = '';
        const key = JSON.stringify(s.files);
        if (key === shown) return;
        shown = key; files = s.files;
        $('empty').hidden = files.length > 0;
        $('all').hidden = files.length < 2;
        $('files').innerHTML = files.map(f =>
          `<li><div class="name">${esc(f.name)}<small>${f.folder ? esc(f.folder) + ' · ' : ''}${size(f.size)}</small></div>` +
          `<a class="btn small" href="/api/file/${f.id}?k=${K}" download="${esc(f.name)}">Download</a></li>`).join('');
      } catch (e) {
        $('status').textContent = "Can't reach the Mac. Check it's still connected to this phone's hotspot (or the same Wi-Fi) and Ferry is running.";
      }
    }

    $('all').onclick = async () => {
      const batch = rid(), total = files.reduce((a, f) => a + f.size, 0);
      for (const f of files) {
        const a = document.createElement('a');
        a.href = `/api/file/${f.id}?k=${K}&batch=${batch}&total=${total}`;
        a.download = f.name;
        document.body.appendChild(a); a.click(); a.remove();
        await new Promise(r => setTimeout(r, 800));
      }
    };

    $('pick').onchange = async ev => {
      const picked = [...ev.target.files];
      ev.target.value = '';
      if (!picked.length) return;
      const batch = rid(), total = picked.reduce((a, f) => a + f.size, 0);
      const rows = picked.map(f => {
        const li = document.createElement('li');
        li.innerHTML = `<div class="name">${esc(f.name)}<small>${size(f.size)}</small><progress max="1" value="0"></progress></div><span class="state">Waiting</span>`;
        $('uploads').prepend(li);
        return li;
      });
      uploadsCancelled = false;
      $('cancelUp').hidden = false;
      for (let i = 0; i < picked.length; i++) {
        const f = picked[i], bar = rows[i].querySelector('progress'), st = rows[i].querySelector('.state');
        if (uploadsCancelled) { st.textContent = 'Canceled'; st.className = 'state bad'; continue; }
        st.textContent = 'Sending';
        try {
          await new Promise((resolve, reject) => {
            const x = new XMLHttpRequest();
            currentXHR = x;
            x.open('PUT', `/api/upload?k=${K}&name=${encodeURIComponent(f.name)}&batch=${batch}&total=${total}`);
            x.upload.onprogress = e => { if (e.lengthComputable) bar.value = e.loaded / e.total; };
            x.onload = () => x.status === 200 ? resolve() : reject(new Error(x.responseText || ('Error ' + x.status)));
            x.onerror = () => reject(new Error(uploadsCancelled ? 'Canceled' : 'Connection lost (canceled on the Mac?)'));
            x.onabort = () => reject(new Error('Canceled'));
            x.send(f);
          });
          bar.value = 1; st.textContent = 'Sent ✓'; st.className = 'state ok';
        } catch (e) {
          st.textContent = e.message; st.className = 'state bad';
          if (/Canceled/.test(e.message)) uploadsCancelled = true;
        }
      }
      currentXHR = null;
      $('cancelUp').hidden = true;
    };

    refresh();
    setInterval(refresh, 2000);
    </script>
    </body>
    </html>
    """#
}
