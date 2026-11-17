// sttSheet.jsx — Speech-to-Text model chooser sheet (3 directions) + shared state hook.
// Mirrors ManageModelsSheet (AI Language Model) chrome: headline, metadata copy, chip rows, Done.

if (!document.getElementById('stt-styles')) {
  const s = document.createElement('style'); s.id = 'stt-styles';
  s.textContent = `
  .stt-scope{--paper:#FBFAF5;--ink:#1A1813;--ink2:rgba(26,24,19,.56);--ink3:rgba(26,24,19,.36);--sage:#4E7D5C;
    --sage-wash:rgba(78,125,92,.14);--sep:rgba(26,24,19,.11);--chip:rgba(26,24,19,.06);--warn:#8A5A0B;--warn-fill:rgba(232,161,58,.2);
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;color:var(--ink);-webkit-font-smoothing:antialiased;letter-spacing:-.003em}
  .stt-scope a{color:var(--sage);text-decoration:none}.stt-scope a:hover{text-decoration:underline}
  .stt-stage{position:relative;width:100%;height:100%;background:radial-gradient(130% 110% at 0% 0%,#E9E7E0,#E4E1D8 55%,#DCD9CF);display:flex;align-items:flex-start;justify-content:center;padding-top:40px;box-sizing:border-box}
  .stt-sheetwrap{position:relative}
  .stt-sheet{background:#fff;border-radius:14px;box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 22px 60px rgba(40,28,12,.26),0 6px 16px rgba(40,28,12,.12);padding:24px;box-sizing:border-box;display:flex;flex-direction:column;gap:16px;text-align:left}
  .stt-h{font-size:13px;font-weight:700;margin:0}
  .stt-meta{font-size:12px;color:var(--ink2);line-height:1.4;margin:0;text-wrap:pretty}
  .stt-mono{font-family:"IBM Plex Mono",ui-monospace,monospace;font-variant-numeric:tabular-nums}
  .stt-rows{display:flex;flex-direction:column;gap:8px}
  .stt-row{background:rgba(26,24,19,.035);border-radius:8px;padding:8px;display:flex;flex-direction:column;gap:4px}
  .stt-name{font-size:13px;font-weight:500}
  .stt-line{display:flex;align-items:center;gap:8px}
  .stt-sp{flex:1}
  .stt-btn{display:inline-flex;align-items:center;justify-content:center;height:20px;padding:0 9px;border-radius:5px;border:0;background:#fff;font:inherit;font-size:11.5px;font-weight:500;color:var(--ink);box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 .5px 1px rgba(0,0,0,.1);cursor:pointer;white-space:nowrap}
  .stt-btn:active{background:#EFEDE7}
  .stt-btn.reg{height:24px;padding:0 14px;font-size:13px;border-radius:6px}
  .stt-badge{display:inline-flex;align-items:center;gap:4px;height:19px;padding:0 8px;border-radius:10px;background:rgba(78,125,92,.15);color:var(--sage);font-size:11px;font-weight:500;white-space:nowrap}
  .stt-default{display:inline-flex;align-items:center;gap:4px;font-size:12px;color:var(--ink2);white-space:nowrap}
  .stt-warn{display:inline-flex;align-items:center;gap:4px;height:19px;padding:0 8px;border-radius:10px;background:var(--warn-fill);color:var(--warn);font-size:11px;font-weight:500;white-space:nowrap}
  .stt-bar{height:4px;border-radius:2px;background:rgba(26,24,19,.1);overflow:hidden}.stt-bar i{display:block;height:100%;background:var(--sage);border-radius:2px;transition:width .2s}
  .stt-dim{opacity:.5}
  /* B · highlights */
  .stt-b .stt-row{padding:12px 12px 10px;gap:9px}
  .stt-b .stt-name{font-size:13.5px;font-weight:600}
  .stt-traits{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px 14px}
  .stt-trait{display:flex;align-items:center;gap:6px;font-size:12.5px;color:var(--ink);min-width:0}
  .stt-trait.con{color:var(--ink2)}
  .stt-mk{flex:0 0 auto;width:15px;height:15px;border-radius:50%;display:flex;align-items:center;justify-content:center;background:var(--sage-wash);color:var(--sage)}
  .stt-trait.con .stt-mk{background:var(--chip);color:var(--ink3)}
  .stt-link{background:none;border:0;padding:0;font:inherit;color:inherit;cursor:pointer;display:inline-flex;align-items:center;gap:2px;border-bottom:1px dotted var(--ink3)}
  .stt-ul{background:none;border:0;padding:0;font:inherit;color:var(--ink);cursor:pointer;text-decoration:underline;text-decoration-color:var(--ink3);text-underline-offset:2px}
  .stt-ul:hover{color:var(--sage);text-decoration-color:var(--sage)}
  .stt-popw{position:relative;display:inline-flex;vertical-align:middle}
  .stt-pop{display:inline-flex;align-items:center;gap:5px;height:20px;padding:0 5px 0 8px;border-radius:5px;border:0;background:#fff;font:inherit;font-size:12px;font-weight:500;color:var(--ink);box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 .5px 1px rgba(0,0,0,.1);cursor:pointer;white-space:nowrap}
  .stt-pop .cv{width:14px;height:14px;border-radius:3.5px;background:var(--sage);color:#fff;display:flex;align-items:center;justify-content:center}
  .stt-menu{position:absolute;top:calc(100% + 3px);left:0;z-index:8;min-width:150px;background:rgba(250,250,248,.98);border-radius:8px;padding:5px;box-shadow:0 0 0 .5px rgba(0,0,0,.18),0 10px 28px rgba(40,28,12,.22);display:flex;flex-direction:column}
  .stt-mi{position:relative;height:22px;display:flex;align-items:center;padding:0 12px 0 24px;border-radius:4px;font-size:13px;font-weight:400;color:var(--ink);cursor:pointer;white-space:nowrap}
  .stt-mi:hover{background:var(--sage);color:#fff}
  .stt-mi .ck{position:absolute;left:8px;top:6px}
  .stt-lcell{flex-direction:column!important;align-items:flex-start!important;gap:3px!important}
  .stt-lcap{font-size:11px;color:var(--ink3);font-weight:400}
  .stt-dtbl{display:grid;grid-template-columns:minmax(0,1.35fr) .8fr .95fr 1.15fr .8fr .9fr 108px;background:#fff;border-radius:10px;box-shadow:0 0 0 .5px rgba(26,22,14,.12),0 1px 2px rgba(0,0,0,.04)}
  .stt-dtbl>div{padding:10px 10px;border-top:.5px solid var(--sep);font-size:12.5px;display:flex;align-items:center;gap:5px;min-width:0}
  .stt-dtbl>.th:first-child{border-top-left-radius:10px}.stt-dtbl>.th:nth-child(7){border-top-right-radius:10px}
  .stt-dtbl>.th{border-top:0;font-size:11px;color:var(--ink2);padding-top:9px;padding-bottom:7px;background:rgba(26,24,19,.025);line-height:1.2}
  .stt-dtbl>.mdl{flex-direction:column;align-items:flex-start;gap:4px}
  .stt-dtbl>.win{font-weight:600}.stt-dtbl>.lose{color:var(--ink2)}
  .stt-dtbl>.act{flex-direction:column;align-items:flex-end;gap:5px;text-align:right}
  .stt-dtbl>.sel{background:rgba(78,125,92,.05)}
  .stt-langs{font-size:11.5px;color:var(--ink2);line-height:1.5;background:rgba(255,255,255,.7);border-radius:6px;padding:6px 8px;box-shadow:0 0 0 .5px var(--sep)}
  .stt-foot{display:flex;align-items:center;gap:10px;min-height:20px;border-top:.5px solid var(--sep);padding-top:8px}
  .stt-fine{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:10.5px;color:var(--ink3);letter-spacing:.02em;white-space:nowrap}
  /* C · side by side */
  .stt-tbl{display:grid;grid-template-columns:118px minmax(0,1fr) minmax(0,1fr);background:#fff;border-radius:10px;box-shadow:0 0 0 .5px rgba(26,22,14,.12),0 1px 2px rgba(0,0,0,.04)}
  .stt-tbl>div{padding:9px 12px;border-top:.5px solid var(--sep);font-size:12.5px;display:flex;align-items:center;gap:6px;min-width:0}
  .stt-tbl>.hd{border-top:0;flex-direction:column;align-items:flex-start;gap:5px;padding-top:12px}
  .stt-tbl>.lbl{color:var(--ink2);font-size:12px}
  .stt-tbl>.win{font-weight:600}
  .stt-tbl>.lose{color:var(--ink2)}
  .stt-tbl>.col2{border-left:.5px solid var(--sep)}
  .stt-tbl>.ft{padding:10px 12px 12px;flex-direction:column;align-items:flex-start;gap:6px}
  .stt-tbl .ft .stt-line{flex-direction:column;align-items:flex-start;gap:6px}
  .stt-tbl .sel{background:rgba(78,125,92,.05)}
  /* alert */
  .stt-scrim{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:5}
  .stt-alert{width:300px;background:rgba(251,250,245,.97);border-radius:18px;padding:20px 16px 16px;box-sizing:border-box;box-shadow:0 0 0 .5px rgba(0,0,0,.18),0 24px 60px rgba(40,28,12,.32);display:flex;flex-direction:column;align-items:center;text-align:center;gap:8px}
  .stt-alert img{width:56px;height:56px;margin-bottom:4px}
  .stt-alert h3{font-size:13px;font-weight:700;margin:0;text-wrap:balance}
  .stt-alert p{font-size:11.5px;line-height:1.4;color:var(--ink2);margin:0;text-wrap:pretty}
  .stt-alert .btns{display:grid;grid-template-columns:1fr 1fr;gap:8px;width:100%;margin-top:8px}
  .stt-abtn{height:28px;border-radius:14px;border:0;font:inherit;font-size:13px;font-weight:500;background:rgba(26,24,19,.08);color:var(--ink);cursor:pointer;white-space:nowrap;padding:0 8px}
  .stt-abtn.pri{background:var(--sage);color:#fff}
  `;
  document.head.appendChild(s);
}

const STT_LANGS = ['Cantonese', 'Chinese', 'English', 'French', 'German', 'Italian', 'Japanese', 'Korean', 'Portuguese', 'Spanish'];
const STT_NAMES = { apple: 'Apple Speech', whisper: 'Whisper' };
const sttTech = (s, k) => (k === 'apple' ? `SpeechTranscriber · macOS ${s.os}` : 'Whisper V3 Turbo · 635 MB');

function SttGlyph({ name, size = 10, color = 'currentColor' }) {
  const p = { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: color, strokeWidth: 2.6, strokeLinecap: 'round', strokeLinejoin: 'round', style: { display: 'block' } };
  if (name === 'check') return <svg {...p}><path d="m5 12.5 4.2 4.2L19 7" /></svg>;
  if (name === 'minus') return <svg {...p}><path d="M6.5 12h11" /></svg>;
  if (name === 'chev') return <svg {...p} strokeWidth={2.2}><path d="m9.5 6 6 6-6 6" /></svg>;
  if (name === 'chevd') return <svg {...p} strokeWidth={2.2}><path d="m6 9.5 6 6 6-6" /></svg>;
  if (name === 'star') return <svg {...p} stroke="none" fill={color}><path d="M12 3.2 14.6 9l6.2.6-4.7 4.1 1.4 6.1L12 16.6l-5.5 3.2 1.4-6.1-4.7-4.1L9.4 9Z" /></svg>;
  if (name === 'warn') return <svg {...p} stroke="none"><path d="M12 3.5 22 20.5H2Z" fill={color} /><path d="M12 10v4.5M12 17.4v.2" stroke="#fff" strokeWidth="2.2" /></svg>;
  return null;
}
const SttBadge = () => <span className="stt-badge"><SttGlyph name="star" size={10} />Recommended</span>;
const SttDefault = () => (<span className="stt-default">
  <span style={{ width: 13, height: 13, borderRadius: '50%', background: 'var(--sage)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><SttGlyph name="check" size={8} color="#fff" /></span>Default</span>);
const SttWarn = ({ children = 'Requires macOS 26 or later' }) => <span className="stt-warn"><SttGlyph name="warn" size={10} />{children}</span>;

/* ───────── state ───────── */
// s: { os, rec, selected, apple:'ready'|'none'|'downloading', whisper:'ready'|'none'|'downloading', pct:{apple,whisper}, langs, alert }
function useSttState(init) {
  const [s, setS] = React.useState(() => ({ os: 26, rec: 'apple', selected: null, apple: 'ready', whisper: 'none', pct: { apple: 0, whisper: 0 }, lang: 'English', picker: false, alert: false, live: {}, ...init }));
  React.useEffect(() => {
    const live = Object.keys(s.live).filter((k) => s.live[k] && s[k] === 'downloading');
    if (!live.length) return;
    const t = setInterval(() => setS((p) => {
      const n = { ...p, pct: { ...p.pct } };
      live.forEach((k) => {
        n.pct[k] = Math.min(100, p.pct[k] + (k === 'apple' ? 9 : 4));
        if (n.pct[k] >= 100) { n[k] = 'ready'; n.live = { ...p.live, [k]: false }; if (!p.selected || p.selected === k || !isReady(p, p.selected)) n.selected = k; }
      });
      return n;
    }), 220);
    return () => clearInterval(t);
  }, [s.live, s.apple, s.whisper]);
  const act = {
    download: (k) => setS((p) => ({ ...p, [k]: 'downloading', pct: { ...p.pct, [k]: p.pct[k] || 0 }, live: { ...p.live, [k]: true }, selected: k })),
    choose: (k) => setS((p) => ({ ...p, selected: k })),
    del: (k) => setS((p) => ({ ...p, [k]: 'none', pct: { ...p.pct, [k]: 0 }, selected: p.selected === k ? 'apple' : p.selected })),
    picker: (v) => setS((p) => ({ ...p, picker: v })),
    setLang: (v) => setS((p) => ({ ...p, lang: v, picker: false })),
    alert: (v) => setS((p) => ({ ...p, alert: v })),
  };
  return [s, act];
}
const isReady = (s, k) => s[k] === 'ready' && (k !== 'apple' || s.os >= 26);
const sttTarget = (s) => s.selected || s.rec;
const appleOK = (s) => s.os >= 26;

/* ───────── shared bits ───────── */
function SttSelect({ s, k, act }) {
  if (k === 'apple' && !appleOK(s)) return null;
  if (s[k] !== 'ready') return null;
  return sttTarget(s) === k ? <SttDefault /> : <button className="stt-btn" onClick={() => act.choose(k)}>Choose Model</button>;
}
function SttProgress({ pct, width = 120 }) {
  return (<div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
    <div className="stt-bar" style={{ width }}><i style={{ width: `${pct}%` }} /></div>
    <span className="stt-mono" style={{ fontSize: 11, color: 'var(--ink2)' }}>{pct}%</span>
  </div>);
}
function SttAction({ s, k, act }) {
  if (k === 'apple' && !appleOK(s)) return null;
  if (s[k] === 'downloading') return <SttProgress pct={s.pct[k]} />;
  if (s[k] === 'none') return <button className="stt-btn" onClick={() => act.download(k)}>Download</button>;
  if (k === 'whisper') return <button className="stt-btn" onClick={() => act.del(k)}>Delete</button>;
  return null;
}
function SttAlert({ act }) {
  return (<div className="stt-scrim"><div className="stt-alert">
    <img src="Biscotti Design System/brand/app-icon.png" alt="" />
    <h3>Apple Speech requires macOS 26</h3>
    <p>This Mac is running macOS 15. Update macOS to use Apple’s built-in speech model. Whisper works on this Mac today.</p>
    <div className="btns"><button className="stt-abtn" onClick={() => act.alert(false)}>Not Now</button><button className="stt-abtn pri" onClick={() => act.alert(false)}>Software Update…</button></div>
  </div></div>);
}
function SttUnavailable({ act }) {
  return (<div className="stt-line"><SttWarn /><a href="#" onClick={(e) => { e.preventDefault(); act.alert(true); }} style={{ fontSize: 12 }}>Learn more…</a></div>);
}

function SttLangPop({ s, act }) {
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (!s.picker) return;
    const h = (e) => { if (ref.current && !ref.current.contains(e.target)) act.picker(false); };
    document.addEventListener('mousedown', h); return () => document.removeEventListener('mousedown', h);
  }, [s.picker]);
  return (<span className="stt-popw" ref={ref}>
    <button className="stt-pop" onClick={() => act.picker(!s.picker)}>{s.lang}<span className="cv"><svg width="8" height="10" viewBox="0 0 8 10" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M1.5 3.8 4 1.5l2.5 2.3M1.5 6.2 4 8.5l2.5-2.3" /></svg></span></button>
    {s.picker && <div className="stt-menu">{STT_LANGS.map((l) => (
      <div key={l} className="stt-mi" onClick={() => act.setLang(l)}>{l === s.lang && <span className="ck"><SttGlyph name="check" size={10} /></span>}{l}</div>))}</div>}
  </span>);
}
function SttLang({ s, act, prefix = '1 language ' }) {
  return <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>{prefix}<SttLangPop s={s} act={act} /></span>;
}

/* ───────── A · Familiar (ManageModelsSheet verbatim pattern) ───────── */
function SttRowsA({ s, act }) {
  const descA = <React.Fragment>{s.apple === 'ready' ? 'Fast and built into macOS, no download needed. ' : 'Fast and built into macOS. '}Transcribes 1 language: <SttLangPop s={s} act={act} /> No custom vocabulary.</React.Fragment>;
  const descW = 'Better with technical jargon and uncommon words, and supports custom vocabulary. Transcribes any of 99 languages, but about 5× slower. Requires 635 MB of disk.';
  const row = (k, name, desc) => {
    const off = k === 'apple' && !appleOK(s);
    return (<div className="stt-row" key={k}>
      <div className={off ? 'stt-dim' : ''} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        {s.rec === k && <div><SttBadge /></div>}<div className="stt-line"><span className="stt-name">{name}</span><span className="stt-sp" /><SttSelect s={s} k={k} act={act} /></div>
        <div className="stt-line" style={{ alignItems: 'flex-start' }}>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4 }}><p className="stt-meta">{desc}</p><span className="stt-fine">{sttTech(s, k)}</span></div>
          <SttAction s={s} k={k} act={act} />
        </div>
      </div>
      {off && <SttUnavailable act={act} />}
    </div>);
  };
  return <div className="stt-rows">{row('apple', 'Apple Speech', descA)}{row('whisper', 'Whisper', descW)}</div>;
}

/* ───────── B · Highlights (pros / tradeoff, aligned) ───────── */
function SttTrait({ con, children }) {
  return <div className={'stt-trait' + (con ? ' con' : '')}><span className="stt-mk"><SttGlyph name={con ? 'minus' : 'check'} size={9} /></span><span style={{ minWidth: 0 }}>{children}</span></div>;
}
function SttRowsB({ s, act }) {
  const off = !appleOK(s);
  return (<div className="stt-rows">
    <div className="stt-row">
      <div className={off ? 'stt-dim' : ''} style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        {s.rec === 'apple' && <div style={{ marginBottom: -4 }}><SttBadge /></div>}<div className="stt-line"><span className="stt-name">Apple Speech</span><span className="stt-sp" /><SttSelect s={s} k="apple" act={act} /></div>
        <div className="stt-traits">
          <SttTrait>5× faster</SttTrait>
          <SttTrait>{s.apple === 'ready' ? 'Built in, no download' : 'Built into macOS'}</SttTrait>
          <SttTrait con><SttLang s={s} act={act} /></SttTrait>
          <SttTrait con>No custom vocabulary</SttTrait>
        </div>
      </div>
      <div className="stt-foot">
        {off ? <SttUnavailable act={act} /> : <span className="stt-fine">SpeechTranscriber · macOS {s.os}{s.apple === 'none' ? ' · system download' : ''}</span>}
        <span className="stt-sp" /><SttAction s={s} k="apple" act={act} />
      </div>
    </div>
    <div className="stt-row">
      {s.rec === 'whisper' && <div style={{ marginBottom: -4 }}><SttBadge /></div>}<div className="stt-line"><span className="stt-name">Whisper</span><span className="stt-sp" /><SttSelect s={s} k="whisper" act={act} /></div>
      <div className="stt-traits">
        <SttTrait>Better with jargon &amp; rare words</SttTrait>
        <SttTrait>Any of 99 languages</SttTrait>
        <SttTrait>Custom vocabulary</SttTrait>
        <SttTrait con>5× slower</SttTrait>
      </div>
      <div className="stt-foot"><span className="stt-fine">Whisper V3 Turbo · 635 MB</span><span className="stt-sp" /><SttAction s={s} k="whisper" act={act} /></div>
    </div>
  </div>);
}

/* ───────── C · Side by side ───────── */
function SttTableC({ s, act }) {
  const off = !appleOK(s);
  const sel = (k) => (isReady(s, k) && sttTarget(s) === k ? ' sel' : '');
  const a = (cls) => cls + (off ? ' stt-dim' : '') + sel('apple');
  const w = (cls) => cls + ' col2' + sel('whisper');
  const Win = ({ children }) => <React.Fragment><span className="stt-mk" style={{ width: 14, height: 14 }}><SttGlyph name="check" size={8} /></span>{children}</React.Fragment>;
  const head = (k, name) => <React.Fragment>{s.rec === k ? <SttBadge /> : <span style={{ height: 19 }} />}<span className="stt-name" style={{ fontWeight: 600 }}>{name}</span><span className="stt-fine">{sttTech(s, k)}</span></React.Fragment>;
  const foot = (k) => (<React.Fragment>
    {k === 'apple' && off ? <SttUnavailable act={act} /> : <React.Fragment>
      <SttSelect s={s} k={k} act={act} /><SttAction s={s} k={k} act={act} />
    </React.Fragment>}
  </React.Fragment>);
  return (<div>
    <div className="stt-tbl">
      <div className="hd lbl" /><div className={a('hd')}>{head('apple', 'Apple Speech')}</div><div className={w('hd')}>{head('whisper', 'Whisper')}</div>
      <div className="lbl">Speed</div><div className={a('win')}><Win>5× faster</Win></div><div className={w('lose')}>Slower</div>
      <div className="lbl">Download</div><div className={a(s.apple === 'ready' ? 'win' : 'lose')}>{s.apple === 'ready' ? <Win>None, built in</Win> : 'System download'}</div><div className={w('lose')}>635 MB</div>
      <div className="lbl">Languages</div><div className={a('lose stt-lcell')}><SttLangPop s={s} act={act} /><span className="stt-lcap">1 language only</span></div><div className={w('win')}><Win>Any of 99</Win></div>
      <div className="lbl">Jargon &amp; rare words</div><div className={a('lose')}>Good</div><div className={w('win')}><Win>Better</Win></div>
      <div className="lbl">Custom vocabulary</div><div className={a('lose')}>Not supported</div><div className={w('win')}><Win>Supported</Win></div>
      <div className="lbl" /><div className={a('ft').replace(' stt-dim', '')}>{foot('apple')}</div><div className={w('ft')}>{foot('whisper')}</div>
    </div>
  </div>);
}

/* ───────── D · Table (one row per model, one column per attribute) ───────── */
function SttTableD({ s, act }) {
  const off = !appleOK(s);
  const sel = (k) => (isReady(s, k) && sttTarget(s) === k ? ' sel' : '');
  const A = (cls) => cls + (off ? ' stt-dim' : '') + sel('apple');
  const Wc = (cls) => cls + sel('whisper');
  const Win = ({ children }) => <React.Fragment><span className="stt-mk" style={{ width: 14, height: 14 }}><SttGlyph name="check" size={8} /></span>{children}</React.Fragment>;
  const act_ = (k) => (k === 'apple' && off
    ? <React.Fragment><SttWarn>Needs macOS 26</SttWarn><a href="#" onClick={(e) => { e.preventDefault(); act.alert(true); }} style={{ fontSize: 12 }}>Learn more…</a></React.Fragment>
    : <React.Fragment><SttSelect s={s} k={k} act={act} />{s[k] === 'downloading' ? <SttProgress pct={s.pct[k]} width={56} /> : <SttAction s={s} k={k} act={act} />}</React.Fragment>);
  return (<div className="stt-dtbl">
    <div className="th">Model</div><div className="th">Speed</div><div className="th">Download</div><div className="th">Languages</div><div className="th">Jargon &amp; rare words</div><div className="th">Custom vocabulary</div><div className="th" />
    <div className={A('mdl')}>{s.rec === 'apple' && <SttBadge />}<span className="stt-name" style={{ fontWeight: 600 }}>Apple Speech</span><span className="stt-fine" style={{ whiteSpace: 'normal' }}>SpeechTranscriber</span></div>
    <div className={A('win')}><Win>5× faster</Win></div>
    <div className={A(s.apple === 'ready' ? 'win' : 'lose')}>{s.apple === 'ready' ? <Win>Built in</Win> : 'System'}</div>
    <div className={A('lose stt-lcell')}><SttLangPop s={s} act={act} /><span className="stt-lcap">1 language only</span></div>
    <div className={A('lose')}>Good</div>
    <div className={A('lose')}>No</div>
    <div className={'act' + sel('apple')}>{act_('apple')}</div>
    <div className={Wc('mdl')}>{s.rec === 'whisper' && <SttBadge />}<span className="stt-name" style={{ fontWeight: 600 }}>Whisper</span><span className="stt-fine" style={{ whiteSpace: 'normal' }}>Whisper V3 Turbo</span></div>
    <div className={Wc('lose')}>Slower</div>
    <div className={Wc('lose')}>635 MB</div>
    <div className={Wc('win')}><Win>Any of 99</Win></div>
    <div className={Wc('win')}><Win>Better</Win></div>
    <div className={Wc('win')}><Win>Yes</Win></div>
    <div className={'act' + sel('whisper')}>{act_('whisper')}</div>
  </div>);
}

/* ───────── the sheet ───────── */
function SttSheet({ variant = 'b', s, act, onDone }) {
  const width = { a: 480, b: 520, c: 540, d: 720 }[variant];
  return (<div className="stt-sheetwrap">
    <div className={'stt-sheet stt-' + variant} style={{ width }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <h2 className="stt-h">Speech to Text Model</h2>
        <p className="stt-meta">Choose the model used to transcribe your meetings. Both run entirely on your Mac.</p>
      </div>
      {variant === 'a' && <SttRowsA s={s} act={act} />}
      {variant === 'b' && <SttRowsB s={s} act={act} />}
      {variant === 'c' && <SttTableC s={s} act={act} />}
      {variant === 'd' && <SttTableD s={s} act={act} />}
      <div style={{ display: 'flex', justifyContent: 'flex-end' }}><button className="stt-btn reg" onClick={onDone}>Done</button></div>
    </div>
    {s.alert && <SttAlert act={act} />}
  </div>);
}

// Standalone artboard: sheet on the wall backdrop.
function SttSheetDemo({ variant = 'b', init }) {
  const [s, act] = useSttState(init);
  return (<div className="stt-scope" style={{ height: '100%' }}><div className="stt-stage"><SttSheet variant={variant} s={s} act={act} onDone={() => {}} /></div></div>);
}

Object.assign(window, { useSttState, SttSheet, SttSheetDemo, SttGlyph, SttProgress, sttTarget, appleOK, isReady, STT_NAMES });
