// sttScreens.jsx — Onboarding "Download Local AI Models" step + Settings row, wired to the STT sheet.

if (!document.getElementById('stt-scr-styles')) {
  const s = document.createElement('style'); s.id = 'stt-scr-styles';
  s.textContent = `
  .sto-win{position:relative;width:100%;height:100%;border-radius:12px;overflow:hidden;background:#FAF9F5;box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 24px 60px rgba(40,28,12,.18);display:flex;flex-direction:column}
  .sto-tb{height:28px;flex:0 0 auto;background:#F4F3EF;border-bottom:.5px solid rgba(0,0,0,.1);display:flex;align-items:center;gap:8px;padding-left:14px}
  .sto-tb i{width:12px;height:12px;border-radius:50%;display:block;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.14)}
  .sto-body{flex:1;display:flex;flex-direction:column;align-items:center;padding:28px 0 28px;min-height:0}
  .sto-main{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}
  .sto-kick{font-family:"IBM Plex Mono",monospace;font-size:11px;font-weight:500;letter-spacing:.17em;color:var(--ink2);text-transform:uppercase}
  .sto-title{font-family:"Newsreader",Georgia,serif;font-weight:500;font-size:34px;letter-spacing:-.01em;margin:0;line-height:1.1}
  .sto-lead{font-size:16px;color:var(--ink2);max-width:430px;margin:12px 0 0;line-height:1.3;text-wrap:balance}
  .sto-card{width:560px;background:#fff;border-radius:12px;box-shadow:0 0 0 .5px rgba(26,22,14,.1),0 1px 3px rgba(0,0,0,.04);text-align:left;margin-top:20px}
  .sto-row{display:flex;align-items:flex-start;gap:14px;padding:15px 16px;position:relative}
  .sto-row+.sto-row::before{content:"";position:absolute;top:0;left:48px;right:0;height:.5px;background:var(--sep)}
  .sto-tile{flex:0 0 auto;width:34px;height:34px;border-radius:9px;background:rgba(78,125,92,.08);color:var(--sage);display:flex;align-items:center;justify-content:center}
  .sto-name{font-size:14.5px;font-weight:600}
  .sto-why{font-size:12.5px;color:var(--ink2);margin-top:2px;line-height:1.3}
  .sto-ctl{flex:0 0 auto;width:120px;display:flex;flex-direction:column;align-items:center;gap:6px}
  .sto-pill{height:30px;padding:0 14px;border-radius:8px;border:0;font:inherit;font-size:13px;font-weight:600;background:var(--sage);color:#fff;display:inline-flex;align-items:center;gap:6px;box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(40,60,45,.22);cursor:pointer}
  .sto-cap{font-family:"IBM Plex Mono",monospace;font-size:11px;color:var(--ink3);text-align:center}
  .sto-ready{display:flex;align-items:center;gap:6px;font-family:"IBM Plex Mono",monospace;font-size:11px;font-weight:500;color:var(--sage);letter-spacing:.12em;height:20px}
  .sto-rec{display:flex;align-items:center;gap:10px;margin-top:6px;font-size:12.5px;color:var(--ink2)}
  .sto-rec button{background:none;border:0;padding:0;font:inherit;font-weight:600;color:var(--ink2);display:inline-flex;align-items:center;gap:3px;cursor:pointer}
  .sto-rec button:hover{color:var(--ink)}
  .sto-skip{font-size:13.5px;color:var(--ink3);height:40px;display:flex;align-items:center}
  .sto-cta{height:40px;padding:0 22px;border-radius:9px;border:0;font:inherit;font-size:14.5px;font-weight:600;background:var(--sage);color:#fff;box-shadow:inset 0 1px 0 rgba(255,255,255,.22),0 1px 2px rgba(40,60,45,.28)}
  .sto-foot{display:flex;flex-direction:column;align-items:center;gap:2px}
  .sto-foot b{font-size:14px;font-weight:700}
  .sto-foot span{font-size:12px;color:var(--ink3)}
  .sto-over{position:absolute;inset:28px 0 0 0;background:rgba(26,24,19,.06);display:flex;justify-content:center;padding-top:36px;z-index:4}
  /* settings */
  .sts-page{height:100%;background:#FAF9F5;padding:30px 0;box-sizing:border-box;overflow:hidden;position:relative}
  .sts-col{max-width:640px;margin:0 auto;padding:0 20px}
  .sts-title{font-family:"Newsreader",Georgia,serif;font-weight:500;font-size:27px;letter-spacing:-.01em;margin:0 0 16px 10px}
  .sts-sechd{display:flex;align-items:baseline;justify-content:space-between;font-size:13px;font-weight:700;padding:0 10px 8px}
  .sts-sechd span{font-size:12px;font-weight:400;color:var(--ink2)}
  .sts-group{background:rgba(255,255,255,.85);border-radius:10px;box-shadow:0 0 0 .5px rgba(26,22,14,.1);margin-bottom:22px}
  .sts-row{display:flex;align-items:center;gap:10px;padding:10px 12px;font-size:13px;position:relative}
  .sts-row+.sts-row::before{content:"";position:absolute;top:0;left:12px;right:12px;height:.5px;background:var(--sep)}
  .sts-row .sub{font-size:12px;color:var(--ink2);margin-top:3px}
  .sts-row .val{font-size:12px;color:var(--ink2);white-space:nowrap}
  .sts-tog{width:26px;height:15px;border-radius:8px;background:var(--sage);position:relative;flex:0 0 auto}
  .sts-tog{cursor:pointer;transition:background .15s}.sts-tog.off{background:rgba(26,24,19,.16)}
  .sts-tog.off::after{right:auto;left:1.5px}
  .sts-tog::after{content:"";position:absolute;right:1.5px;top:1.5px;width:12px;height:12px;border-radius:50%;background:#fff;box-shadow:0 .5px 1px rgba(0,0,0,.25)}
  `;
  document.head.appendChild(s);
}

function StoGlyph({ name }) {
  const p = { width: 18, height: 18, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round', style: { display: 'block' } };
  if (name === 'waveform') return <svg {...p}><path d="M4 11v2M7.5 8.5v7M11 5.5v13M14.5 9v6M18 7v10M21 11v2" /></svg>;
  if (name === 'sparkles') return <svg {...p}><path d="M13 5c.6 3.3 2 4.7 5.3 5.3-3.3.6-4.7 2-5.3 5.3-.6-3.3-2-4.7-5.3-5.3C11 9.7 12.4 8.3 13 5Z" fill="currentColor" stroke="none" /><path d="M6.5 3.5v3M5 5h3" strokeWidth="1.5" /></svg>;
  if (name === 'person') return <svg {...p}><circle cx="9" cy="8.5" r="3.2" /><path d="M3.5 19a5.5 5.5 0 0 1 11 0" /><path d="M15.5 5.6a3.1 3.1 0 0 1 0 5.8M17.5 14.2a5.4 5.4 0 0 1 3 4.8" /></svg>;
  if (name === 'down') return <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ display: 'block' }}><circle cx="12" cy="12" r="9" /><path d="M12 7.5v8M8.5 12.5 12 16l3.5-3.5" /></svg>;
  return null;
}
function StoReady() {
  return (<span className="sto-ready"><span style={{ width: 16, height: 16, borderRadius: '50%', background: 'var(--sage)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><SttGlyph name="check" size={10} color="#fff" /></span>READY</span>);
}
function StoProgress({ pct }) {
  return (<React.Fragment>
    <div className="stt-bar" style={{ width: 120, height: 3 }}><i style={{ width: `${pct}%` }} /></div>
    <span className="sto-cap" style={{ color: 'var(--ink2)' }}>Downloading… {pct}%</span>
  </React.Fragment>);
}

// Transcription row trailing control, derived from the STT selection.
function StoSttControl({ s, act }) {
  const k = sttTarget(s);
  if (s[k] === 'downloading') return <StoProgress pct={s.pct[k]} />;
  if (isReady(s, k)) return (<React.Fragment><StoReady />{k === 'apple' && <span className="sto-cap">Built in</span>}</React.Fragment>);
  return (<React.Fragment>
    <button className="sto-pill" onClick={() => act.download(k)}><StoGlyph name="down" />Download</button>
    <span className="sto-cap">{k === 'apple' ? 'System download' : '~635 MB'}</span>
  </React.Fragment>);
}

function StoRow({ icon, name, why, ctl, extra }) {
  return (<div className="sto-row">
    <span className="sto-tile"><StoGlyph name={icon} /></span>
    <div style={{ flex: 1, minWidth: 0 }}><div className="sto-name">{name}</div><div className="sto-why">{why}</div>{extra}</div>
    <div className="sto-ctl">{ctl}</div>
  </div>);
}
function StoRec({ name, onSeeAll }) {
  return (<div className="sto-rec"><span>{name}</span>
    <button onClick={onSeeAll}>See all options<SttGlyph name="chev" size={11} /></button></div>);
}

function SttOnboarding({ init, sheetOpen = false, variant = 'b' }) {
  const [s, act] = useSttState(init);
  const [open, setOpen] = React.useState(sheetOpen);
  const k = sttTarget(s);
  return (<div className="stt-scope" style={{ height: '100%' }}><div className="sto-win">
    <div className="sto-tb"><i style={{ background: '#ff5f57' }} /><i style={{ background: '#febc2e' }} /><i style={{ background: '#28c840' }} /></div>
    <div className="sto-body">
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 240, height: 3, borderRadius: 3, background: 'rgba(26,24,19,.1)' }}><div style={{ width: '80%', height: '100%', borderRadius: 3, background: 'var(--sage)' }} /></div>
        <div className="sto-kick">AI Models</div>
      </div>
      <div className="sto-main">
        <h1 className="sto-title">Download Local AI Models</h1>
        <p className="sto-lead">One-time download. AI runs locally — nothing leaves your Mac.</p>
        <div className="sto-card">
          <StoRow icon="waveform" name="Transcription" why="Turns speech into text."
            ctl={<StoSttControl s={s} act={act} />}
            extra={s[k] !== 'downloading' && <StoRec name={k === 'apple' ? `Apple Speech · ${s.lang} Only` : STT_NAMES[k]} onSeeAll={() => setOpen(true)} />} />
          <StoRow icon="person" name="Speaker ID" why="Labels who’s speaking."
            ctl={<React.Fragment><button className="sto-pill"><StoGlyph name="down" />Download</button><span className="sto-cap">size TBD</span></React.Fragment>} />
          <StoRow icon="sparkles" name="Language Model" why="Meeting summaries, speaker matching, and automatic titles."
            ctl={<React.Fragment><button className="sto-pill"><StoGlyph name="down" />Download</button><span className="sto-cap">~3 GB</span></React.Fragment>}
            extra={<StoRec name="Gemma 4 E2B" onSeeAll={() => {}} />} />
        </div>
        <div style={{ marginTop: 24, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}><span className="sto-skip">Skip</span></div>
      </div>
      <div className="sto-foot">
        <img src="Biscotti Design System/brand/mark-shield-mic.png" alt="" style={{ width: 18, height: 18, objectFit: 'contain', marginBottom: 4 }} />
        <b>Biscotti</b><span>Total recall, total privacy.</span>
      </div>
    </div>
    {open && <div className="sto-over"><SttSheet variant={variant} s={s} act={act} onDone={() => setOpen(false)} /></div>}
  </div></div>);
}

function SttSettings({ init, sheetOpen = false, variant = 'b', vocabAlert = false }) {
  const [s, act] = useSttState(init);
  const [open, setOpen] = React.useState(sheetOpen);
  const [vocab, setVocab] = React.useState(true);
  const [vAlert, setVAlert] = React.useState(vocabAlert);
  const k = sttTarget(s);
  const ready = isReady(s, k);
  const vocabOn = vocab && k === 'whisper';
  const toggleVocab = () => { if (vocabOn) setVocab(false); else if (k === 'whisper') setVocab(true); else setVAlert(true); };
  const switchToWhisper = () => { if (s.whisper === 'ready') act.choose('whisper'); else if (s.whisper === 'none') act.download('whisper'); else act.choose('whisper'); setVocab(true); setVAlert(false); };
  return (<div className="stt-scope" style={{ height: '100%' }}><div className="sts-page">
    <div className="sts-col">
      <h1 className="sts-title">Settings</h1>
      <div className="sts-sechd">AI Enhancements<span>AI runs locally on your Mac.</span></div>
      <div className="sts-group">
        <div className="sts-row"><div style={{ flex: 1 }}>AI Analysis &amp; Summary<div className="sub">Generate a title and summary from the transcript, and guess the names of speakers from context.</div></div><span className="sts-tog" /></div>
        <div className="sts-row"><div style={{ flex: 1 }}>Summary Prompt<div className="sub">Customize the instructions used to write meeting summaries.</div></div><button className="stt-btn">Customize…</button></div>
        <div className="sts-row"><div style={{ flex: 1 }}>Speech to Text Model<div className="sub">The model used to transcribe meetings</div></div>
          {ready ? <React.Fragment><span className="val">{k === 'apple' ? `Apple Speech · ${s.lang} Only` : STT_NAMES[k]}</span><button className="stt-btn" onClick={() => setOpen(true)}>Manage</button></React.Fragment>
            : <button className="stt-btn" onClick={() => setOpen(true)}>Download…</button>}
        </div>
        <div className="sts-row"><div style={{ flex: 1 }}>AI Language Model<div className="sub">The AI model used to summarize meetings</div></div><span className="val">Gemma 4 E2B</span><button className="stt-btn">Manage</button></div>
      </div>
      <div className="sts-sechd">Custom Vocabulary<span>Beta</span></div>
      <div className="sts-group"><div className="sts-row"><div style={{ flex: 1 }}>Custom Vocabulary</div><span className={'sts-tog' + (vocabOn ? '' : ' off')} onClick={toggleVocab} /></div></div>
    </div>
    {vAlert && <div className="stt-scrim" style={{ background: 'rgba(26,24,19,.06)' }}><div className="stt-alert">
      <img src="Biscotti Design System/brand/app-icon.png" alt="" />
      <h3>Requires Whisper Transcription</h3>
      <p>Custom vocabulary only works with the Whisper speech to text model. Switching downloads Whisper (635 MB) and uses it for new transcripts.</p>
      <div className="btns"><button className="stt-abtn" onClick={() => setVAlert(false)}>Cancel</button><button className="stt-abtn pri" onClick={switchToWhisper}>Switch to Whisper</button></div>
    </div></div>}
    {open && <div className="sto-over" style={{ inset: 0 }}><SttSheet variant={variant} s={s} act={act} onDone={() => setOpen(false)} /></div>}
  </div></div>);
}

Object.assign(window, { SttOnboarding, SttSettings });
