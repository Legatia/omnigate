defmodule OmnigateControl.PrivateChatPage do
  @moduledoc """
  The "Private chat" page of the dashboard: one self-contained HTML page,
  built like the dashboard itself (inline style and script under a
  per-response nonce, nothing loaded from elsewhere, all data written with
  `textContent`).

  Three panels: the conversation; what the provider was sent for the last
  message, as the data plane's dry run produced it; and what was verified
  about the machine behind the chosen model. The data comes from
  `GET /admin/private-chat/state`, `POST /admin/private-chat/send` and
  `POST /admin/attestations/verify`; see `OmnigateControl.PrivateChat`.
  """
  alias OmnigateControl.Dashboard

  @doc "The page for a CSRF token and a CSP nonce."
  def page(csrf, nonce) do
    [
      ~s(<!doctype html><html lang="en"><head><meta charset="utf-8">),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
      ~s(<meta name="csrf" content="),
      Plug.HTML.html_escape(csrf),
      ~s("><link rel="icon" href="data:,">),
      ~s(<title>Private chat · omnigate</title><style nonce="),
      nonce,
      ~s(">),
      Dashboard.css(),
      css(),
      ~s(</style></head><body class="pc">),
      ~s(<header class="top"><div class="brand">omnigate <span>private chat</span></div>),
      ~s(<nav aria-label="Pages"><a href="/">Dashboard</a><a href="/private-chat" aria-current="page">Private chat</a></nav>),
      ~s(<div class="right"><span id="gateway" class="muted"></span>),
      ~s(<form method="post" action="/logout"><input type="hidden" name="_csrf" value="),
      Plug.HTML.html_escape(csrf),
      ~s("><button type="submit" class="ghost">Sign out</button></form></div></header>),
      ~s(<main class="pc-main">),
      ~s(<div class="bar panel"><label class="pick">Model<select id="model"></select></label>),
      ~s(<label class="switch"><input type="checkbox" id="redact" checked><span>Redact personal data and secrets</span></label>),
      ~s(<label class="switch"><input type="checkbox" id="attested" checked><span>Attested providers only</span></label>),
      ~s(<span id="route" class="muted route"></span>),
      ~s(<button type="button" id="reset" class="ghost">New conversation</button></div>),
      ~s(<div class="cols">),
      # 1: the conversation
      ~s(<section class="panel col" aria-labelledby="h-chat"><h2 id="h-chat">Conversation</h2>),
      ~s(<p class="hint muted">What you type and what you read, with your own values in it.</p>),
      ~s(<div id="log" class="log" aria-live="polite"><p id="log-empty" class="muted empty">Nothing sent yet. Try a message with an e-mail address, a phone number or a card number in it.</p></div>),
      ~s(<p id="need-key" class="notice" hidden></p>),
      ~s(<form id="send" autocomplete="off"><textarea id="text" rows="3" maxlength="8000" placeholder="Write a message" required></textarea>),
      ~s(<div class="row"><button type="submit" id="go">Send</button><button type="button" id="sample" class="ghost">Fill in an example</button>),
      ~s(<span id="status" class="muted" role="status"></span></div></form></section>),
      # 2: what left
      ~s(<section class="panel col" aria-labelledby="h-wire"><h2 id="h-wire">What left this machine</h2>),
      ~s(<p class="hint muted">The last message as the provider is sent it. Produced by the gateway's own redaction, in a dry run of the same request.</p>),
      ~s(<div id="wire-meta" class="chips"></div>),
      ~s(<div id="wire" class="wire mono"><p class="muted empty">Send a message to see it here.</p></div>),
      ~s(<div id="outcome" class="outcome" hidden></div></section>),
      # 3: verified
      ~s(<section class="panel col" aria-labelledby="h-proof"><div class="row head"><h2 id="h-proof">Verified</h2><span id="verdict"></span></div>),
      ~s(<p id="proof-hint" class="hint muted"></p>),
      ~s(<ol id="checks" class="checks"></ol>),
      ~s(<div class="row"><button type="button" id="verify" class="ghost" hidden>Verify again now</button><span id="verify-status" class="muted" role="status"></span></div>),
      # The receipt of the last answer (`OmnigateControl.Receipts`).
      ~s(<div id="answer" class="answer" hidden><h3>This answer</h3><ol id="answer-checks" class="checks"></ol>),
      ~s(<div class="row"><button type="button" id="receipt" class="ghost" hidden>Download receipt</button><span id="answer-status" class="muted" role="status"></span></div></div>),
      ~s(<details id="limits" class="limits"><summary>What this does not show</summary><ul>),
      ~s(<li>Whether the measured software is software to trust: that takes an allowlist of measurements \(<code>attestation.measurements</code>, empty unless set\) and a check of where its images were built, which is not done.</li>),
      ~s(<li>That the connection a request travels on ends inside the attested machine: the data plane does not bind its TLS connections to the report.</li>),
      ~s(<li>Which machine produced an answer: machines serving the same model share one signing key, and a signature by the provider's gateway \(every streamed answer\) covers what the gateway passed on, not what the model produced.</li>),
      ~s(</ul><p class="muted">Details: docs/attestation.md.</p></details></section>),
      ~s(</div></main><script nonce="),
      nonce,
      ~s(">),
      js(),
      ~s(</script></body></html>)
    ]
    |> IO.iodata_to_binary()
  end

  defp css do
    ~S"""
    .pc-main{max-width:1880px;padding:12px 24px 24px}
    .bar{display:flex;flex-wrap:wrap;align-items:center;gap:10px 22px;margin-top:8px}
    .pick{display:flex;align-items:center;gap:10px}.pick select{margin:0;min-width:240px;width:auto}
    .switch{display:flex;align-items:center;gap:8px;font-weight:500;font-size:13.5px;cursor:pointer}
    .switch input{display:inline-block;width:16px;height:16px;margin:0;accent-color:var(--accent)}
    .route{flex:1 1 200px;font-size:12.5px}
    .cols{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(0,1fr) minmax(0,1.05fr);gap:14px;margin-top:14px;align-items:start}
    .col{display:flex;flex-direction:column;min-height:calc(100vh - 190px)}
    .col h2{margin:0 0 2px;font-size:16px}.hint{margin:0 0 12px;font-size:12.5px}
    .head{justify-content:space-between}
    .log{flex:1 1 auto;display:flex;flex-direction:column;gap:10px;overflow-y:auto;max-height:calc(100vh - 400px);min-height:160px;padding:2px}
    .msg{max-width:92%;border-radius:10px;padding:9px 12px;white-space:pre-wrap;overflow-wrap:anywhere;font-size:14.5px;line-height:1.5}
    .msg.user{align-self:flex-end;background:var(--accent);color:var(--accent-text)}
    .msg.assistant{align-self:flex-start;background:var(--bg);border:1px solid var(--line)}
    .msg.refused{align-self:stretch;max-width:100%;background:var(--bad-bg);color:var(--bad);border:1px solid var(--bad)}
    .msg .who{display:block;font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;opacity:.75;margin-bottom:2px}
    textarea{display:block;width:100%;margin:12px 0 10px;font:inherit;font-size:14.5px;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:9px 11px;resize:vertical}
    textarea:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    .notice{margin:10px 0 0;padding:9px 12px;border-radius:8px;background:var(--warn-bg);color:var(--warn);font-size:13px}
    .chips{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px;min-height:22px}
    .wire{flex:1 1 auto;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:12px;white-space:pre-wrap;overflow-wrap:anywhere;overflow-y:auto;max-height:calc(100vh - 420px);min-height:160px;font-size:13px;line-height:1.6}
    .wire .role{display:block;color:var(--muted);font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;margin-top:10px}
    .wire .role:first-child{margin-top:0}
    .ph{background:var(--warn-bg);color:var(--warn);border-radius:4px;padding:0 4px;font-weight:600}
    .wire .empty,.log .empty{text-align:left;padding:8px 2px;white-space:normal;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
    .outcome{margin-top:12px;border:1px solid var(--line);border-radius:8px;padding:10px 12px;font-size:13px}
    .outcome.bad{border-color:var(--bad);background:var(--bad-bg);color:var(--bad)}
    .outcome dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:3px 12px;margin:0}
    .outcome dt{color:var(--muted)}.outcome.bad dt{color:inherit;opacity:.8}.outcome dd{margin:0;overflow-wrap:anywhere}
    .checks{list-style:none;margin:0 0 12px;padding:0;display:flex;flex-direction:column;gap:6px}
    .checks li{border:1px solid var(--line);border-radius:8px;background:var(--bg)}
    .checks details>summary{display:flex;align-items:flex-start;gap:10px;padding:8px 10px;cursor:pointer;list-style:none}
    .checks details>summary::-webkit-details-marker{display:none}
    .mark{flex:0 0 20px;width:20px;height:20px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;margin-top:1px}
    .mark.ok{background:var(--ok-bg);color:var(--ok)}.mark.bad{background:var(--bad-bg);color:var(--bad)}.mark.off{background:var(--off-bg);color:var(--off)}
    .what{flex:1 1 auto;min-width:0}.what b{display:block;font-weight:600;font-size:13.5px}.what span{display:block;color:var(--muted);font-size:12.5px;overflow-wrap:anywhere}
    .raw{margin:0;padding:8px 10px 10px 40px;border-top:1px solid var(--line);display:grid;grid-template-columns:max-content minmax(0,1fr);gap:3px 10px;font-size:12px}
    .raw dt{color:var(--muted)}.raw dd{margin:0;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;overflow-wrap:anywhere}
    .answer{margin-top:6px;padding-top:12px;border-top:1px solid var(--line)}.answer h3{margin:0 0 8px;font-size:14px}
    .limits{font-size:12.5px;margin-top:10px}.limits summary{cursor:pointer;color:var(--muted)}.limits ul{margin:8px 0;padding-left:18px}.limits li{margin-bottom:5px}
    .limits code{font-size:12px}
    nav a[aria-current=page]{border-bottom-color:var(--accent)}
    @media (max-width:1100px){.cols{grid-template-columns:1fr}.col{min-height:0}.log,.wire{max-height:none}}
    """
  end

  defp js do
    ~S"""
    (function(){
    "use strict";
    var csrf=document.querySelector('meta[name=csrf]').content,state=null,history=[],sending=false,lastPair=null;
    var SAMPLE='Draft a short reply to Dana Reyes (dana.reyes@example.com, +1 (415) 555-0134). Her card 4111 1111 1111 1111 was charged twice for order 88213; say the second charge is refunded within 3 days.';
    function $(id){return document.getElementById(id)}
    function el(tag,cls,text){var e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
    function clear(n){while(n.firstChild)n.removeChild(n.firstChild)}
    function pill(text,cls){return el('span','pill '+cls,text)}
    function cap(s){s=String(s||'');return s.charAt(0).toUpperCase()+s.slice(1)}
    function short(s,n){s=String(s||'');n=n||16;return s.length>n?s.slice(0,n)+'…':s}
    function ago(s){if(s==null)return 'never';if(s<60)return s+' s ago';if(s<3600)return Math.round(s/60)+' min ago';return Math.round(s/3600)+' h ago'}
    function api(method,path,body){
      return fetch(path,{method:method,credentials:'same-origin',headers:{'content-type':'application/json','x-csrf-token':csrf,accept:'application/json'},body:body==null?null:JSON.stringify(body)})
        .then(function(r){return r.text().then(function(t){var j=null;try{j=t?JSON.parse(t):null}catch(e){}
          if(!r.ok)throw new Error(j&&j.error&&j.error.message?j.error.message:'Request failed (HTTP '+r.status+')');return j})})}

    function route(){if(!state)return null;var name=$('model').value;for(var i=0;i<state.models.length;i++)if(state.models[i].model===name)return state.models[i];return state.models[0]||null}
    // The target the page describes: the first attested one, else the first.
    function target(r){if(!r)return null;for(var i=0;i<r.targets.length;i++)if(r.targets[i].attested)return r.targets[i];return r.targets[0]||null}

    function renderModels(){
      var sel=$('model'),keep=sel.value;clear(sel);
      state.models.forEach(function(m){var t=target(m),o=el('option',null,m.model+(t&&t.attested?(t.attestation&&t.attestation.verified?'  ·  attested, verified':'  ·  attested, not verified'):'  ·  not attested'));o.value=m.model;sel.appendChild(o)});
      if(keep)sel.value=keep;
      if(!sel.value&&state.models.length){var best=state.models.filter(function(m){var t=target(m);return t&&t.attested&&t.attestation&&t.attestation.verified})[0]||state.models[0];sel.value=best.model}
    }

    function check(ok,title,line,raw){
      var li=el('li'),d=el('details'),s=el('summary'),w=el('div','what');
      s.appendChild(el('span','mark '+(ok===true?'ok':ok===false?'bad':'off'),ok===true?'✓':ok===false?'✕':'–'));
      w.appendChild(el('b',null,title));w.appendChild(el('span',null,line));s.appendChild(w);d.appendChild(s);
      if(raw&&raw.length){var dl=el('dl','raw');raw.forEach(function(p){dl.appendChild(el('dt',null,p[0]));dl.appendChild(el('dd',null,p[1]==null?'—':String(p[1])))});d.appendChild(dl)}
      li.appendChild(d);return li}

    function renderProof(){
      var r=route(),t=target(r),list=$('checks'),v=$('verdict'),hint=$('proof-hint'),btn=$('verify');
      var open={};Array.prototype.forEach.call(list.querySelectorAll('details'),function(d,i){if(d.open)open[i]=true});
      clear(list);clear(v);btn.hidden=true;
      $('route').textContent=r?('goes to '+r.targets.map(function(x){return x.upstream+' / '+x.model}).join('  →  ')):'';
      var need=$('need-key');need.hidden=true;
      if(t&&!t.key_present){need.hidden=false;need.textContent='No provider key: '+t.key_env+' is not set in the control plane\'s environment, so '+t.upstream+' will refuse a chat. The verification on the right needs no key. Set '+t.key_env+' for both processes and restart them to chat.'}
      if(!t){hint.textContent='No text model is configured.';return}
      if(!t.attested){
        v.appendChild(pill('not attested','off'));
        hint.textContent=t.upstream+' ('+(t.host||'')+') makes no claim about the machine it runs on that this gateway can check. With "Attested providers only" switched on, a request for this model is refused instead of sent.';
        list.appendChild(check(null,'No attestation','This upstream has no "attestation" setting in the config.',[['upstream',t.upstream],['model',t.model],['host',t.host]]));return}
      var a=t.attestation;btn.hidden=false;lastPair={upstream:t.upstream,model:t.model};
      if(!a||a.state==='pending'){v.appendChild(pill('checking…','info'));hint.textContent='The first check of '+t.upstream+' / '+t.model+' is under way.';return}
      var e=a.evidence,g=e&&e.gateway,m=e&&e.models&&e.models[0],ok=a.verified;
      v.appendChild(pill(ok?'verified':'not verified',ok?'ok':'bad'));
      hint.textContent=ok
        ?(t.upstream+' / '+t.model+' at '+(t.host||'')+': checked '+ago(a.age_s)+', '+(a.checks===1?'1 check':a.checks+' checks')+' so far, again at least every '+Math.round(a.max_age_s/2)+' s. Requests are sent only while this holds.')
        :(t.upstream+' / '+t.model+' at '+(t.host||'')+': '+(a.reason||'not verified')+'. No request is sent to it.');
      if(!ok){list.appendChild(check(false,'Not verified',a.reason||'The last verification is too old.',[['reason code',a.reason_code],['last attempt',a.last_attempt_at?new Date(a.last_attempt_at*1000).toISOString():null],['checks so far',a.checks],['last pass',a.checked_at?new Date(a.checked_at*1000).toISOString():'never']]));
        if(!e)return}
      var both=function(f){return [['gateway',f(g)]].concat(m?[['model',f(m)]]:[])};
      list.appendChild(check(ok,'Genuine Intel TDX hardware','The provider\'s gateway'+(m?' and the model\'s machine':'')+' each sent a quote signed by an Intel processor; the certificate chain ends at Intel\'s root, pinned in the gateway. Nothing in it is revoked.',
        both(function(x){return 'TDX quote v'+x.quote_version+', Intel collateral valid until '+new Date(x.collateral_expires_at*1000).toISOString()})));
      list.appendChild(check(ok,'Platform patch status: '+g.tcb_status+(m&&m.tcb_status!==g.tcb_status?' / '+m.tcb_status:''),'Intel\'s current list of patch levels says so. Accepted here: '+a.policy.accepted_tcb.join(', ')+'.',
        both(function(x){return x.tcb_status+(x.advisory_ids&&x.advisory_ids.length?' ('+x.advisory_ids.join(', ')+')':'')})));
      list.appendChild(check(ok,'Not in debug mode','A machine in debug mode can be read from outside; these are not.',both(function(x){return 'TD attributes '+x.td_attributes})));
      list.appendChild(check(ok,'Fresh: answers our nonce','The quotes contain the random number this gateway made up for this check, so they were produced just now, for us.',
        [['nonce',e.nonce],['checked at',new Date(e.verified_at*1000).toISOString()]].concat(both(function(x){return 'report data '+x.report_data}))));
      list.appendChild(check(ok,'Signing key bound to the machine','The quote names the key the machine signs with: '+g.signing_algo+':'+short(g.signing_address)+(m?' (gateway), '+m.signing_algo+':'+short(m.signing_address)+' (model)':'')+'.',
        both(function(x){return x.signing_algo+':'+x.signing_address})));
      list.appendChild(check(ok,'Configuration is the one measured','The software configuration the provider shows hashes to the value the processor measured at start.',
        both(function(x){return 'app_compose sha256 '+x.app_compose_sha256}).concat(both(function(x){return 'MRTD '+x.mr_td}))));
      list.appendChild(check(ok,'Event log replays to the measured value','Replaying the boot events gives the register value in the quote (RTMR3).',both(function(x){return 'RTMR3 '+x.rtmr3})));
      if(m){var gpu=m.gpu;list.appendChild(check(gpu==='verified'?ok:null,'GPU evidence: '+(gpu==='verified'?'accepted by NVIDIA':gpu==='absent'?'none sent':'not checked'),
        gpu==='verified'?'The model\'s GPUs sent evidence bound to the same nonce, and NVIDIA\'s attestation service accepted it.':gpu==='absent'?'The model report carries no GPU evidence.':'The setting "gpu" is "skip".',
        [['setting',a.policy.gpu]]))}
      Array.prototype.forEach.call(list.querySelectorAll('details'),function(d,i){if(open[i])d.open=true});
    }

    function renderAll(){if(!state)return;$('gateway').textContent='gateway '+state.gateway_url;renderModels();renderProof()}
    function load(){return api('GET','/admin/private-chat/state').then(function(s){state=s;renderAll()}).catch(function(e){$('status').textContent=e.message})}

    function bubble(role,text,cls){var m=el('div','msg '+(cls||role));m.appendChild(el('span','who',role==='user'?'You':cls==='refused'?'Gateway':'Answer'));m.appendChild(document.createTextNode(text));
      var log=$('log'),empty=$('log-empty');if(empty)empty.remove();log.appendChild(m);log.scrollTop=log.scrollHeight;return m}

    // The body the provider is sent, message by message, placeholders marked.
    function renderWire(dry){
      var box=$('wire'),meta=$('wire-meta');clear(box);clear(meta);
      if(!dry||!dry.ok){box.appendChild(el('p','muted empty',dry&&dry.error?dry.error:'No dry run.'));return}
      var total=0;Object.keys(dry.replaced).forEach(function(k){var n=dry.replaced[k];if(n){total+=n;meta.appendChild(pill(n+' '+k,'warn'))}});
      if(!total)meta.appendChild(pill(dry.protections.indexOf('redact')>=0?'nothing to redact':'redaction off','off'));
      if(dry.protections)meta.appendChild(pill(dry.protections,'info'));
      var parsed=null;try{parsed=JSON.parse(dry.body)}catch(e){}
      var msgs=parsed&&parsed.messages;
      if(!Array.isArray(msgs)){mark(box,dry.body);return}
      msgs.forEach(function(m){box.appendChild(el('span','role',m.role));mark(box,typeof m.content==='string'?m.content:JSON.stringify(m.content))});
      box.scrollTop=box.scrollHeight}
    function mark(box,text){var re=/\[[A-Z]+_\d+\]/g,at=0,m;while((m=re.exec(text))){if(m.index>at)box.appendChild(document.createTextNode(text.slice(at,m.index)));box.appendChild(el('span','ph',m[0]));at=m.index+m[0].length}
      if(at<text.length)box.appendChild(document.createTextNode(text.slice(at)));box.appendChild(document.createTextNode('\n'))}

    function renderOutcome(asked,res){
      var box=$('outcome');clear(box);box.hidden=false;box.className='outcome'+(res.ok?'':' bad');
      var dl=el('dl');function row(k,v){if(v==null||v==='')return;dl.appendChild(el('dt',null,k));dl.appendChild(el('dd',null,String(v)))}
      row('Asked for',asked);
      if(res.ok){row('Answered by',res.upstream+(res.model?' ('+res.model+')':''));row('Attestation',res.attestation||'none: this provider is not attested');row('Applied',res.privacy);
        if(res.usage&&res.usage.prompt_tokens!=null)row('Tokens',res.usage.prompt_tokens+' in, '+res.usage.completion_tokens+' out')}
      else{row('Refused',res.error.code+' (HTTP '+res.status+')');row('Why',cap(res.error.message));if(res.error.attempts&&res.error.attempts.length)row('Targets',res.error.attempts.map(function(a){return a.upstream+': '+a.outcome}).join(', '));row('Sent to a provider',res.upstream?'yes, '+res.upstream:'no')}
      row('Request id',res.request_id);box.appendChild(dl)}

    // The receipt of the answer just shown: the provider's signature over
    // the exact bytes, checked by the control plane a moment after the answer.
    var receiptOf=null,receiptTimer=null;
    function answerProof(res){
      var box=$('answer'),list=$('answer-checks'),st=$('answer-status'),dl=$('receipt');
      if(receiptTimer){clearTimeout(receiptTimer);receiptTimer=null}
      clear(list);dl.hidden=true;receiptOf=null;st.textContent='';
      if(!res||!res.ok||!res.attestation||!res.request_id){box.hidden=true;return}
      box.hidden=false;var id=res.request_id,tries=0;
      list.appendChild(check(null,'Signature: being checked','The provider is asked for its signature over this request and this answer.',[['request id',id]]));
      (function poll(){
        api('GET','/admin/receipts/'+encodeURIComponent(id)).then(function(r){
          if(r.verdict==='pending')throw new Error('pending');showReceipt(r)})
        .catch(function(){tries++;
          if(tries<30){receiptTimer=setTimeout(poll,1000)}
          else{clear(list);list.appendChild(check(null,'No receipt','The gateway has no receipt for this answer after 30 seconds. It is not verified.',[['request id',id]]))}})})()}
    function showReceipt(r){
      var list=$('answer-checks'),sig=r.signature,ok=r.verdict==='verified',dl=$('receipt');clear(list);
      var att=r.attestation,signer=att&&att.reports?att.reports.filter(function(x){return x.signed_this_answer})[0]:null;
      var raw=[['request sha256',r.request_sha256],['response sha256',r.response_sha256],['completion id',r.completion_id]];
      if(sig)raw=raw.concat([['signed text',sig.text],['signature',sig.signature],['key',(sig.signing_algo||'')+':'+(sig.signing_address||'')],['signed by',sig.kind]]);
      if(att)raw.push(['matched to evidence verified at',new Date(att.verified_at*1000).toISOString()]);
      if(ok){
        var model=sig.kind==='provider_tee';
        list.appendChild(check(true,model?'Signed by the model\'s machine':'Signed by the provider\'s gateway',
          'The exact bytes of this request and this answer were signed with '+sig.signing_algo+':'+short(sig.signing_address)+', the key of the '+(signer?signer.role:'')+' report this gateway verified before the request'+(model?'.':'. A gateway signature covers what the gateway passed on, not what the model produced.'),raw))}
      else{list.appendChild(check(false,'This answer is not verified',cap(r.reason||'no valid signature')+'.',raw.concat([['reason code',r.reason_code]])))}
      receiptOf=r;dl.hidden=false;$('answer-status').textContent=ok?'Check it yourself: tools/verify_receipt.py':''}
    $('receipt').addEventListener('click',function(){
      if(!receiptOf)return;var a=document.createElement('a'),url=URL.createObjectURL(new Blob([JSON.stringify(receiptOf,null,2)+'\n'],{type:'application/json'}));
      a.href=url;a.download='receipt-'+receiptOf.id+'.json';document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url)},1000)});

    $('send').addEventListener('submit',function(ev){
      ev.preventDefault();if(sending||!state)return;var text=$('text').value.trim();if(!text)return;
      sending=true;$('go').disabled=true;$('status').textContent='Sending…';
      var turn=history.concat([{role:'user',content:text}]);bubble('user',text);$('text').value='';
      api('POST','/admin/private-chat/send',{model:$('model').value,messages:turn,redact:$('redact').checked,attested:$('attested').checked})
        .then(function(out){renderWire(out.dry_run);renderOutcome(out.asked,out.response);answerProof(out.response);
          if(out.response.ok){history=turn.concat([{role:'assistant',content:out.response.text}]);bubble('assistant',out.response.text);$('status').textContent=''}
          else{var er=out.response.error,up=out.response.upstream;
            bubble('assistant',er.code==='attestation_unverified'?'Not sent. '+cap(er.message)+'.':
              (out.response.status===401||out.response.status===403)&&up?'Sent to '+up+', which refused it (HTTP '+out.response.status+': '+er.message+'). Is the provider\'s API key set for the data plane?':
              er.message+' ('+er.code+')','refused');$('status').textContent=''}})
        .catch(function(e){bubble('assistant',e.message,'refused');$('status').textContent=''})
        .finally(function(){sending=false;$('go').disabled=false;$('text').focus();load()})});
    $('text').addEventListener('keydown',function(ev){if(ev.key==='Enter'&&!ev.shiftKey){ev.preventDefault();$('go').click()}});
    $('sample').addEventListener('click',function(){$('text').value=SAMPLE;$('text').focus()});
    $('reset').addEventListener('click',function(){history=[];var log=$('log');clear(log);var p=el('p','muted empty','Nothing sent yet.');p.id='log-empty';log.appendChild(p);
      clear($('wire'));$('wire').appendChild(el('p','muted empty','Send a message to see it here.'));clear($('wire-meta'));$('outcome').hidden=true;answerProof(null)});
    $('model').addEventListener('change',renderProof);
    $('verify').addEventListener('click',function(){
      if(!lastPair)return;var b=$('verify'),s=$('verify-status');b.disabled=true;s.textContent='Asking for a report with a new nonce…';var started=Date.now();
      api('POST','/admin/attestations/verify',lastPair).then(function(a){s.textContent=(a.verified?'Verified':'Not verified')+' in '+((Date.now()-started)/1000).toFixed(1)+' s'+(a.evidence?', nonce '+short(a.evidence.nonce,12):'')})
        .catch(function(e){s.textContent=e.message}).finally(function(){b.disabled=false;load()})});
    load();setInterval(function(){if(!sending)load()},5000);
    })();
    """
  end
end
