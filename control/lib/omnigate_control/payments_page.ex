defmodule OmnigateControl.PaymentsPage do
  @moduledoc """
  The "Payments" page of the dashboard: the credit of every prepaid key, a
  form to add credit by hand, and the payments taken for credit. One
  self-contained HTML page, built like the dashboard itself (inline style
  and script under a per-response nonce, nothing loaded from elsewhere, all
  data written with `textContent`).

  The data comes from `GET /admin/keys`, `GET /admin/payments` and
  `GET /admin/topups`; credit is added with `POST /admin/keys/{name}/topup`.
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
      ~s(</div><div class="row"><button type="submit">Add credit</button><span id="t-status" role="status" aria-live="polite"></span></div></form></section>),
      ~s(<section aria-labelledby="h-pay"><h2 id="h-pay">Payments</h2>),
      ~s(<div class="scroll"><table><thead><tr><th>Started</th><th>Key</th><th>State</th><th class="num">Asked</th><th class="num">Credited</th><th>Paid with</th><th>Deposit address</th><th>Note</th></tr></thead>),
      ~s(<tbody id="payments"><tr><td colspan="8" class="muted">Loading…</td></tr></tbody></table></div></section>),
      ~s(<section aria-labelledby="h-added"><h2 id="h-added">Credit added</h2>),
      ~s(<p class="muted">Every top-up and bonus, newest first: payments, credit added by hand, and weekly bonuses.</p>),
      ~s(<div class="scroll"><table><thead><tr><th>Time</th><th>Key</th><th>Source</th><th class="num">Amount</th><th>Reference</th></tr></thead>),
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
    #t-status.bad{color:var(--bad)}td.addr{white-space:normal;word-break:break-all;min-width:220px;max-width:320px}
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
    function when(v){var d=typeof v==='number'?new Date(v*1000):new Date(v);return isNaN(d)?String(v==null?'':v):d.toLocaleString()}
    function api(method,path,body){
      return fetch(path,{method:method,credentials:'same-origin',headers:{'content-type':'application/json','x-csrf-token':csrf,accept:'application/json'},body:body==null?null:JSON.stringify(body)})
        .then(function(r){return r.text().then(function(t){var j=null;try{j=t?JSON.parse(t):null}catch(e){}
          if(!r.ok)throw new Error(j&&j.error&&j.error.message?j.error.message:'Request failed (HTTP '+r.status+')');return j})})}
    function empty(body,cols,text){clear(body);var tr=el('tr'),td=el('td','muted',text);td.colSpan=cols;tr.appendChild(td);body.appendChild(tr)}
    function cls(s){return s==='settled'||s==='active'?'ok':s==='awaiting_deposit'?'info':s==='processing'?'warn':s==='disabled'?'off':'bad'}
    function word(s){return {awaiting_deposit:'waiting for the deposit',settled:'credited'}[s]||s}

    function renderCredit(keys){
      var body=$('credit'),sel=$('t-key'),keep=sel.value,prepaid=keys.filter(function(k){return k.credits});
      clear(sel);
      if(!prepaid.length){empty(body,6,'No prepaid key yet. A managed key with a budget is prepaid: create one on the dashboard.');return}
      clear(body);
      prepaid.forEach(function(k){var c=k.credits,tr=el('tr'),st=el('td'),o=el('option',null,k.name);o.value=k.name;sel.appendChild(o);
        tr.appendChild(el('td',null,k.name));st.appendChild(el('span','pill '+cls(k.blocked?'out of credit':k.state),k.blocked?'out of credit':k.state));tr.appendChild(st);
        tr.appendChild(el('td','num',usd(c.balance_usd)));tr.appendChild(el('td','num',usd(c.burned_usd)));tr.appendChild(el('td','num',usd(k.budget_usd)));
        tr.appendChild(el('td',null,c.last_bonus?usd(c.last_bonus.amount_usd)+' for '+c.last_bonus.week:'—'));body.appendChild(tr)});
      if(keep)sel.value=keep}
    function renderPayments(list){
      var body=$('payments');if(!list.length){empty(body,8,'No payment yet.');return}clear(body);
      list.forEach(function(p){var tr=el('tr'),st=el('td'),d=p.deposit||{};
        tr.appendChild(el('td',null,when(p.created_at)));tr.appendChild(el('td',null,p.key));
        st.appendChild(el('span','pill '+cls(p.status),word(p.status)));tr.appendChild(st);
        tr.appendChild(el('td','num',usd(p.amount_usd)));tr.appendChild(el('td','num',p.credited_usd==null?'—':usd(p.credited_usd)));
        tr.appendChild(el('td',null,(d.amount||'')+' '+(d.symbol||'')+' on '+(d.chain||'')));
        tr.appendChild(el('td','mono addr',d.address||''));tr.appendChild(el('td','addr',p.detail||(p.tx&&p.tx.length?'tx '+p.tx.join(', '):'')));body.appendChild(tr)})}
    function renderAdded(list){
      var body=$('added');if(!list.length){empty(body,5,'Nothing added yet.');return}clear(body);
      list.forEach(function(t){var tr=el('tr');
        tr.appendChild(el('td',null,when(t.at||t.applied_at||t.time)));tr.appendChild(el('td',null,t.key));tr.appendChild(el('td',null,t.source||'admin'));
        tr.appendChild(el('td','num',usd(t.amount_usd)));tr.appendChild(el('td','mono addr',t.reference||''));body.appendChild(tr)})}
    function refresh(){
      return Promise.all([api('GET','/admin/keys'),api('GET','/admin/payments'),api('GET','/admin/topups')]).then(function(r){
        renderCredit(r[0].keys||[]);renderPayments(r[1].payments||[]);renderAdded(r[2].topups||[]);$('updated').textContent='Updated '+new Date().toLocaleTimeString()})
      .catch(function(e){$('updated').textContent=e.message})}
    $('topup').addEventListener('submit',function(ev){
      ev.preventDefault();var f=ev.target,s=$('t-status');s.className='';s.textContent='Adding…';
      api('POST','/admin/keys/'+encodeURIComponent(f.key.value)+'/topup',{amount_usd:Number(f.amount_usd.value),reference:f.reference.value.trim()})
        .then(function(r){s.textContent=r.topup&&r.topup.replayed?'That reference was credited before; nothing was added.':'Added '+usd(r.topup.amount_usd)+'.';f.amount_usd.value='';f.reference.value='';return refresh()})
        .catch(function(e){s.className='bad';s.textContent=e.message})});
    refresh();setInterval(function(){if(!document.hidden)refresh()},5000);document.addEventListener('visibilitychange',function(){if(!document.hidden)refresh()});
    })();
    """
  end
end
