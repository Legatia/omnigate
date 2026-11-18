defmodule OmnigateControl.PaymentsPage do
  @moduledoc """
  The "Payments" page of the dashboard: the credit of every prepaid key, a
  form to add credit by hand, and the payments taken for credit. One
  self-contained HTML page, built like the dashboard itself (inline style
  and script under a per-response nonce, nothing loaded from elsewhere, all
  data written with `textContent`).

  The data comes from `GET /admin/keys`, `GET /admin/payments` and
  `GET /admin/topups`; credit is added with `POST /admin/keys/{name}/topup`,
  or from a transaction's signature with `POST /admin/payments/credit`.
  The page exists only while payments are configured (`OmnigateControl.Payments`).
  """
  alias OmnigateControl.Dashboard

  @doc "The page for a CSRF token, a CSP nonce and the gateway's public address."
  def page(csrf, nonce, gateway_url) do
    [
      ~s(<!doctype html><html lang="en"><head><meta charset="utf-8">),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
      ~s(<meta name="csrf" content="),
      Plug.HTML.html_escape(csrf),
      ~s("><link rel="icon" href="data:,">),
      ~s(<title>Payments · omnigate</title><style nonce="),
      nonce,
      ~s(">),
      Dashboard.css(),
      css(),
      ~s(</style></head><body>),
      ~s(<header class="top"><div class="brand">omnigate <span>payments</span></div>),
      ~s(<nav aria-label="Pages"><a href="/">Dashboard</a><a href="/payments" aria-current="page">Payments</a></nav>),
      ~s(<div class="right"><span id="updated" class="muted" role="status"></span>),
      ~s(<form method="post" action="/logout"><input type="hidden" name="_csrf" value="),
      Plug.HTML.html_escape(csrf),
      ~s("><button type="submit" class="ghost">Sign out</button></form></div></header><main>),
      ~s(<section aria-labelledby="h-credit"><h2 id="h-credit">Credit</h2>),
      ~s(<p class="muted">Prepaid keys and what is left on each. Key holders add credit themselves at <code>),
      Plug.HTML.html_escape(gateway_url),
      ~s(/topup</code>, or over the payments API.</p>),
      ~s(<div class="scroll"><table><thead><tr><th>Key</th><th>State</th><th class="num">Credit left</th><th class="num">Used</th><th class="num">Total bought</th><th>Last bonus</th></tr></thead>),
      ~s(<tbody id="credit"><tr><td colspan="6" class="muted">Loading…</td></tr></tbody></table></div>),
      ~s(<form id="topup" class="panel" autocomplete="off"><h3>Add credit by hand</h3>),
      ~s(<p class="muted">For money that reached you some other way. A reference is credited once: sending the same one again adds nothing.</p><div class="fields">),
      ~s(<label>Key<select name="key" id="t-key" required></select></label>),
      ~s(<label>Amount in USD<input name="amount_usd" type="number" min="0.01" step="0.01" inputmode="decimal" required></label>),
      ~s(<label>Reference <span class="muted">an invoice or transfer id</span><input name="reference" required maxlength="200" pattern="[!-~]+" spellcheck="false"></label>),
      ~s(</div><div class="row"><button type="submit">Add credit</button><span id="t-status" role="status" aria-live="polite"></span></div></form>),
      ~s(<form id="bytx" class="panel" autocomplete="off" hidden><h3>Credit a transaction</h3>),
      ~s(<p class="muted">For a transfer to your wallet that was not recognized: sent by hand with another amount, or after its payment expired. ),
      ~s(The gateway reads the transaction on the chain and credits what it moved to your wallet. One transaction is credited once. ),
      ~s(Whose transfer it is the chain does not say: check that it is this key holder's.</p><div class="fields">),
      ~s(<label>Key<select name="key" id="x-key" required></select></label>),
      ~s(<label>Transaction signature<input name="tx" required minlength="64" maxlength="88" pattern="[1-9A-HJ-NP-Za-km-z]+" spellcheck="false"></label>),
      ~s(</div><div class="row"><button type="submit">Read and credit</button><span id="x-status" role="status" aria-live="polite"></span></div></form></section>),
      ~s(<section aria-labelledby="h-pay"><h2 id="h-pay">Payments</h2>),
      ~s(<div class="scroll"><table><thead><tr><th>Started, UTC</th><th>Key</th><th>State</th><th class="num">Asked</th><th class="num">Credited</th><th>Paid with</th><th>Deposit address and note</th></tr></thead>),
      ~s(<tbody id="payments"><tr><td colspan="7" class="muted">Loading…</td></tr></tbody></table></div><p id="p-status" role="status" aria-live="polite"></p></section>),
      ~s(<section aria-labelledby="h-added"><h2 id="h-added">Credit added</h2>),
      ~s(<p class="muted">Every top-up and bonus, newest first: payments, credit added by hand, and weekly bonuses.</p>),
      ~s(<div class="scroll"><table><thead><tr><th>Time, UTC</th><th>Key</th><th>Source</th><th class="num">Amount</th><th>Reference</th></tr></thead>),
      ~s(<tbody id="added"><tr><td colspan="5" class="muted">Loading…</td></tr></tbody></table></div></section>),
      ~s(</main><script nonce="),
      nonce,
      ~s(">),
      js(),
      ~s(</script></body></html>)
    ]
    |> IO.iodata_to_binary()
  end

  defp css do
    ~S"""
    nav a[aria-current=page]{border-bottom-color:var(--accent)}
    #t-status.bad,#x-status.bad,#p-status.bad{color:var(--bad)}form[hidden]{display:none}td.addr .note button{margin:4px 0 0}td.addr{white-space:normal;word-break:break-all;min-width:220px;max-width:320px}
    td.addr .note{display:block;margin-top:2px;font-size:12px;word-break:normal;overflow-wrap:anywhere}
    """
  end

  defp js do
    ~S"""
    (function(){
    "use strict";
    var csrf=document.querySelector('meta[name=csrf]').content;
    function $(id){return document.getElementById(id)}
    function el(tag,cls,text){var e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
    function clear(n){while(n.firstChild)n.removeChild(n.firstChild)}
    function usd(n){return n==null?'—':'$'+Number(n).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2})}
    // UTC, as on the dashboard.
    function when(v){var d=typeof v==='number'?new Date(v*1000):new Date(v);return isNaN(d)?String(v==null?'':v):d.toISOString().slice(0,19).replace('T',' ')}
    function api(method,path,body){
      return fetch(path,{method:method,credentials:'same-origin',headers:{'content-type':'application/json','x-csrf-token':csrf,accept:'application/json'},body:body==null?null:JSON.stringify(body)})
        .then(function(r){return r.text().then(function(t){var j=null;try{j=t?JSON.parse(t):null}catch(e){}
          // The session ended: sign in, and come back here.
          if(r.status===401){location.href='/login?next=/payments'}
          if(!r.ok)throw new Error(j&&j.error&&j.error.message?j.error.message:'Request failed (HTTP '+r.status+')');return j})})}
    function empty(body,cols,text){clear(body);var tr=el('tr'),td=el('td','muted',text);td.colSpan=cols;tr.appendChild(td);body.appendChild(tr)}
    function cls(s){return s==='settled'||s==='active'?'ok':s==='awaiting_deposit'?'info':s==='processing'?'warn':s==='disabled'?'off':'bad'}
    var byTx=false,sure=null,explorer=null;
    // A transaction's signature, as a link where there is somewhere to look it up.
    function txNode(sig){
      if(!explorer||!/^[1-9A-HJ-NP-Za-km-z]{64,88}$/.test(sig))return document.createTextNode(sig);
      var a=el('a',null,sig);a.href=explorer.replace('{tx}',sig);a.target='_blank';a.rel='noopener noreferrer';a.title='Look at this transaction on the chain';return a}
    function say(id,text,bad){var s=$(id);s.className=bad?'bad':'';s.textContent=text||''}
    function word(s){return {awaiting_deposit:'waiting for the deposit',settled:'credited'}[s]||s}

    function renderCredit(keys){
      var body=$('credit'),sel=$('t-key'),keep=sel.value,xsel=$('x-key'),xkeep=xsel.value,prepaid=keys.filter(function(k){return k.credits});
      clear(sel);clear(xsel);
      if(!prepaid.length){empty(body,6,'No prepaid key yet. A managed key with a budget is prepaid: create one on the dashboard.');return}
      clear(body);
      prepaid.forEach(function(k){var c=k.credits,tr=el('tr'),st=el('td'),o=el('option',null,k.name);o.value=k.name;sel.appendChild(o);o=el('option',null,k.name);o.value=k.name;xsel.appendChild(o);
        tr.appendChild(el('td',null,k.name));st.appendChild(el('span','pill '+cls(k.blocked?'out of credit':k.state),k.blocked?'out of credit':k.state));tr.appendChild(st);
        tr.appendChild(el('td','num',usd(c.balance_usd)));tr.appendChild(el('td','num',usd(c.burned_usd)));tr.appendChild(el('td','num',usd(k.budget_usd)));
        tr.appendChild(el('td',null,c.last_bonus?usd(c.last_bonus.amount_usd)+' for '+c.last_bonus.week:'—'));body.appendChild(tr)});
      if(keep)sel.value=keep;if(xkeep)xsel.value=xkeep}
    function renderPayments(list){
      var body=$('payments');if(!list.length){empty(body,7,'No payment yet.');return}clear(body);
      list.forEach(function(p){var tr=el('tr'),st=el('td'),d=p.deposit||{};
        tr.appendChild(el('td',null,when(p.created_at)));tr.appendChild(el('td',null,p.key));
        st.appendChild(el('span','pill '+cls(p.status),word(p.status)));tr.appendChild(st);
        tr.appendChild(el('td','num',usd(p.amount_usd)));tr.appendChild(el('td','num',p.credited_usd==null?'—':usd(p.credited_usd)));
        tr.appendChild(el('td',null,(d.amount||'')+' '+(d.symbol||'')+' on '+(d.chain||'')));
        var a=el('td','addr'),note=p.detail||'',c=p.claimed_tx;a.appendChild(el('span','mono',d.address||''));
        if(d.reference)a.appendChild(el('span','muted note','reference '+d.reference));
        if(p.tx&&p.tx.length){var txs=el('span','muted note','tx ');p.tx.forEach(function(t,i){if(i)txs.appendChild(document.createTextNode(', '));txs.appendChild(txNode(String(t)))});a.appendChild(txs)}
        if(note)a.appendChild(el('span','muted note',note));
        if(c&&byTx){var box=el('span','note','The payer names a transaction of '+usd(c.amount_usd)+': '),ask='Credit '+usd(c.amount_usd)+' to '+p.key+'?',b=el('button','small ghost',sure===p.id?ask:'Read and credit');
          box.appendChild(txNode(c.signature));box.appendChild(document.createTextNode(' '));
          b.type='button';b.addEventListener('click',function(){
            // (Asked twice; the question outlives the table being drawn again.)
            if(sure!==p.id){sure=p.id;b.textContent=ask;return}
            sure=null;b.disabled=true;say('p-status','Reading the transaction…');
            api('POST','/admin/payments/credit',{payment:p.id,tx:c.signature}).then(function(r){say('p-status','Credited '+usd(r.credited_usd)+' to '+r.key+'.');return refresh()})
              .catch(function(e){say('p-status',e.message,true);b.disabled=false;b.textContent='Read and credit'})});
          box.appendChild(b);a.appendChild(box)}
        tr.appendChild(a);body.appendChild(tr)})}
    function renderAdded(list){
      var body=$('added');if(!list.length){empty(body,5,'Nothing added yet.');return}clear(body);
      list.forEach(function(t){var tr=el('tr');
        tr.appendChild(el('td',null,when(t.at||t.applied_at||t.time)));tr.appendChild(el('td',null,t.key));tr.appendChild(el('td',null,t.source||'admin'));
        // "solana:tx:<signature>": the signature is a link.
        var ref=el('td','mono addr'),m=/^([a-z_]+:tx:)([1-9A-HJ-NP-Za-km-z]{64,88})$/.exec(t.reference||'');
        if(m){ref.appendChild(document.createTextNode(m[1]));ref.appendChild(txNode(m[2]))}else ref.textContent=t.reference||'';
        tr.appendChild(el('td','num',usd(t.amount_usd)));tr.appendChild(ref);body.appendChild(tr)})}
    function refresh(){
      return Promise.all([api('GET','/admin/keys'),api('GET','/admin/payments'),api('GET','/admin/topups')]).then(function(r){
        byTx=!!r[1].credit_by_tx;explorer=typeof r[1].explorer_tx==='string'&&/^https:\/\//.test(r[1].explorer_tx)?r[1].explorer_tx:null;$('bytx').hidden=!byTx;renderCredit(r[0].keys||[]);renderPayments(r[1].payments||[]);renderAdded(r[2].topups||[]);$('updated').textContent='Updated '+new Date().toISOString().slice(11,19)+' UTC'})
      .catch(function(e){$('updated').textContent=e.message})}
    $('topup').addEventListener('submit',function(ev){
      ev.preventDefault();var f=ev.target,s=$('t-status');s.className='';s.textContent='Adding…';
      api('POST','/admin/keys/'+encodeURIComponent(f.key.value)+'/topup',{amount_usd:Number(f.amount_usd.value),reference:f.reference.value.trim()})
        .then(function(r){s.textContent=r.topup&&r.topup.replayed?'That reference was credited before; nothing was added.':'Added '+usd(r.topup.amount_usd)+'.';f.amount_usd.value='';f.reference.value='';return refresh()})
        .catch(function(e){s.className='bad';s.textContent=e.message})});
    $('bytx').addEventListener('submit',function(ev){
      ev.preventDefault();var f=ev.target;say('x-status','Reading the transaction…');
      api('POST','/admin/payments/credit',{key:f.key.value,tx:f.tx.value.trim()})
        .then(function(r){say('x-status','Credited '+usd(r.credited_usd)+' to '+r.key+'.');f.tx.value='';return refresh()})
        .catch(function(e){say('x-status',e.message,true)})});
    refresh();setInterval(function(){if(!document.hidden)refresh()},5000);document.addEventListener('visibilitychange',function(){if(!document.hidden)refresh()});
    })();
    """
  end
end
