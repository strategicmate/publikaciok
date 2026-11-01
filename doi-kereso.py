#!/usr/bin/env python3
# doi-kereso.py
#
# Megkeresi a publikacios lista tetelezeihez tartozo DOI azonositokat
# az OpenAlex es a Crossref adatbazisban, majd elkesziti a frissitett fajlt.
#
# Nem kell hozza telepiteni semmit, csak Python 3.8 vagy ujabb.
#
# Hasznalat:
#   python doi-kereso.py --limit 10      proba, csak az elso 10 talalat nelkuli tetelen
#   python doi-kereso.py                 teljes futas, feltoltes nelkul
#   python doi-kereso.py --feltoltes     teljes futas, a vegen felajanlja a feltoltest
#
# A szkript nem tarol kulcsot. Ha feltoltesre keri, csak az adott futas idejere kerdezi be.

import argparse
import base64
import csv
import getpass
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

# Windows konzolon az ekezetek miatt
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

VERZIO = "doi-kereso.py 1.0"
OPEN_TAG = '<script type="application/json" id="db">'
CLOSE_TAG = "</script>"
DB_RE = re.compile(re.escape(OPEN_TAG) + r"(.*?)" + re.escape(CLOSE_TAG), re.S)


# ----------------------------------------------------------------- segedek

def norm(s):
    if not s:
        return ""
    d = unicodedata.normalize("NFD", str(s))
    d = "".join(c for c in d if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9]+", " ", d.lower()).strip()


def cim_egyezik(a, b):
    x, y = norm(a), norm(b)
    if not x or not y:
        return False
    if x == y:
        return True
    hosszu, rovid = (x, y) if len(x) >= len(y) else (y, x)
    if hosszu.startswith(rovid) and len(rovid) / len(hosszu) >= 0.7:
        return True
    A = {w for w in x.split() if len(w) > 3}
    B = {w for w in y.split() if len(w) > 3}
    if len(A) < 3 or len(B) < 3:
        return False
    return len(A & B) / min(len(A), len(B)) >= 0.85


def ev_egyezik(a, b):
    if not a or not b:
        return True
    try:
        return abs(int(a) - int(b)) <= 1
    except (TypeError, ValueError):
        return True


class Naplo:
    def __init__(self):
        self.sorok = []

    def add(self, uzenet):
        self.sorok.append(uzenet)

    def egyedi(self, db=5):
        latott, ki = set(), []
        for s in self.sorok:
            if s not in latott:
                latott.add(s)
                ki.append(s)
            if len(ki) >= db:
                break
        return ki


naplo = Naplo()


def kerdez(url, forras, ua):
    """Lekerdezes ujraprobalkozassal forgalomkorlat eseten."""
    varakozas = 0.8
    for probalkozas in range(1, 4):
        try:
            keres = urllib.request.Request(
                url, headers={"User-Agent": ua, "Accept": "application/json"}
            )
            with urllib.request.urlopen(keres, timeout=30) as valasz:
                return json.loads(valasz.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            uz = f"{forras} HTTP {e.code}: {e.reason}"
            if e.code in (429, 500, 502, 503, 504) and probalkozas < 3:
                naplo.add(f"{uz}  [ujraprobalas {probalkozas}]")
                time.sleep(varakozas)
                varakozas *= 3
                continue
            naplo.add(uz)
            raise
        except Exception as e:
            uz = f"{forras}: {e.__class__.__name__}: {e}"
            if probalkozas < 3:
                naplo.add(f"{uz}  [ujraprobalas {probalkozas}]")
                time.sleep(varakozas)
                varakozas *= 3
                continue
            naplo.add(uz)
            raise
    return None


def openalex(rec, mail, ua):
    cim = (rec.get("title") or "")[:250]
    url = ("https://api.openalex.org/works?per-page=3"
           "&select=doi,title,publication_year"
           f"&mailto={urllib.parse.quote(mail)}"
           f"&search={urllib.parse.quote(cim)}")
    j = kerdez(url, "OpenAlex", ua)
    for it in (j or {}).get("results", []):
        if not it.get("doi"):
            continue
        if not cim_egyezik(rec.get("title"), it.get("title")):
            continue
        if not ev_egyezik(rec.get("year"), it.get("publication_year")):
            continue
        return {
            "doi": re.sub(r"^https?://(dx\.)?doi\.org/", "", str(it["doi"])),
            "matched": it.get("title") or "",
            "year": it.get("publication_year"),
            "src": "OpenAlex",
        }
    return None


def crossref(rec, mail, ua):
    cim = (rec.get("title") or "")[:250]
    url = ("https://api.crossref.org/works?rows=3"
           "&select=DOI,title,issued"
           f"&mailto={urllib.parse.quote(mail)}"
           f"&query.bibliographic={urllib.parse.quote(cim)}")
    j = kerdez(url, "Crossref", ua)
    for it in ((j or {}).get("message") or {}).get("items", []):
        cimek = it.get("title") or []
        if not cimek:
            continue
        t = cimek[0]
        if not cim_egyezik(rec.get("title"), t):
            continue
        ev = None
        reszek = (it.get("issued") or {}).get("date-parts") or []
        if reszek and reszek[0]:
            ev = reszek[0][0]
        if not ev_egyezik(rec.get("year"), ev):
            continue
        return {"doi": it.get("DOI"), "matched": t, "year": ev, "src": "Crossref"}
    return None


# ----------------------------------------------------------------- fo menet

def main():
    ap = argparse.ArgumentParser(description="DOI kereso a publikacios listahoz")
    ap.add_argument("--limit", type=int, default=0, help="csak ennyi tetelt nez meg, 0 = mind")
    ap.add_argument("--feltoltes", action="store_true", help="a vegen felajanlja a feltoltest")
    ap.add_argument("--owner", default="strategicmate")
    ap.add_argument("--repo", default="publikaciok")
    ap.add_argument("--path", default="besenyojanos/index.html")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--mail", default="attilamate.kovacs@gmail.com")
    a = ap.parse_args()

    ua = f"doi-kereso/1.0 (mailto:{a.mail})"
    mappa = os.path.dirname(os.path.abspath(__file__))

    nyers = f"https://raw.githubusercontent.com/{a.owner}/{a.repo}/{a.branch}/{a.path}"
    print(VERZIO)
    print(f"Fajl letoltese: {nyers}")
    keres = urllib.request.Request(nyers, headers={"User-Agent": ua, "Cache-Control": "no-cache"})
    with urllib.request.urlopen(keres, timeout=60) as v:
        html = v.read().decode("utf-8")

    m = DB_RE.search(html)
    if not m:
        print("HIBA: nem talalom az adatblokkot a fajlban.")
        return 1
    db = json.loads(m.group(1))
    print(f"Betoltve: {len(db)} tetel")

    todo = [r for r in db if not r.get("doi") and not r.get("hidden") and r.get("title")]
    if a.limit > 0:
        todo = todo[: a.limit]
    print(f"Kereses indul {len(todo)} tetelhez")
    print()

    talalatok = []
    hiba_oa = hiba_cr = 0

    for i, rec in enumerate(todo, 1):
        hit = None
        try:
            hit = openalex(rec, a.mail, ua)
        except Exception:
            hiba_oa += 1
        if not hit:
            time.sleep(0.12)
            try:
                hit = crossref(rec, a.mail, ua)
            except Exception:
                hiba_cr += 1

        if hit:
            rec["doi"] = hit["doi"]
            rec["doi_source"] = hit["src"]
            talalatok.append({
                "MTMT": rec.get("mtmt_id", ""),
                "Ev": rec.get("year", ""),
                "Cim": rec.get("title", ""),
                "TalaltCim": hit["matched"],
                "TalaltEv": hit["year"] or "",
                "DOI": hit["doi"],
                "Forras": hit["src"],
                "Link": "https://doi.org/" + hit["doi"],
            })
            cim = rec["title"][:60]
            print(f"  [{i:>3}] {hit['doi']}  <-  {cim}")
        else:
            print(f"  [{i:>3}] ...", end="\r", flush=True)

        time.sleep(0.15)

    print(" " * 70, end="\r")
    print()
    oa = sum(1 for t in talalatok if t["Forras"] == "OpenAlex")
    cr = sum(1 for t in talalatok if t["Forras"] == "Crossref")
    print(f"Kesz. {len(talalatok)} talalat {len(todo)} tetelbol.")
    print(f"  OpenAlex: {oa} talalat, {hiba_oa} hiba")
    print(f"  Crossref: {cr} talalat, {hiba_cr} hiba")

    if naplo.sorok:
        print()
        print("Hibauzenetek (elteroek, legfeljebb 5):")
        for s in naplo.egyedi():
            print("  " + s)

    if not talalatok:
        print("\nNincs mit menteni.")
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M")
    csv_ut = os.path.join(mappa, f"doi-jelentes-{stamp}.csv")
    with open(csv_ut, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(talalatok[0].keys()), delimiter=";")
        w.writeheader()
        w.writerows(talalatok)
    print(f"\nJelentes: {csv_ut}")

    uj_json = json.dumps(db, ensure_ascii=False, indent=1).replace("</", "<\\/")
    uj_html = html[: m.start()] + OPEN_TAG + uj_json + CLOSE_TAG + html[m.end():]

    html_ut = os.path.join(mappa, f"index-{stamp}.html")
    with open(html_ut, "w", encoding="utf-8", newline="") as f:
        f.write(uj_html)
    print(f"Frissitett fajl: {html_ut}")

    if not a.feltoltes:
        print()
        print("A feltoltes kimaradt. Nezd at a jelentest, es ha jo, futtasd ujra a")
        print("--feltoltes kapcsoloval, vagy toltsd fel kezzel a fenti fajlt a GitHubra.")
        return 0

    print()
    print("Nezd at a jelentest, mielott feltoltod.")
    if input("Feltoltsem a GitHubra? (i/n) ").strip().lower() != "i":
        print("Feltoltes kihagyva.")
        return 0

    token = getpass.getpass("Illeszd be a GitHub kulcsot (nem latszik): ").strip()
    if not token:
        print("Nem adtal meg kulcsot, feltoltes kihagyva.")
        return 0

    api = f"https://api.github.com/repos/{a.owner}/{a.repo}/contents/{a.path}"
    fejlec = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "doi-kereso",
        "Content-Type": "application/json",
    }

    with urllib.request.urlopen(
        urllib.request.Request(f"{api}?ref={a.branch}", headers=fejlec), timeout=30
    ) as v:
        meta = json.loads(v.read().decode("utf-8"))

    torzs = json.dumps({
        "message": f"DOI azonositok kiegeszitese ({len(talalatok)} tetel)",
        "content": base64.b64encode(uj_html.encode("utf-8")).decode("ascii"),
        "sha": meta["sha"],
        "branch": a.branch,
    }).encode("utf-8")

    try:
        with urllib.request.urlopen(
            urllib.request.Request(api, data=torzs, headers=fejlec, method="PUT"), timeout=60
        ) as v:
            r = json.loads(v.read().decode("utf-8"))
        print()
        print(f"Feltoltve. Commit: {r['commit']['sha'][:7]}")
        print("Az elo oldal 1-2 percen belul frissul.")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            print("\nA kulcs ervenytelen vagy lejart, vagy nincs rajta Contents jogosultsag.")
        else:
            print(f"\nA feltoltes nem sikerult. HTTP {e.code}: {e.reason}")
            print(e.read().decode("utf-8", "replace")[:300])
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
