"""比較用の写真を Wikimedia Commons から集める（自由に使えるライセンスのものだけ）。
使い方: python3 fetch_images.py <保存先フォルダ>
保存先に credits.txt（作者・ライセンス・元のページ）も書く。"""
import json
import os
import sys
import urllib.parse
import urllib.request

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
API = "https://commons.wikimedia.org/w/api.php"
HEADERS = {"User-Agent": "HameraBeautyCompare/1.0 (GitHub Actions; image quality test)"}
# (検索語, 何枚取るか)。自撮り・上半身・全身が混ざるようにする
QUERIES = [
    ("portrait woman face close-up natural light", 2),
    ("headshot portrait woman", 2),
    ("portrait man face close-up", 2),
    ("selfie young woman", 2),
    ("half-length portrait woman outdoor", 2),
    ("full body portrait standing woman street", 2),
    ("full body portrait man standing", 1),
]
ALLOWED = ("cc0", "cc by", "cc-by", "public domain", "pd")


def get(params):
    url = API + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as r:
        return json.load(r)


credits = []
taken = set()
for query, count in QUERIES:
    data = get({
        "action": "query", "format": "json", "generator": "search", "gsrnamespace": 6,
        "gsrsearch": f"{query} filetype:bitmap", "gsrlimit": 30,
        "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata", "iiurlwidth": 2400,
    })
    pages = sorted(data.get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 0))
    got = 0
    for page in pages:
        if got >= count:
            break
        info = (page.get("imageinfo") or [{}])[0]
        meta = info.get("extmetadata", {})
        license_name = meta.get("LicenseShortName", {}).get("value", "")
        if info.get("mime") != "image/jpeg" or info.get("width", 0) < 1500 or info.get("height", 0) < 1500:
            continue
        if not license_name.lower().startswith(ALLOWED) or "nc" in license_name.lower().split():
            continue
        if page["title"] in taken:
            continue
        name = f"c{len(taken):02d}"
        url = info.get("thumburl") or info["url"]
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=120) as r:
                open(os.path.join(OUT, name + ".jpg"), "wb").write(r.read())
        except Exception as error:  # noqa: BLE001
            print("skip", page["title"], error)
            continue
        taken.add(page["title"])
        got += 1
        artist = meta.get("Artist", {}).get("value", "")
        credits.append(f"{name}: {page['title']} / {license_name} / {artist} / {info.get('descriptionurl', '')}")
        print(name, page["title"], license_name)

open(os.path.join(OUT, "credits.txt"), "w").write("\n".join(credits) + "\n")
