/* Executed inside the visible WKWebView. Reads only public catalog and visible
 * page facts. Never serializes cookies, form values, addresses or card details. */
(() => {
  'use strict';
  const tidy = s => String(s || '').replace(/[\u200b-\u200f\u2060]/g, '').replace(/\s+/g, ' ').trim();
  const label = s => { const e = document.createElement('div'); e.innerHTML = typeof s === 'object' ? s?.value || '' : s || ''; e.querySelectorAll('as-footnote,sup,script,style').forEach(x => x.remove()); return tidy(e.textContent); };
  const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const shop = () => location.protocol === 'https:' && /^(www|secure\d*(?:\.(?:store|www))?|store)\.apple\.com(\.cn)?$/.test(location.hostname);
  // Apple may decorate product anchors with tracking parameters or a
  // trailing slash. The saved plan only needs the canonical official path;
  // never carry query strings or fragments into the native URL validator.
  const canonicalProductURL = raw => {
    try {
      const u = new URL(String(raw), location.href);
      if (u.protocol !== 'https:' || u.hostname !== 'www.apple.com.cn' || !u.pathname.startsWith('/shop/')) return null;
      return u.origin + u.pathname.replace(/\/+$/, '');
    } catch (_) { return null; }
  };
  const text = e => tidy(e?.innerText || e?.getAttribute('aria-label') || e?.value);
  function data() {
    if (window.PRODUCT_SELECTION_BOOTSTRAP?.productSelectionData) return window.PRODUCT_SELECTION_BOOTSTRAP.productSelectionData;
    for (const s of document.scripts) {
      if (!s.textContent.includes('PRODUCT_SELECTION_BOOTSTRAP')) continue;
      const m = /(?:"productSelectionData"|\bproductSelectionData)\s*:\s*/.exec(s.textContent);
      if (!m) continue;
      let start = m.index + m[0].length, depth = 0, quoted = false, escaped = false;
      for (let i = start; i < s.textContent.length; i++) {
        const c = s.textContent[i];
        if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
        else if (c === '"') quoted = true;
        else if (c === '{') depth++;
        else if (c === '}' && --depth === 0) return JSON.parse(s.textContent.slice(start, i + 1));
      }
    }
    return null;
  }
  function catalog() {
    if (!shop()) throw Error('请打开 Apple 官方购买页');
    const d = data();
    if (!d?.products?.length || !d?.sections?.length) throw Error('此页面没有可识别的规格目录，请在官网完成配置后使用「读取当前商品」');
    const keys = d.sections.filter(s => !s.doesNotAffectMPartDetermination).map(s => s.formFieldName || s.dimension);
    if (!keys.length || new Set(keys).size !== keys.length) throw Error('官方规格结构变化');
    const base = location.origin + location.pathname.replace(/\/[a-z0-9]+\/a\/?$/i, '').replace(/\/$/, '');
    const variants = d.products.map(p => {
      if (!/^[A-Z0-9]+\/A$/i.test(p.partNumber)) throw Error('型号编号无效');
      const selections = {}, labels = [];
      for (const k of keys) { if (typeof p[k] !== 'string') throw Error('官方配置字段缺失'); selections[k] = p[k]; labels.push(label(d.displayValues?.[k]?.[p[k]]) || p[k]); }
      const a = [...document.querySelectorAll('a[href]')].find(a => {
        const href = canonicalProductURL(a.href);
        return href && new URL(href).pathname.toLowerCase().endsWith('/' + p.partNumber.toLowerCase());
      });
      const price = d.displayValues?.prices?.[p.fullPrice];
      const amount = Number(price?.currentPrice?.raw_amount ?? price?.amountBeforeTradeIn ?? 0);
      return {partNumber:p.partNumber.toUpperCase(), family:p.familyType || '', selections, label:labels.join(' · '), url:canonicalProductURL(a?.href) || base + '/' + p.partNumber.toLowerCase(), price:amount, comingSoon:!!p.comingSoon};
    });
    return {source:base, title:tidy(document.querySelector('h1')?.textContent || document.title).replace(/购买 | - Apple.*$/g,''), groups:keys.map(k => ({key:k, title:label(d.displayValues?.[k]?.title?.multiVariantsDisplayTitle) || k, options:[...new Set(variants.map(v => v.selections[k]))].sort((a,b) => { const order = d.displayValues?.[k]?.variantOrder || []; return order.indexOf(a) - order.indexOf(b); }).map(value => ({value,label:label(d.displayValues?.[k]?.[value]) || value}))})), variants};
  }
  function current() {
    if (!shop()) throw Error('请打开 Apple 官方购买页');
    const match = location.pathname.match(/\/([a-z0-9]+\/a)(?:\/|$)/i);
    const field = document.querySelector('input[name="product"],input[name="partNumber"]');
    const part = (match?.[1] || field?.value || '').toUpperCase();
    if (!/^[A-Z0-9]+\/A$/.test(part)) throw Error('尚未识别到唯一型号。请先在官网完成规格选择，再读取。');
    const d = data(), p = d?.products?.find(p => p.partNumber.toUpperCase() === part);
    if (p) { const c = catalog(); return {source:c.source,title:c.title,variant:c.variants.find(v => v.partNumber === part)}; }
    const title = tidy(document.querySelector('h1')?.textContent);
    if (!title) throw Error('页面缺少商品标题');
    return {source:location.origin + location.pathname,title,variant:{partNumber:part, family:'', selections:{}, label:title,url:location.origin + location.pathname,price:0,comingSoon:false}};
  }
  const buttons = () => [...document.querySelectorAll('button,input[type="submit"],a[role="button"],a.button')].filter(e => visible(e) && text(e));
  function descriptor(e) {
    let selector = '';
    if (e.id && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1) selector = '#' + CSS.escape(e.id);
    else if (e.getAttribute('data-autom')) selector = '[data-autom=' + JSON.stringify(e.getAttribute('data-autom')) + ']';
    else if (e.name) selector = e.tagName.toLowerCase() + '[name=' + JSON.stringify(e.name) + ']';
    return {selector,label:text(e),host:location.hostname,path:location.pathname};
  }
  function choices() { if (!shop()) return []; return buttons().filter(e => /^(继续.*|确认订单|提交订单|立即下单|下单|付款|支付|结账|结算|Continue.*|Place Order|Pay Now)$/i.test(text(e)) && !/删除|移除|退出|注销|remove|delete|sign out/i.test(text(e))).map(descriptor).filter(d => d.selector && d.label.length < 100); }
  function evidence(plan) {
    const part = plan.variant.partNumber.toLowerCase();
    const urlMatch = location.pathname.toLowerCase().endsWith('/' + part);
    const fields = [...document.querySelectorAll('input[name="product"],input[name="partNumber"]')];
    const selectedMatch = fields.length > 0 && fields.every(e => e.value.toLowerCase() === part);
    const checked = [...document.querySelectorAll('input[type=radio]:checked,select')].filter(e => e.name in plan.variant.selections);
    const conflict = checked.some(e => plan.variant.selections[e.name] !== e.value) || fields.some(e => e.value && e.value.toLowerCase() !== part);
    // A selected URL is product evidence; catalog entries listing *all* products are not.
    const items = [...document.querySelectorAll('[data-autom="bag-item"],.rs-bag-product,.rs-iteminfo')].filter(visible);
    const roots = items.filter(e => !items.some(p => p !== e && p.contains(e)));
    const matches = roots.filter(e => [...e.querySelectorAll('a[href]')].some(a => a.href.toLowerCase().includes('/' + part)) || tidy(e.innerText).toUpperCase().includes(plan.variant.partNumber));
    let bagOK = roots.length === 1 && matches.length === 1;
    if (bagOK) {
      const quantities = [...matches[0].querySelectorAll('select,input')].filter(e => /quantity/i.test(e.name + ' ' + e.id + ' ' + e.getAttribute('data-autom')));
      bagOK = quantities.length === 1 && String(quantities[0].value) === '1';
    }
    return {productOK:(urlMatch || selectedMatch) && !conflict, bagOK, items:roots.length};
  }
  function status() {
    const body = tidy(document.body?.innerText);
    const loggedIn = [...document.querySelectorAll('a,button')].some(e => visible(e) && /^(退出登录|退出账户|退出|Sign Out)$/i.test(text(e)));
    const password = /\/shop\/(signin|login)(\/|$)/i.test(location.pathname) || [...document.querySelectorAll('input[type=password]')].some(visible);
    const confirmation = [...document.querySelectorAll('[data-autom="order-number"],[data-autom="orderNumber"]')].some(e=>visible(e) && /[A-Z0-9]{6,}/.test(text(e)));
    return {loggedIn, loginRequired:password, challenge:/验证你的身份|验证您的身份|输入验证码|安全验证|verify your identity/i.test(body), orderConfirmed:confirmation, checkout:/\/shop\/checkout/i.test(location.pathname),path:location.pathname,title:document.title,host:location.hostname};
  }
  // These are global purchase defaults, not fields on each saved product plan.
  // Keep the legacy WKWebView path aligned with the native browser controller.
  const defaultPurchaseChoices = [
    {pattern:/^不折抵换购$|^No trade.in$/i, message:'已选择不折抵换购'},
    {pattern:/^不加 AppleCare\+ 服务计划$|^No AppleCare.*$/i, message:'已选择不加 AppleCare+ 服务计划'}
  ];
  function prepare(plan) {
    if (!shop()) return {state:'waiting',message:'等待官方商品页'};
    const desired = plan.variant.selections;
    const d = data();
    if (d?.products?.length) {
      const match = d.products.filter(p => p.partNumber === plan.variant.partNumber && Object.entries(desired).every(([k,v])=>p[k]===v));
      if (match.length !== 1) return {state:'manual',message:'官网目录已变化，原配置不再对应唯一型号，请重新读取规格'};
    }
    for (const [key,value] of Object.entries(desired)) {
      const radios = [...document.querySelectorAll('input[type=radio]')].filter(e => e.name === key);
      if (radios.length) {
        const choice = radios.find(e => e.value === value);
        if (!choice || choice.disabled) return {state:'waiting',message:'规格选项尚未可用'};
        if (!choice.checked) { choice.click(); return {state:'changed',message:'准备商品规格'}; }
      }
    }
    // These defaults are explicitly displayed in the App's purchase summary.
    for (const choice of defaultPurchaseChoices) {
      const labels = [...document.querySelectorAll('label')].filter(e => choice.pattern.test(text(e)));
      for (const l of labels) {
        const input = l.control || l.querySelector('input[type=radio]');
        if (input && !input.disabled && !input.checked) { input.click(); return {state:'changed',message:choice.message}; }
      }
    }
    return {state:'ready',message:'商品选配已准备，等待开售按钮'};
  }
  function step(plan, action, dry = true) {
    if (!shop()) return {state:'manual',message:'当前不在 Apple 商店页面，请在 App 内完成登录或支付验证'};
    const st = status();
    if (st.loginRequired || st.challenge) return {state:'manual',message:'Apple 要求登录或身份验证，请在右侧完成后继续'};
    const ev = evidence(plan);
    let candidates = [];
    if (action.kind === 'configure') {
      if (ev.bagOK || buttons().some(e => /^(添加到购物袋|加入购物袋|添加至购物袋|Add to Bag)$/i.test(text(e)))) return {state:'done',message:'已进入添加购物袋阶段'};
      if (!ev.productOK) return {state:'manual',message:'当前商品配置与订单包不一致'};
      candidates = buttons().filter(e => /^(继续|Continue)$/i.test(text(e)));
    } else if (action.kind === 'add') {
      if (ev.bagOK) return {state:'done',message:'购物袋中已有正确商品及数量'};
      if (!ev.productOK) return {state:'manual',message:'页面商品尚未与订单包匹配，请检查右侧规格'};
      candidates = buttons().filter(e => /^(添加到购物袋|加入购物袋|添加至购物袋|Add to Bag)$/i.test(text(e)));
    } else if (action.kind === 'checkout') {
      if (!ev.bagOK) return {state:'manual',message:'购物袋未核验：请确认只有目标商品且数量为 1，再继续'};
      candidates = buttons().filter(e => /^(结账|结算|去结账|Check Out|Checkout)$/i.test(text(e)));
    } else {
      if (location.hostname !== action.host || location.pathname !== action.path) return {state:'waiting',message:'等待已配置的购买步骤页面'};
      if (!action.selector) return {state:'manual',message:'缺少步骤按钮，请重新配置'};
      candidates = [...document.querySelectorAll(action.selector)].filter(e => visible(e) && text(e) === action.label);
      if (action.kind === 'submit') {
        if (!plan.autoSubmit) return {state:'manual',message:'已到最终确认，请在右侧提交订单'};
        // The final page must independently expose product, quantity and payable
        // total. If Apple hides any of those, human confirmation is required.
        if (!ev.bagOK) return {state:'manual',message:'最终订单摘要无法独立核验商品与数量，请人工提交'};
        const totals = [...document.querySelectorAll('[data-autom="summary-total"],[data-autom="total-price"]')].filter(visible);
        const amount = totals.length === 1 ? Number(text(totals[0]).replace(/[^0-9.]/g,'')) : NaN;
        if (!Number.isFinite(amount) || amount <= 0 || amount > plan.maxTotal) return {state:'manual',message:'应付金额未核实或超过价格上限，请人工确认'};
      }
    }
    if (!candidates.length) return {state:'waiting',message:'等待购买按钮可用'};
    if (candidates.length !== 1) return {state:'manual',message:'找到多个同名操作，停止自动执行，请人工确认'};
    const e = candidates[0];
    if (e.disabled || e.getAttribute('aria-disabled') === 'true') return {state:'waiting',message:'购买按钮暂不可用'};
    if (!dry) { e.click(); return {state:'clicked',message:'已点击：' + text(e)}; }
    return {state:'ready',message:'可执行：' + text(e)};
  }
  window.StoreAssistant = {catalog,current,choices,status,prepare,step};
})();
