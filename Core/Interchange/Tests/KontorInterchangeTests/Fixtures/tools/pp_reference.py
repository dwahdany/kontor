"""Independent reference for the Portfolio Performance importer tests.

Resolves XStream references with lxml's XPath engine (no code shared with the Swift package) and
derives, for every real PP fixture: entity counts, the unified ledger (each cross entry once),
account balances and share positions. The result is stored as ../pp_reference.json and compared
with the importer's output in ReferenceTests.swift.

Regenerate with:  uv run --with lxml python -I tools/pp_reference.py pp pp_reference.json
"""
import json
import os
import sys

from lxml import etree

def resolve(el):
    hops = 0
    while el is not None and el.get('reference') is not None and hops < 50:
        ref = el.get('reference')
        if ref[0] in './':
            r = el.xpath(ref)
            el = r[0] if r else None
        else:
            root = el.getroottree().getroot()
            r = root.xpath('//*[@id=$i]', i=ref)
            el = r[0] if r else None
        hops += 1
    return el

def child(el, name):
    c = el.find(name)
    return resolve(c) if c is not None else None

def txt(el, name, default=''):
    c = child(el, name)
    return (c.text or '').strip() if c is not None else default

POS_ACC = {'DEPOSIT','INTEREST','DIVIDENDS','FEES_REFUND','TAX_REFUND','SELL','TRANSFER_IN'}
POS_PF = {'BUY','TRANSFER_IN','DELIVERY_INBOUND'}

def analyze(path):
    tree = etree.parse(path)
    root = tree.getroot()
    version = int(root.findtext('version') or 0)
    sf = 1000 if version <= 25 else 100 if version <= 48 else 1
    pf = 1000000 if version <= 29 else 10000 if version <= 48 else 1
    out = {'version': version}
    secs = [resolve(s) for s in root.find('securities')] if root.find('securities') is not None else []
    out['securities_listed'] = len(secs)
    out['fx_securities'] = sum(1 for s in secs if s.find('targetCurrencyCode') is not None and (s.findtext('targetCurrencyCode') or '').strip())
    prices = {}
    for s in secs:
        ps = child(s, 'prices')
        days = {}
        if ps is not None:
            for p in ps:
                days[p.get('t')[:10]] = int(p.get('v')) * pf
        lat = child(s, 'latest')
        if lat is not None and lat.get('t') and (not days or lat.get('t')[:10] >= max(days)):
            days[lat.get('t')[:10]] = int(lat.get('v')) * pf
        prices[txt(s,'uuid') or txt(s,'name')] = [len(days), sum(days.values())]
    out['prices'] = prices
    accounts = []; portfolios = []
    def add(lst, el):
        if el is not None and all(el is not x for x in lst): lst.append(el)
    if root.find('accounts') is not None:
        for a in root.find('accounts'): add(accounts, resolve(a))
    if root.find('portfolios') is not None:
        for p in root.find('portfolios'): add(portfolios, resolve(p))
    # discover via cross entries / referenceAccount
    changed = True
    seen_tx = set()
    while changed:
        changed = False
        na, npf = len(accounts), len(portfolios)
        for p in list(portfolios):
            ra = child(p, 'referenceAccount'); add(accounts, ra)
        for owner in list(accounts) + list(portfolios):
            tl = child(owner, 'transactions')
            if tl is None: continue
            for t in tl:
                t = resolve(t)
                if t is None or tree.getpath(t) in seen_tx: continue
                seen_tx.add(tree.getpath(t))
                ce = child(t, 'crossEntry')
                if ce is not None:
                    for nm in ('account','accountFrom','accountTo'):
                        add(accounts, child(ce, nm))
                    for nm in ('portfolio','portfolioFrom','portfolioTo'):
                        add(portfolios, child(ce, nm))
        if len(accounts) != na or len(portfolios) != npf:
            changed = True; seen_tx = set()
    out['accounts'] = len(accounts); out['portfolios'] = len(portfolios)
    balances = {}; positions = {}
    entries = {}; standalone = {}
    seen = {}
    nacc = 0; npft = 0
    for a in accounts:
        key = txt(a,'uuid') or txt(a,'name')
        bal = 0
        tl = child(a, 'transactions')
        for t in (tl if tl is not None else []):
            t = resolve(t)
            if t is None: continue
            nacc += 1
            typ = txt(t,'type'); amt = int(txt(t,'amount') or 0)
            bal += amt if typ in POS_ACC else -amt
            ce = child(t,'crossEntry')
            if ce is not None:
                entries[tree.getpath(ce)] = ce.get('class') or '?'
            else:
                standalone[typ] = standalone.get(typ,0)+1
        balances[key] = bal
    for p in portfolios:
        key = txt(p,'uuid') or txt(p,'name')
        tl = child(p, 'transactions')
        for t in (tl if tl is not None else []):
            t = resolve(t)
            if t is None: continue
            npft += 1
            typ = txt(t,'type'); sh = int(txt(t,'shares') or 0) * sf
            s = child(t,'security')
            sk = (txt(s,'uuid') or txt(s,'name')) if s is not None else '?'
            k = key + '|' + sk
            positions[k] = positions.get(k,0) + (sh if typ in POS_PF else -sh)
            ce = child(t,'crossEntry')
            if ce is not None:
                entries[tree.getpath(ce)] = ce.get('class') or '?'
            else:
                standalone['P:'+typ] = standalone.get('P:'+typ,0)+1
    out['account_tx'] = nacc; out['portfolio_tx'] = npft
    ec = {}
    for v in entries.values(): ec[v] = ec.get(v,0)+1
    out['entries'] = ec; out['standalone'] = standalone
    out['unified'] = len(entries) + sum(standalone.values())
    out['balances'] = balances
    out['positions'] = {k:v for k,v in positions.items() if v != 0}
    out['negative_positions'] = [k for k,v in positions.items() if v < 0]
    out['negative_balances'] = {k:v for k,v in balances.items() if v < 0}
    # dangling refs
    out['dangling'] = sum(1 for e in root.iter() if e.get('reference') is not None and resolve(e) is None)
    return out


def units(t):
    fee = tax = 0; fx = None
    u = child(t, 'units')
    if u is not None:
        for un in u:
            un = resolve(un); a = child(un, 'amount'); v = int(a.get('amount'))
            if un.get('type') == 'FEE': fee += v
            elif un.get('type') == 'TAX': tax += v
            elif un.get('type') == 'GROSS_VALUE':
                f = child(un, 'forex')
                if f is not None: fx = [int(f.get('amount')), f.get('currency')]
    if fee == 0 and child(t, 'fees') is not None: fee = int(txt(t, 'fees') or 0)
    if tax == 0 and child(t, 'taxes') is not None: tax = int(txt(t, 'taxes') or 0)
    return fee, tax, fx
KIND = {'DEPOSIT':'deposit','REMOVAL':'withdrawal','INTEREST':'interest','INTEREST_CHARGE':'interestCharge','DIVIDENDS':'dividend','FEES':'fee','FEES_REFUND':'feeRefund','TAXES':'tax','TAX_REFUND':'taxRefund','DELIVERY_INBOUND':'deliveryIn','DELIVERY_OUTBOUND':'deliveryOut'}
def ledger(path):
    tree = etree.parse(path); root = tree.getroot()
    version = int(root.findtext('version') or 0)
    sf = 1000 if version <= 25 else 100 if version <= 48 else 1
    def info(t):
        fee, tax, fx = units(t); d = txt(t, 'date'); minute = None
        if len(d) > 10:
            minute = int(d[11:13]) * 60 + int(d[14:16])
            if minute == 0: minute = None
        s = child(t, 'security')
        return dict(type=txt(t, 'type'), date=d[:10], minute=minute, amount=int(txt(t, 'amount') or 0), shares=int(txt(t, 'shares') or 0) * sf,
                    fee=fee, tax=tax, fx=fx, cur=txt(t, 'currencyCode'), sec=(txt(s, 'name') if s is not None else None))
    out = []; seen = set()
    def owner_cur(t):
        p = t.getparent().getparent()
        return txt(p, 'currencyCode')
    for t in root.iter('account-transaction', 'portfolio-transaction'):
        if t.get('reference') is not None: continue
        ce = child(t, 'crossEntry'); i = info(t)
        if ce is None:
            k = KIND[i['type']]
            sh = i['shares'] if k in ('dividend','deliveryIn','deliveryOut') else 0
            bd = k in ('dividend','interest','deliveryIn','deliveryOut')
            sec = i['sec'] if k in ('dividend','deliveryIn','deliveryOut','fee','feeRefund','tax','taxRefund') else None
            out.append([k, i['date'], i['minute'], i['amount'], i['cur'], sh, i['fee'] if bd else 0, i['tax'] if bd else 0, i['fx'] if bd and i['fx'] and i['fx'][1] != i['cur'] else None, sec, None])
            continue
        p = tree.getpath(ce)
        if p in seen: continue
        seen.add(p)
        cls = ce.get('class')
        if cls == 'buysell':
            pt = info(child(ce, 'portfolioTransaction')); at = info(child(ce, 'accountTransaction'))
            out.append([pt['type'].lower(), pt['date'], pt['minute'], at['amount'], at['cur'], pt['shares'], pt['fee'], pt['tax'], pt['fx'] if pt['fx'] and pt['fx'][1] != at['cur'] else None, pt['sec'], None])
        elif cls == 'account-transfer':
            a = info(child(ce, 'transactionFrom')); b = info(child(ce, 'transactionTo'))
            ca = [b['amount'], b['cur']] if (b['cur'] != a['cur'] or b['amount'] != a['amount']) else None
            out.append(['cashTransfer', a['date'], a['minute'], a['amount'], a['cur'], 0, 0, 0, None, None, ca])
        else:
            a = info(child(ce, 'transactionFrom'))
            out.append(['securityTransfer', a['date'], a['minute'], a['amount'], a['cur'], a['shares'], 0, 0, None, a['sec'], None])
    return sorted(out, key=json.dumps)

def line(t):
    def pair(p): return '' if p is None else '%d %s' % (p[0], p[1])
    kind, date, minute, amount, cur, shares, fee, tax, fx, sec, counter = t
    return '|'.join([kind, date, '' if minute is None else str(minute), str(amount), cur, str(shares), str(fee), str(tax), pair(fx), sec or '', pair(counter)])

if __name__ == "__main__":
    directory, target = sys.argv[1], sys.argv[2]
    result = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith('.xml') or name.startswith('synthetic'):
            continue
        path = os.path.join(directory, name)
        a = analyze(path)
        result[name] = {
            'version': a['version'], 'securities': a['securities_listed'] - a['fx_securities'], 'exchangeRateSecurities': a['fx_securities'],
            'accounts': a['accounts'], 'depots': a['portfolios'], 'transactions': a['unified'],
            'balances': {k.lower(): v for k, v in a['balances'].items()},
            'positions': {k.lower(): v for k, v in a['positions'].items()},
            'prices': {k.lower(): v for k, v in a['prices'].items()},
            'ledger': sorted(line(t) for t in ledger(path)),
        }
    json.dump(result, open(target, 'w'), indent=1, sort_keys=True, ensure_ascii=False)
