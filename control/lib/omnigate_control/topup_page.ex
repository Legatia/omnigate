defmodule OmnigateControl.TopupPage do
  @moduledoc """
  The top-up page: where the holder of a prepaid key buys credit without
  writing a program. One self-contained HTML page, built like the dashboard
  (inline style and script under a per-response nonce, nothing loaded from
  elsewhere, all data written with `textContent`).

  It is served on the gateway's public port at `GET /topup`, which the data
  plane hands to `GET /internal/topup` here, and only while payments are
  configured. The page itself holds nothing secret and needs no sign-in: the
  holder types the key into it, and the script calls the payments API
  (`/v1/payments*`, see `OmnigateControl.Payments`) on the same origin with
  that key. The key is kept in the page's memory only: not in a cookie, not
  in storage, not in the address.

  The deposit address is also drawn as a QR code, made in the page (byte
  mode, error correction level M, versions 1 to 9: up to 180 bytes).
  """
  alias OmnigateControl.Dashboard

  @doc "The page for a CSP nonce."
  def page(nonce) do
    [
      ~s(<!doctype html><html lang="en"><head><meta charset="utf-8">),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
      ~s(<link rel="icon" href="data:,"><title>Top up · omnigate</title><style nonce="),
      nonce,
      ~s(">),
      Dashboard.css(),
      css(),
      ~s(</style></head><body class="tu">),
      ~s(<header class="top"><div class="brand">omnigate <span>top up</span></div>),
      ~s(<div class="right"><span id="who" class="muted"></span><button type="button" id="forget" class="ghost" hidden>Forget key</button></div></header>),
      ~s(<main class="tu-main">),
      ~s(<noscript><p class="panel">This page needs JavaScript. The same can be done over the payments API: see docs/payments.md.</p></noscript>),
      # 1: the key
      ~s(<section id="s-key" class="panel"><h2>Your key</h2>),
      ~s(<p class="muted">The gateway key the credit is for. It stays in this page: it is not stored and is sent only to this gateway.</p>),
      ~s(<form id="f-key" autocomplete="off"><label>Gateway key<input id="key" type="password" required autocomplete="off" spellcheck="false" maxlength="512"></label>),
      ~s(<div class="row"><button type="submit" id="key-go">Continue</button><span id="key-status" class="status" role="status"></span></div></form></section>),
      # 2: balance and a new payment
      ~s(<section id="s-balance" class="panel" hidden><div class="bal"><div><div class="label muted">Credit left</div><div id="balance" class="value">—</div></div>),
      ~s(<div id="bal-sub" class="muted small-text"></div></div></section>),
      ~s(<section id="s-new" class="panel" hidden><h2>Add credit</h2>),
      ~s(<form id="f-new" autocomplete="off"><div class="amounts" role="group" aria-label="Amount in US dollars">),
      ~s(<button type="button" class="ghost amt" data-usd="5">$5</button><button type="button" class="ghost amt" data-usd="20">$20</button>),
      ~s(<button type="button" class="ghost amt" data-usd="50">$50</button><button type="button" class="ghost amt" data-usd="100">$100</button></div>),
      ~s(<div class="fields"><label>Amount in USD<input id="usd" type="number" min="0" step="0.01" inputmode="decimal" required></label>),
      ~s(<label>Network<select id="chain" required></select></label>),
      ~s(<label>Pay with<select id="asset" required></select></label></div>),
      ~s(<label>Refund address <span class="muted">on that network: where the funds return if the payment fails. Use the address you pay from.</span>),
      ~s(<input id="refund" required maxlength="200" spellcheck="false" autocomplete="off"></label>),
      ~s(<div id="quote" class="quote" hidden></div>),
      ~s(<div class="row"><button type="submit" id="quote-go">Get a quote</button><button type="button" id="pay-go" hidden>Start payment</button>),
      ~s(<span id="new-status" class="status" role="status"></span></div></form></section>),
      # 3: one payment
      ~s(<section id="s-pay" class="panel" hidden><div class="row head"><h2>Payment</h2><span id="pay-pill"></span></div>),
      ~s(<ol id="steps" class="steps"><li id="st-1">Send the deposit</li><li id="st-2">Swap in progress</li><li id="st-3">Credit added</li></ol>),
      ~s(<div id="pay-send" class="send"><div id="qr" class="qr" role="img" aria-label="The deposit address as a QR code"></div>),
      ~s(<dl class="what"><dt>Send exactly</dt><dd><span id="p-amount" class="big"></span> <button type="button" class="small ghost copy" data-copy="p-amount-raw">Copy</button><span id="p-amount-raw" hidden></span></dd>),
      ~s(<dt>On</dt><dd id="p-chain"></dd>),
      ~s(<dt>To this address</dt><dd><span id="p-address" class="mono addr"></span> <button type="button" class="small ghost copy" data-copy="p-address">Copy</button></dd>),
      ~s(<dt id="p-memo-l" hidden>With this memo</dt><dd id="p-memo-d" hidden><span id="p-memo" class="mono addr"></span> <button type="button" class="small ghost copy" data-copy="p-memo">Copy</button></dd>),
      ~s(<dt>Before</dt><dd id="p-deadline"></dd></dl></div>),
      ~s(<p id="pay-note" class="muted"></p>),
      ~s(<dl id="pay-facts" class="facts"></dl>),
      ~s(<div class="row"><button type="button" id="pay-back" class="ghost">Back</button><span id="pay-status" class="status" role="status"></span></div></section>),
      # 4: earlier payments
      ~s(<section id="s-list" class="panel" hidden><h2>Payments on this key</h2><div class="scroll"><table><thead><tr>),
      ~s(<th>Started</th><th>State</th><th class="num">Asked</th><th class="num">Credited</th><th>Paid with</th><th></th></tr></thead><tbody id="list"></tbody></table></div></section>),
      ~s(</main><script nonce="),
      nonce,
      ~s(">),
      qr_js(),
      js(),
      ~s(</script></body></html>)
    ]
    |> IO.iodata_to_binary()
  end

  defp css do
    ~S"""
    .tu-main{max-width:760px;margin:0 auto;padding:16px 16px 40px;display:flex;flex-direction:column;gap:14px}
    .tu h2{margin:0 0 6px;font-size:17px}.tu .panel p{margin:0 0 12px}
    .tu label{margin-bottom:12px}.status{font-size:13px}.status.bad{color:var(--bad)}
    .bal{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between;gap:8px 20px}
    .bal .value{font-size:34px;font-weight:650;line-height:1.1}
    .amounts{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0 14px}.amt{min-width:64px}.amt.on{background:var(--accent);color:var(--accent-text)}
    .tu .fields{grid-template-columns:repeat(auto-fit,minmax(160px,1fr));margin-bottom:0}
    .quote{border:1px solid var(--line);border-radius:8px;background:var(--bg);padding:10px 12px;margin:0 0 12px;font-size:14px}
    .quote b{font-size:17px}
    .head{justify-content:space-between}
    .steps{list-style:none;display:flex;gap:6px;margin:8px 0 16px;padding:0;counter-reset:s}
    .steps li{flex:1 1 0;counter-increment:s;border-top:3px solid var(--line);padding-top:6px;font-size:12.5px;color:var(--muted)}
    .steps li::before{content:counter(s) ". "}
    .steps li.done{border-top-color:var(--ok);color:var(--ok)}.steps li.now{border-top-color:var(--accent);color:var(--text);font-weight:600}
    .steps li.bad{border-top-color:var(--bad);color:var(--bad);font-weight:600}
    .send{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-start;margin-bottom:14px}.send[hidden]{display:none}
    .qr{flex:0 0 auto;width:208px;height:208px;background:#fff;border:1px solid var(--line);border-radius:8px;padding:6px}
    .qr svg{display:block;width:100%;height:100%}
    .what{flex:1 1 260px;min-width:0;margin:0}.what dt{color:var(--muted);font-size:12.5px;margin-top:10px}.what dt:first-child{margin-top:0}
    .what dd{margin:2px 0 0;overflow-wrap:anywhere}.big{font-size:20px;font-weight:650}.addr{font-size:13.5px}
    .facts{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 14px;margin:12px 0;font-size:13px}
    .facts dt{color:var(--muted)}.facts dd{margin:0;overflow-wrap:anywhere}
    .tu td button{margin:0}.tu td,.tu th{white-space:nowrap}
    @media (max-width:520px){.qr{margin:0 auto}}
    """
  end

  @doc """
  The script's QR encoder: `qrMatrix(text)` gives the modules as rows of
  booleans (or null when the text is too long), `qrSvg(text)` an SVG element.
  """
  def qr_js do
    ~S"""
    var qrMatrix=(function(){
    "use strict";
    // version -> [codewords, error correction codewords per block, blocks, data codewords each, more blocks, data codewords each] at level M
    var V=[null,[26,10,1,16,0,0],[44,16,1,28,0,0],[70,26,1,44,0,0],[100,18,2,32,0,0],[134,24,2,43,0,0],[172,16,4,27,0,0],[196,18,4,31,0,0],[242,22,2,38,2,39],[292,22,3,36,2,37]];
    var AL=[null,[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46]];
    function mul(x,y){var z=0;for(var i=7;i>=0;i--){z=(z<<1)^((z>>>7)*0x11D);z^=((y>>>i)&1)*x}return z}
    function divisor(deg){var r=[],i,j,root=1;for(i=0;i<deg-1;i++)r.push(0);r.push(1);
      for(i=0;i<deg;i++){for(j=0;j<deg;j++){r[j]=mul(r[j],root);if(j+1<deg)r[j]^=r[j+1]}root=mul(root,2)}return r}
    function remainder(data,div){var r=div.map(function(){return 0});data.forEach(function(b){var f=b^r.shift();r.push(0);div.forEach(function(c,i){r[i]^=mul(c,f)})});return r}
    function utf8(s){var out=[],e=unescape(encodeURIComponent(s));for(var i=0;i<e.length;i++)out.push(e.charCodeAt(i));return out}
    return function(text){
      var bytes=utf8(text),v,spec,cap;
      for(v=1;v<=9;v++){spec=V[v];cap=spec[2]*spec[3]+spec[4]*spec[5];if(bytes.length+2<=cap)break}
      if(v>9)return null;
      // the bit stream: mode, length, the bytes, a terminator, padding
      var bits=[];function put(val,len){for(var i=len-1;i>=0;i--)bits.push((val>>>i)&1)}
      put(4,4);put(bytes.length,8);bytes.forEach(function(b){put(b,8)});
      put(0,Math.min(4,cap*8-bits.length));while(bits.length%8)bits.push(0);
      var data=[],i,j;for(i=0;i<bits.length;i+=8){var b=0;for(j=0;j<8;j++)b=(b<<1)|bits[i+j];data.push(b)}
      for(var pad=0xEC;data.length<cap;pad^=0xEC^0x11)data.push(pad);
      // blocks, each with its error correction, then interleaved
      var div=divisor(spec[1]),blocks=[],at=0;
      [[spec[2],spec[3]],[spec[4],spec[5]]].forEach(function(g){for(var n=0;n<g[0];n++){var d=data.slice(at,at+g[1]);at+=g[1];blocks.push({d:d,e:remainder(d,div)})}});
      var all=[],longest=Math.max(spec[3],spec[5]);
      for(i=0;i<longest;i++)blocks.forEach(function(k){if(i<k.d.length)all.push(k.d[i])});
      for(i=0;i<spec[1];i++)blocks.forEach(function(k){all.push(k.e[i])});
      // the square: modules, and which of them are not data
      var n=17+4*v,m=[],fn=[],x,y;
      for(y=0;y<n;y++){m.push([]);fn.push([]);for(x=0;x<n;x++){m[y].push(false);fn[y].push(false)}}
      function set(px,py,dark){m[py][px]=!!dark;fn[py][px]=true}
      function finder(cx,cy){for(var dy=-4;dy<=4;dy++)for(var dx=-4;dx<=4;dx++){var d=Math.max(Math.abs(dx),Math.abs(dy)),px=cx+dx,py=cy+dy;if(px>=0&&px<n&&py>=0&&py<n)set(px,py,d!==2&&d!==4)}}
      function format(mask){var d=mask,rem=d,k;for(k=0;k<10;k++)rem=(rem<<1)^((rem>>>9)*0x537);var f=((d<<10)|rem)^0x5412;function bit(q){return (f>>>q)&1}
        for(k=0;k<=5;k++)set(8,k,bit(k));set(8,7,bit(6));set(8,8,bit(7));set(7,8,bit(8));for(k=9;k<15;k++)set(14-k,8,bit(k));
        for(k=0;k<8;k++)set(n-1-k,8,bit(k));for(k=8;k<15;k++)set(8,n-15+k,bit(k));set(8,n-8,1)}
      for(i=0;i<n;i++){set(6,i,i%2===0);set(i,6,i%2===0)}
      finder(3,3);finder(n-4,3);finder(3,n-4);
      var al=AL[v],last=al.length-1;
      for(i=0;i<al.length;i++)for(j=0;j<al.length;j++){if((i===0&&j===0)||(i===0&&j===last)||(i===last&&j===0))continue;
        for(var ay=-2;ay<=2;ay++)for(var ax=-2;ax<=2;ax++)set(al[i]+ax,al[j]+ay,Math.max(Math.abs(ax),Math.abs(ay))!==1)}
      format(0);
      if(v>=7){var rem=v;for(i=0;i<12;i++)rem=(rem<<1)^((rem>>>11)*0x1F25);var vb=(v<<12)|rem;
        for(i=0;i<18;i++){var a=n-11+i%3,c=Math.floor(i/3),on=(vb>>>i)&1;set(a,c,on);set(c,a,on)}}
      // the codewords, in the zigzag from the bottom right
      var k=0;
      for(var right=n-1;right>=1;right-=2){if(right===6)right=5;
        for(var vert=0;vert<n;vert++)for(j=0;j<2;j++){x=right-j;y=((right+1)&2)===0?n-1-vert:vert;
          if(!fn[y][x]&&k<all.length*8){m[y][x]=((all[k>>>3]>>>(7-(k&7)))&1)===1;k++}}}
      // the mask that leaves the fewest long runs and blocks
      function masked(mask,px,py){switch(mask){case 0:return (px+py)%2===0;case 1:return py%2===0;case 2:return px%3===0;case 3:return (px+py)%3===0;
        case 4:return (Math.floor(px/3)+Math.floor(py/2))%2===0;case 5:return px*py%2+px*py%3===0;case 6:return (px*py%2+px*py%3)%2===0;default:return ((px+py)%2+px*py%3)%2===0}}
      function apply(mask){for(var py=0;py<n;py++)for(var px=0;px<n;px++)if(!fn[py][px]&&masked(mask,px,py))m[py][px]=!m[py][px]}
      function penalty(){var p=0,dark=0,px,py,run,col;
        for(py=0;py<n;py++){run=1;for(px=1;px<n;px++){if(m[py][px]===m[py][px-1]){run++;if(run===5)p+=3;else if(run>5)p++}else run=1}}
        for(px=0;px<n;px++){run=1;for(py=1;py<n;py++){if(m[py][px]===m[py-1][px]){run++;if(run===5)p+=3;else if(run>5)p++}else run=1}}
        for(py=0;py<n-1;py++)for(px=0;px<n-1;px++){col=m[py][px];if(col===m[py][px+1]&&col===m[py+1][px]&&col===m[py+1][px+1])p+=3}
        for(py=0;py<n;py++)for(px=0;px<n;px++)if(m[py][px])dark++;
        return p+Math.floor(Math.abs(dark*20-n*n*10)/(n*n))*10}
      var best=0,least=Infinity;
      for(i=0;i<8;i++){apply(i);format(i);var pen=penalty();if(pen<least){least=pen;best=i}apply(i)}
      apply(best);format(best);
      return m}})();
    function qrSvg(text){
      var m=qrMatrix(text);if(!m)return null;
      var ns='http://www.w3.org/2000/svg',n=m.length,q=4,svg=document.createElementNS(ns,'svg'),bg=document.createElementNS(ns,'rect'),p=document.createElementNS(ns,'path'),d='';
      svg.setAttribute('viewBox','0 0 '+(n+2*q)+' '+(n+2*q));svg.setAttribute('shape-rendering','crispEdges');
      bg.setAttribute('width','100%');bg.setAttribute('height','100%');bg.setAttribute('fill','#fff');svg.appendChild(bg);
      for(var y=0;y<n;y++)for(var x=0;x<n;x++)if(m[y][x])d+='M'+(x+q)+' '+(y+q)+'h1v1h-1z';
      p.setAttribute('d',d);p.setAttribute('fill','#000');svg.appendChild(p);return svg}
    """
  end

  defp js do
    ~S"""
    (function(){
    "use strict";
    var key=null,assets=[],quoted=null,current=null,timer=null,tick=null,busy=false;
    var END={settled:1,refunded:1,failed:1,expired:1};
    function $(id){return document.getElementById(id)}
    function el(tag,cls,text){var e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
    function clear(n){while(n.firstChild)n.removeChild(n.firstChild)}
    function show(id,on){$(id).hidden=!on}
    function usd(n){return n==null?'—':'$'+Number(n).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2})}
    function say(id,text,bad){var s=$(id);s.textContent=text||'';s.className='status'+(bad?' bad':'')}
    function when(iso){var d=new Date(iso);return isNaN(d)?String(iso||''):d.toLocaleString()}
    function api(method,path,body){
      return fetch(path,{method:method,credentials:'omit',cache:'no-store',headers:{'content-type':'application/json',accept:'application/json',authorization:'Bearer '+key},body:body==null?null:JSON.stringify(body)})
        .then(function(r){return r.text().then(function(t){var j=null;try{j=t?JSON.parse(t):null}catch(e){}
          if(!r.ok){var er=new Error(j&&j.error&&j.error.message?j.error.message:'Request failed (HTTP '+r.status+')');er.status=r.status;throw er}return j})})}
    function stateClass(s){return s==='settled'?'ok':s==='awaiting_deposit'?'info':s==='processing'?'warn':'bad'}
    function stateWord(s){return {awaiting_deposit:'waiting for the deposit',processing:'processing',settled:'credited',refunded:'refunded',failed:'failed',expired:'expired'}[s]||s}

    // -- the key, the balance, the list ---------------------------------------
    function load(){return api('GET','/v1/payments').then(function(d){renderBalance(d.credits);renderList(d.payments||[]);return d})}
    function renderBalance(c){
      show('s-balance',true);
      if(!c){$('balance').textContent='—';$('bal-sub').textContent='This key is not prepaid, so a payment cannot be credited to it. Ask the operator of this gateway.';show('s-new',false);return false}
      $('balance').textContent=usd(c.balance_usd);$('bal-sub').textContent=usd(c.burned_usd)+' used so far';return true}
    function renderList(list){
      var body=$('list');clear(body);show('s-list',list.length>0);
      list.forEach(function(p){var tr=el('tr'),st=el('td'),open=el('td'),b=el('button','small ghost',END[p.status]?'Details':'Open');
        tr.appendChild(el('td',null,when(p.created_at)));st.appendChild(el('span','pill '+stateClass(p.status),stateWord(p.status)));tr.appendChild(st);
        tr.appendChild(el('td','num',usd(p.amount_usd)));tr.appendChild(el('td','num',p.credited_usd==null?'—':usd(p.credited_usd)));
        tr.appendChild(el('td',null,(p.deposit.amount||'')+' '+(p.deposit.symbol||'')+' on '+(p.deposit.chain||'')));
        b.type='button';b.addEventListener('click',function(){openPayment(p)});open.appendChild(b);tr.appendChild(open);body.appendChild(tr)})}
    $('f-key').addEventListener('submit',function(ev){
      ev.preventDefault();if(busy)return;var v=$('key').value.trim();if(!v)return;key=v;busy=true;say('key-status','Checking…');
      load().then(function(d){
        $('key').value='';show('s-key',false);show('forget',true);$('who').textContent='key ending '+v.slice(-4);say('key-status','');
        if(!d.credits)return;show('s-new',true);
        return api('GET','/v1/payments/assets').then(function(a){assets=a.assets||[];renderChains()})})
      .catch(function(e){key=null;say('key-status',e.status===401?'This gateway does not know that key.':e.status===404?'Payments are not switched on at this gateway.':e.message,true)})
      .finally(function(){busy=false})});
    $('forget').addEventListener('click',function(){location.reload()});

    // -- a new payment ----------------------------------------------------------
    function renderChains(){
      var sel=$('chain'),seen={},names=[];clear(sel);
      assets.forEach(function(a){if(!seen[a.chain]){seen[a.chain]=1;names.push(a.chain)}});names.sort();
      names.forEach(function(c){var o=el('option',null,c);o.value=c;sel.appendChild(o)});
      if(seen.near)sel.value='near';renderAssets()}
    function renderAssets(){
      var sel=$('asset'),chain=$('chain').value;clear(sel);
      assets.filter(function(a){return a.chain===chain}).sort(function(a,b){return a.symbol<b.symbol?-1:a.symbol>b.symbol?1:0})
        .forEach(function(a){var o=el('option',null,a.symbol);o.value=a.asset;sel.appendChild(o)});
      unquote()}
    function unquote(){quoted=null;show('quote',false);show('pay-go',false);$('quote-go').className='';say('new-status','')}
    function ask(){return {amount_usd:Number($('usd').value),asset:$('asset').value,refund_to:$('refund').value.trim()}}
    $('chain').addEventListener('change',renderAssets);
    ['asset','usd','refund'].forEach(function(id){$(id).addEventListener('input',function(){unquote();if(id==='usd')marks()})});
    function marks(){Array.prototype.forEach.call(document.querySelectorAll('.amt'),function(b){b.classList.toggle('on',Number(b.dataset.usd)===Number($('usd').value))})}
    Array.prototype.forEach.call(document.querySelectorAll('.amt'),function(b){b.addEventListener('click',function(){$('usd').value=b.dataset.usd;unquote();marks()})});
    $('f-new').addEventListener('submit',function(ev){
      ev.preventDefault();if(busy)return;var a=ask();busy=true;say('new-status','Asking for a quote…');
      api('POST','/v1/payments/quote',a).then(function(q){
        quoted=a;var box=$('quote');clear(box);show('quote',true);
        box.appendChild(document.createTextNode(usd(q.amount_usd)+' of credit takes '));box.appendChild(el('b',null,q.amount+' '+q.symbol));
        box.appendChild(document.createTextNode(' on '+q.chain+(q.deposit_usd?' (about '+usd(q.deposit_usd)+')':'')+(q.time_estimate_s?', and about '+q.time_estimate_s+' seconds after it arrives':'')+'. The exact amount is fixed when the payment starts.'));
        show('pay-go',true);$('quote-go').className='ghost';say('new-status','')})
      .catch(function(e){unquote();say('new-status',e.message,true)}).finally(function(){busy=false})});
    $('pay-go').addEventListener('click',function(){
      if(busy||!quoted)return;busy=true;say('new-status','Starting the payment…');
      api('POST','/v1/payments',quoted).then(function(p){unquote();openPayment(p);load()})
      .catch(function(e){say('new-status',e.message,true)}).finally(function(){busy=false})});

    // -- one payment --------------------------------------------------------------
    function openPayment(p){show('s-new',false);show('s-pay',true);renderPayment(p);$('s-pay').scrollIntoView({block:'start'});watch()}
    function step(id,cls){$(id).className=cls||''}
    function renderPayment(p){
      var was=current&&current.id===p.id?current.status:null;current=p;
      var s=p.status,d=p.deposit,pill=$('pay-pill');clear(pill);pill.appendChild(el('span','pill '+stateClass(s),stateWord(s)));
      step('st-1',s==='awaiting_deposit'?'now':s==='expired'?'bad':'done');
      step('st-2',s==='processing'?'now':s==='settled'?'done':(s==='failed'||s==='refunded')?'bad':'');
      step('st-3',s==='settled'?(p.credited_usd==null?'bad':'done'):'');
      show('pay-send',s==='awaiting_deposit');
      if(s==='awaiting_deposit'){
        $('p-amount').textContent=d.amount+' '+d.symbol;$('p-amount-raw').textContent=d.amount;$('p-chain').textContent=d.chain+', as '+d.symbol;
        $('p-address').textContent=d.address;show('p-memo-l',!!d.memo);show('p-memo-d',!!d.memo);$('p-memo').textContent=d.memo||'';
        var box=$('qr');if(box.dataset.for!==d.address){clear(box);var svg=qrSvg(d.address);if(svg)box.appendChild(svg);box.hidden=!svg;box.dataset.for=d.address}
        countdown()}
      $('pay-note').textContent=
        s==='awaiting_deposit'?'Send it from a wallet of your own, in one transfer. This page notices when it arrives; you can also close it and come back with the key.'+(d.memo?' The memo is required: a transfer without it is not recognized.':''):
        s==='processing'?'The deposit arrived and is being swapped. This usually takes under a minute.':
        s==='settled'?(p.credited_usd==null?'The payment arrived but could not be credited to this key. Contact the operator of this gateway.':usd(p.credited_usd)+' of credit was added to this key.'):
        s==='refunded'?'The payment was not completed and the funds were sent back to the refund address.':
        s==='failed'?'The payment could not be completed.':'Nothing arrived before the deadline. Nothing was credited; start a new payment.';
      var f=$('pay-facts');clear(f);function row(k,v){if(v==null||v==='')return;f.appendChild(el('dt',null,k));f.appendChild(el('dd',null,String(v)))}
      row('Credit asked for',usd(p.amount_usd));row('Note',p.detail);row('Refund address',p.refund_to);
      if(p.tx&&p.tx.length)row('Transactions',p.tx.join(', '));row('Payment id',p.id);
      if(was&&was!==s&&END[s])load()}
    function countdown(){
      if(tick)clearInterval(tick);
      function draw(){if(!current||current.status!=='awaiting_deposit'){clearInterval(tick);tick=null;return}
        var left=Math.round((new Date(current.deadline)-Date.now())/1000),t=when(current.deadline);
        $('p-deadline').textContent=isNaN(left)?t:left>0?t+' ('+(left>=3600?Math.floor(left/3600)+' h ':'')+Math.floor(left%3600/60)+' min '+(left<3600?left%60+' s ':'')+'left)':t+' (passed)'}
      draw();tick=setInterval(draw,1000)}
    function watch(){
      if(timer)clearTimeout(timer);timer=null;if(!current||END[current.status])return;
      timer=setTimeout(function(){var id=current.id;
        api('GET','/v1/payments/'+encodeURIComponent(id)).then(function(p){if(current&&current.id===id){renderPayment(p);say('pay-status','')}})
        .catch(function(e){say('pay-status','Could not check just now: '+e.message,true)}).finally(watch)},4000)}
    document.addEventListener('visibilitychange',function(){if(!document.hidden&&current&&!END[current.status])watch()});
    $('pay-back').addEventListener('click',function(){if(timer)clearTimeout(timer);timer=null;current=null;show('s-pay',false);show('s-new',true);load()});
    Array.prototype.forEach.call(document.querySelectorAll('.copy'),function(b){b.addEventListener('click',function(){
      var text=$(b.dataset.copy).textContent;if(!navigator.clipboard)return;navigator.clipboard.writeText(text).then(function(){var old=b.textContent;b.textContent='Copied';setTimeout(function(){b.textContent=old},1200)})})});
    })();
    """
  end
end
