import Foundation

/// ブラウザのモニターのページ（撮る側の iPhone の Web サーバーが返す）。
/// アプリのモニター（RemoteMonitorView）と同じことができる:
/// - 上の帯: 左右反転・プレビュー・タッチ撮影・全画面（全画面中は「隠す」）、撮る側の名前
/// - 映像: タップでピント・露出、長押し（0.6 秒）で AE/AF ロック、タッチ撮影がオンならタップで撮る
/// - 一致度・録画の時間・見本写真（タップで隠す・出す）・秒読み
/// - 下の帯: 撮った写真（一覧 → 1 枚ずつ、つまんで拡大・ダブルタップ）、タイマー、シャッター、カメラの切り替え
/// - 全画面: ボタンを隠し、右上の「表示」か下から上へなぞると出る（上から下へなぞると隠れる）
/// - 撮影後のプレビュー（撮る側でオンのとき。「プレビュー」でオフにできる）
/// 左右反転・プレビュー・タッチ撮影は、このブラウザに覚えておく。
/// 文字列の中ではバックスラッシュを使わない（Swift の文字列として書いているため）
enum WebMonitorPage {
    static let html = """
    <!doctype html><html lang="ja"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <title>ポーズカメラ モニター</title>
    <style>
    *{box-sizing:border-box}
    html,body{margin:0;height:100%;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;overflow:hidden;
      -webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent}
    button{font:inherit;color:#fff;cursor:pointer}
    button:disabled{opacity:.35}
    #app{position:fixed;inset:0;display:flex;flex-direction:column}
    .bar{background:#000;flex:none;z-index:5}
    #top{padding-top:env(safe-area-inset-top)}
    #top .row{display:flex;align-items:center;gap:4px;padding:6px 10px 0}
    #name{text-align:center;font-size:11px;color:#aaa;font-weight:600;min-height:14px;padding:0 10px 6px;
      white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .tb{background:none;border:0;width:60px;height:46px;display:flex;flex-direction:column;align-items:center;
      justify-content:center;gap:2px;padding:0}
    .tb .ic{font-size:18px;line-height:22px;height:22px}
    .tb .lb{font-size:10px;font-weight:600;white-space:nowrap}
    .tb.on{color:#ffd60a}
    .sp{flex:1}
    #stage{flex:1;position:relative;overflow:hidden;touch-action:none}
    #v{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none}
    #msg{position:absolute;left:0;right:0;top:45%;text-align:center;color:#aaa;font-size:15px;padding:0 20px}
    #info{position:absolute;left:10px;top:10px;display:flex;flex-direction:column;gap:6px;align-items:flex-start}
    #app.full.chrome #info{top:calc(76px + env(safe-area-inset-top))}
    .badges{display:flex;gap:6px}
    .badge{background:#0008;border-radius:14px;padding:5px 11px;font-weight:600;font-size:14px}
    .badge.ok{background:#1db954}
    #sample{position:relative;width:92px;border-radius:8px;overflow:hidden;border:1px solid #fffb;box-shadow:0 2px 6px #0007}
    #sample img{display:block;width:100%}
    #sample .x{position:absolute;right:3px;top:3px;width:18px;height:18px;border-radius:50%;background:#0009;
      font-size:11px;font-weight:700;display:flex;align-items:center;justify-content:center}
    #sampleShow{width:36px;height:36px;border-radius:8px;background:#0007;border:0;font-size:16px}
    #fmark{position:absolute;width:70px;height:70px;border:1.5px solid #ffd60a;border-radius:3px;
      transform:translate(-50%,-50%);pointer-events:none}
    #flock{position:absolute;left:50%;top:-20px;transform:translateX(-50%);background:#ffd60a;color:#000;
      font-size:10px;font-weight:700;padding:1px 4px;white-space:nowrap}
    #count{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:120px;font-weight:700;
      text-shadow:0 2px 10px #000;pointer-events:none}
    #bottom{display:flex;align-items:center;justify-content:space-between;
      padding:12px 16px calc(12px + env(safe-area-inset-bottom))}
    .thumb{width:44px;height:44px;border-radius:8px;border:1px solid #fff9;background:#222;padding:0;overflow:hidden;
      display:flex;align-items:center;justify-content:center;font-size:18px}
    .thumb img{width:100%;height:100%;object-fit:cover}
    .thumbsp{width:44px;height:44px}
    #shutter{width:76px;height:76px;border-radius:50%;border:4px solid #fff;background:none;padding:0;
      display:flex;align-items:center;justify-content:center}
    #shutter i{display:block;width:60px;height:60px;border-radius:50%;background:#fff;transition:all .15s}
    #shutter.video i{background:#e22}
    #shutter.rec i{width:28px;height:28px;border-radius:6px;background:#e22}
    #shutter.busy{opacity:.5}
    .round{width:48px;height:48px;border-radius:50%;background:#ffffff2e;border:0;font-size:22px}
    #app.full #top,#app.full #bottom{position:absolute;left:0;right:0;background:#0008;display:none}
    #app.full #top{top:0}
    #app.full #bottom{bottom:0}
    #app.full.chrome #top{display:block}
    #app.full.chrome #bottom{display:flex}
    #bShow{position:absolute;top:calc(6px + env(safe-area-inset-top));right:10px;z-index:6;background:#0007;border-radius:10px}
    .layer{position:fixed;inset:0;z-index:20}
    #cap{background:#000d;display:flex;align-items:center;justify-content:center}
    #cap img{max-width:100%;max-height:100%;object-fit:contain}
    #album,#viewer{background:#000;display:flex;flex-direction:column}
    .ahead{display:flex;align-items:center;justify-content:space-between;padding:calc(8px + env(safe-area-inset-top)) 12px 8px;
      font-weight:600;font-size:15px;flex:none}
    .ahead button{background:none;border:0;font-size:16px;min-width:60px;text-align:left;color:#0a84ff}
    .ahead span:last-child{min-width:60px}
    #grid{flex:1;overflow-y:auto;display:grid;grid-template-columns:repeat(auto-fill,minmax(100px,1fr));gap:2px;
      align-content:start;padding-bottom:env(safe-area-inset-bottom)}
    #grid img{width:100%;aspect-ratio:3/4;object-fit:cover;display:block}
    #aEmpty{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;color:#aaa;
      text-align:center;padding:30px;font-size:14px;gap:8px}
    #vStage{flex:1;position:relative;overflow:hidden;touch-action:none}
    #vImg{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;transform-origin:50% 50%;pointer-events:none}
    [hidden]{display:none!important}
    </style></head><body>
    <div id="app">
      <div id="top" class="bar">
        <div class="row">
          <button class="tb" id="bMirror"><span class="ic">⇋</span><span class="lb">左右反転</span></button>
          <button class="tb" id="bPrev"><span class="ic" id="iPrev">◉</span><span class="lb">プレビュー</span></button>
          <button class="tb" id="bTouch"><span class="ic">☝︎</span><span class="lb">タッチ撮影</span></button>
          <div class="sp"></div>
          <button class="tb" id="bHide" hidden><span class="ic">▁</span><span class="lb">隠す</span></button>
          <button class="tb" id="bFull"><span class="ic" id="iFull">⤢</span><span class="lb" id="lFull">全画面</span></button>
        </div>
        <div id="name"></div>
      </div>
      <div id="stage">
        <img id="v" alt="" draggable="false">
        <div id="msg">つないでいます…</div>
        <div id="info">
          <div class="badges"><span id="score" class="badge" hidden></span><span id="rec" class="badge" hidden></span><span id="burst" class="badge" hidden></span></div>
          <div id="sample" class="nofocus" hidden><img id="sImg" alt="" draggable="false"><span class="x">✕</span></div>
          <button id="sampleShow" class="nofocus" hidden>🖼</button>
        </div>
        <div id="fmark" hidden><span id="flock" hidden>AE/AF ロック</span></div>
        <div id="count" hidden></div>
      </div>
      <div id="bottom" class="bar">
        <button id="bAlbum" class="thumb" aria-label="撮った写真を見る"><img id="thumb" alt="" hidden><span id="thumbIc">▦</span></button>
        <button id="bTimer" class="tb"><span class="ic">⏱</span><span class="lb" id="lTimer">タイマー</span></button>
        <button id="shutter" aria-label="シャッター"><i></i></button>
        <button id="bFlip" class="round" aria-label="カメラの切り替え">⟲</button>
        <div class="thumbsp"></div>
      </div>
      <button class="tb" id="bShow" hidden><span class="ic">▔</span><span class="lb">表示</span></button>
    </div>
    <div id="cap" class="layer" hidden><img id="capImg" alt=""></div>
    <div id="album" class="layer" hidden>
      <div class="ahead"><button id="aClose">∨ 戻る</button><span>撮った写真</span><span></span></div>
      <div id="grid"></div>
      <div id="aEmpty" hidden><div style="font-size:15px;color:#fff">まだ写真がありません</div>
        <div>このモニターを開いている間に撮った写真が、ここに入ります。</div></div>
    </div>
    <div id="viewer" class="layer" hidden>
      <div class="ahead"><button id="vBack">‹ 一覧</button><span id="vPos"></span><span></span></div>
      <div id="vStage"><img id="vImg" alt="" draggable="false"></div>
    </div>
    <script>
    const k=new URLSearchParams(location.search).get('k');
    const $=id=>document.getElementById(id);
    const q=(path,extra)=>path+'?k='+k+(extra||'');
    function load(key,def){try{const v=localStorage.getItem('posecam-'+key);return v==null?def:v==='1';}catch(e){return def;}}
    function save(key,v){try{localStorage.setItem('posecam-'+key,v?'1':'0');}catch(e){}}
    function buzz(){if(navigator.vibrate)navigator.vibrate(15);}
    let mirror=load('mirror',false),showPrev=load('preview',true),touch=load('touch',false);
    let full=false,chrome=false,st={},photos=[],lastPreview=null,firstState=true,sampleShown=true,sampleName=null;

    function render(){
      $('v').style.transform=mirror?'scaleX(-1)':'';
      $('bMirror').classList.toggle('on',mirror);
      $('bPrev').classList.toggle('on',showPrev);$('iPrev').textContent=showPrev?'◉':'⊘';
      $('bTouch').classList.toggle('on',touch);
      const app=$('app');app.classList.toggle('full',full);app.classList.toggle('chrome',full&&chrome);
      $('lFull').textContent=full?'戻す':'全画面';$('iFull').textContent=full?'⤡':'⤢';
      $('bHide').hidden=!full;$('bShow').hidden=!(full&&!chrome);
    }
    $('bMirror').onclick=()=>{mirror=!mirror;save('mirror',mirror);render();if(!firstState)update(st);};
    $('bPrev').onclick=()=>{showPrev=!showPrev;save('preview',showPrev);render();};
    $('bTouch').onclick=()=>{touch=!touch;save('touch',touch);render();};
    $('bFull').onclick=()=>{
      full=!full;chrome=false;render();
      try{if(full&&document.documentElement.requestFullscreen)document.documentElement.requestFullscreen().catch(()=>{});
        else if(!full&&document.fullscreenElement)document.exitFullscreen().catch(()=>{});}catch(e){}
    };
    $('bHide').onclick=()=>{chrome=false;render();};
    $('bShow').onclick=()=>{chrome=true;render();};
    render();

    // 映像（MJPEG）。切れたら 1 秒後につなぎ直す
    const v=$('v'),msg=$('msg');
    function connect(){v.src=q('/stream','&t='+Date.now());}
    v.onload=()=>{msg.hidden=true;};
    v.onerror=()=>{msg.hidden=false;msg.textContent='つなぎ直しています…';setTimeout(connect,1000);};
    connect();
    function cmd(c){fetch(q('/cmd','&c='+c)).catch(()=>{});buzz();}
    $('shutter').onclick=()=>cmd('shutter');
    $('bFlip').onclick=()=>cmd('flip');
    $('bTimer').onclick=()=>cmd('timer');

    // 映像の表示されている範囲（画面の座標）
    function fitted(){
      const r=$('stage').getBoundingClientRect(),w=v.naturalWidth,h=v.naturalHeight;
      if(!w||!h)return null;
      const s=Math.min(r.width/w,r.height/h),fw=w*s,fh=h*s;
      return {x:r.left+(r.width-fw)/2,y:r.top+(r.height-fh)/2,w:fw,h:fh,left:r.left,top:r.top};
    }
    let markTimer=null;
    // タップした所にピント・露出を合わせる（左右反転して見ていれば戻して送る）
    function focusAt(cx,cy,lock){
      const f=fitted();if(!f)return false;
      const sx=(cx-f.x)/f.w,sy=(cy-f.y)/f.h;
      if(sx<0||sx>1||sy<0||sy>1)return false;
      const x=mirror?1-sx:sx;
      fetch(q('/focus','&x='+x.toFixed(4)+'&y='+sy.toFixed(4)+'&lock='+(lock?1:0))).catch(()=>{});
      buzz();
      const m=$('fmark');m.style.left=(cx-f.left)+'px';m.style.top=(cy-f.top)+'px';m.hidden=false;
      $('flock').hidden=!lock;
      clearTimeout(markTimer);
      if(!lock)markTimer=setTimeout(()=>{m.hidden=true;},1200);
      return true;
    }
    // 映像の操作: タップでピント（タッチ撮影なら撮る）、0.6 秒触れたままで AE/AF ロック、
    // 全画面では上下になぞってボタンを出す・隠す
    let press=null;
    const stage=$('stage');
    stage.addEventListener('contextmenu',e=>e.preventDefault());
    stage.addEventListener('pointerdown',e=>{
      if(e.target.closest('.nofocus'))return;
      const p={x:e.clientX,y:e.clientY,locked:false,moved:false};
      p.timer=setTimeout(()=>{if(!p.moved){p.locked=true;focusAt(p.x,p.y,true);}},600);
      press=p;
    });
    stage.addEventListener('pointermove',e=>{
      if(press&&Math.hypot(e.clientX-press.x,e.clientY-press.y)>12){press.moved=true;clearTimeout(press.timer);}
    });
    stage.addEventListener('pointerup',e=>{
      if(!press)return;
      const p=press;press=null;clearTimeout(p.timer);
      if(p.moved){
        const dx=e.clientX-p.x,dy=e.clientY-p.y;
        if(full&&Math.abs(dy)>30&&Math.abs(dy)>Math.abs(dx)){chrome=dy<0;render();}
        return;
      }
      if(p.locked)return;
      if(focusAt(p.x,p.y,false)&&touch&&!st.recording&&!st.busy&&st.countdown==null){
        setTimeout(()=>cmd('shutter'),300);
      }
    });
    stage.addEventListener('pointercancel',()=>{if(press){clearTimeout(press.timer);press=null;}});
    // 見本写真: タップで隠す・出す
    $('sample').onclick=()=>{sampleShown=false;updateSample();};
    $('sampleShow').onclick=()=>{sampleShown=true;updateSample();};
    function updateSample(){
      $('sample').hidden=!st.sample||!sampleShown;
      $('sampleShow').hidden=!st.sample||sampleShown;
    }

    // 撮った写真
    function photoURL(id){return q('/photo','&id='+id);}
    function renderThumb(){
      const t=$('thumb');
      if(photos.length){t.src=photoURL(photos[0]);t.hidden=false;$('thumbIc').hidden=true;}
      else{t.hidden=true;$('thumbIc').hidden=false;}
    }
    let capTimer=null;
    function showCapture(id){
      $('capImg').src=photoURL(id);$('cap').hidden=false;
      clearTimeout(capTimer);capTimer=setTimeout(()=>{$('cap').hidden=true;},2000);
    }
    $('cap').onclick=()=>{$('cap').hidden=true;};
    function renderGrid(){
      const g=$('grid');g.innerHTML='';
      $('aEmpty').hidden=photos.length>0;g.hidden=photos.length===0;
      photos.forEach((id,i)=>{const im=document.createElement('img');im.loading='lazy';im.src=photoURL(id);
        im.onclick=()=>openViewer(i);g.appendChild(im);});
    }
    $('bAlbum').onclick=()=>{renderGrid();$('album').hidden=false;};
    $('aClose').onclick=()=>{$('album').hidden=true;};

    // 1 枚ずつ見る: 左右になぞってめくる、つまんで拡大、ダブルタップで 2.5 倍・元に戻す、拡大中はなぞって動かす
    let vi=0,zs=1,tx=0,ty=0;
    const vImg=$('vImg'),vStage=$('vStage');
    function applyZoom(){
      const r=vStage.getBoundingClientRect(),mx=(zs-1)*r.width/2,my=(zs-1)*r.height/2;
      tx=Math.max(-mx,Math.min(mx,tx));ty=Math.max(-my,Math.min(my,ty));
      vImg.style.transform='translate('+tx+'px,'+ty+'px) scale('+zs+')';
    }
    function openViewer(i){
      if(i<0||i>=photos.length)return;
      vi=i;zs=1;tx=0;ty=0;applyZoom();vImg.src=photoURL(photos[i]);
      $('vPos').textContent=(i+1)+' / '+photos.length;$('viewer').hidden=false;
    }
    $('vBack').onclick=()=>{$('viewer').hidden=true;};
    const pts=new Map();let pinch=null,swipe=null,lastTap=0;
    vStage.addEventListener('pointerdown',e=>{
      try{vStage.setPointerCapture(e.pointerId);}catch(err){}
      pts.set(e.pointerId,{x:e.clientX,y:e.clientY});
      if(pts.size===2){const a=[...pts.values()];
        pinch={d:Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y),s:zs};swipe=null;}
      else if(pts.size===1){swipe={x:e.clientX,y:e.clientY,tx:tx,ty:ty,moved:false};}
    });
    vStage.addEventListener('pointermove',e=>{
      if(!pts.has(e.pointerId))return;
      pts.set(e.pointerId,{x:e.clientX,y:e.clientY});
      if(pinch&&pts.size===2){const a=[...pts.values()];
        const d=Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y);
        zs=Math.max(1,Math.min(5,pinch.s*d/Math.max(1,pinch.d)));applyZoom();return;}
      if(swipe){const dx=e.clientX-swipe.x,dy=e.clientY-swipe.y;
        if(Math.hypot(dx,dy)>8)swipe.moved=true;
        if(zs>1.01){tx=swipe.tx+dx;ty=swipe.ty+dy;applyZoom();}}
    });
    function endPointer(e){
      if(!pts.has(e.pointerId))return;
      pts.delete(e.pointerId);
      if(pinch){if(pts.size<2)pinch=null;if(zs<1.02){zs=1;tx=0;ty=0;applyZoom();}swipe=null;return;}
      if(!swipe)return;
      const s=swipe;swipe=null;const dx=e.clientX-s.x;
      if(s.moved){if(zs<=1.01&&Math.abs(dx)>50)openViewer(vi+(dx<0?1:-1));return;}
      const now=Date.now();
      if(now-lastTap<300){
        lastTap=0;
        if(zs>1.01){zs=1;tx=0;ty=0;}
        else{const r=vStage.getBoundingClientRect(),cx=e.clientX-r.left-r.width/2,cy=e.clientY-r.top-r.height/2;
          zs=2.5;tx=-cx*(zs-1);ty=-cy*(zs-1);}
        applyZoom();
      }else lastTap=now;
    }
    vStage.addEventListener('pointerup',endPointer);
    vStage.addEventListener('pointercancel',endPointer);

    // 撮る側の状態（0.3 秒ごと）
    function pad(n){return String(n).padStart(2,'0');}
    function update(s){
      st=s;
      $('name').textContent=s.camera||'';
      const sc=$('score');sc.hidden=s.score==null;sc.textContent='一致度 '+s.score+'%';sc.className='badge'+(s.matched?' ok':'');
      const r=$('rec');r.hidden=!s.recording;
      r.textContent='● '+pad(Math.floor((s.recordingSeconds||0)/60))+':'+pad((s.recordingSeconds||0)%60);
      const bu=$('burst');bu.hidden=s.burstShot==null;bu.textContent='連続撮影 '+s.burstShot+' / '+s.burstTotal+'枚';
      const c=$('count');c.hidden=s.countdown==null;c.textContent=s.countdown==null?'':s.countdown;
      $('lTimer').textContent=s.timerSeconds?s.timerSeconds+'秒':'タイマー';
      $('bTimer').classList.toggle('on',!!s.timerSeconds);
      $('shutter').className=(s.recording?'rec':(s.mode==='動画'||s.mode==='スナップ')?'video':'')+(s.busy?' busy':'');
      $('bFlip').disabled=s.canFlip===false;
      if(s.sample!==sampleName){sampleName=s.sample;if(s.sample)$('sImg').src=q('/sample','&n='+encodeURIComponent(s.sample));}
      // モニターで左右反転して見ているときは、見本写真も一緒に反転する
      $('sImg').style.transform=(!!s.sampleMirrored!==mirror)?'scaleX(-1)':'';
      updateSample();
      const ids=s.photos||[];
      if(ids.join(',')!==photos.join(',')){photos=ids;renderThumb();if(!$('album').hidden)renderGrid();}
      if(firstState){lastPreview=s.preview;firstState=false;}
      else if(s.preview!=null&&s.preview!==lastPreview){lastPreview=s.preview;if(showPrev)showCapture(s.preview);}
    }
    async function poll(){
      try{update(await (await fetch(q('/state'),{cache:'no-store'})).json());}catch(e){}
      setTimeout(poll,300);
    }
    poll();
    </script></body></html>
    """
}
