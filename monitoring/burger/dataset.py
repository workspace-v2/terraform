#!/usr/bin/env python3
"""Deterministic, streaming MySQL fixtures. Does not connect to or delete from a database."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import random

VERSION = 1
PROFILES = {"10k": 10000, "100k": 100000, "1m": 1000000}
PATTIES = ["소고기", "치킨", "새우", "콩"]
SAUCES = ["스모키", "갈릭", "매콤", "허니", "머스터드"]
EXTRAS = ["치즈", "베이컨", "버섯", "양파", "아보카도"]
ADJECTIVES = ["더블", "클래식", "그릴", "크리스피", "미니", "시그니처"]
TAG_LABELS = {"SPICY": "매콤", "THICK_PATTY": "두꺼운 패티", "GOOD_VALUE": "가성비", "CHEESY": "치즈", "JUICY": "육즙", "CRISPY": "바삭", "HANDMADE": "수제버거"}


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def catalog(seed, id_base, real_csv=None):
    rng = random.Random(seed)
    if real_csv:
        with open(real_csv, encoding="utf-8-sig", newline="") as source:
            rows = list(csv.DictReader(source))
        if not rows or len(rows) > 3000:
            raise ValueError("real catalog must contain 1..3000 rows")
        names = sorted({row["brand"].strip() for row in rows})
        if any(not name or len(name) > 100 for name in names):
            raise ValueError("invalid brand name")
        brands = [{"id": id_base + i + 1, "name": name} for i, name in enumerate(names)]
        by_name = {b["name"]: b["id"] for b in brands}
        menus = []
        for i, row in enumerate(rows):
            if not row["source_url"].startswith(("https://", "http://")):
                raise ValueError("every real menu requires a source URL")
            name, description = row["name"].strip(), row["description"].strip()
            price = int(row["price"]) if row["price"].strip() else None
            if not name or len(name) > 150 or price is not None and price < 0:
                raise ValueError("invalid menu name or price")
            menus.append({"id": id_base+i+1, "brand_id": by_name[row["brand"].strip()], "name": name, "description": description,
                          "price": price, "source_type": "REAL", "source_url": row["source_url"], "traits": []})
        return brands, menus
    brands = [{"id": id_base+i+1, "name": "합성 버거 공방 %03d" % (i+1)} for i in range(100)]
    menus = []
    for i in range(3000):
        variant = i % 30
        patty = PATTIES[(variant // 6) % 4]
        sauce = SAUCES[(variant // 3) % 5]
        extra = EXTRAS[variant % 5]
        adjective = ADJECTIVES[variant % 6]
        name = f"{sauce} {extra} {adjective} {patty}버거"
        traits = ["CHEESY"] if extra == "치즈" else []
        if sauce == "매콤": traits.append("SPICY")
        if adjective == "더블": traits.append("THICK_PATTY")
        if patty == "소고기": traits.append("JUICY")
        if adjective == "크리스피": traits.append("CRISPY")
        menus.append({"id": id_base+i+1, "brand_id": brands[i//30]["id"], "name": name,
                      "description": f"{patty} 패티에 {extra}와 {sauce} 소스를 조합한 {adjective} 버거. 개발 실험용 합성 메뉴이며 실제 판매 정보가 아니다.",
                      "price": rng.randrange(39, 140)*100, "source_type": "SYNTHETIC", "source_url": None, "traits": traits})
    return brands, menus


def sql_value(value):
    if value is None: return "NULL"
    if isinstance(value, int): return str(value)
    # Hex literals avoid SQL mode dependent escaping of quotes/backslashes.
    return "CONVERT(X'" + str(value).encode("utf-8").hex() + "' USING utf8mb4)"


class SqlWriter:
    def __init__(self, path, batch=250):
        self.file = path.open("w", encoding="utf-8")
        self.batch = batch
        self.digest = hashlib.sha256()
        self.write("SET NAMES utf8mb4;\n")

    def write(self, text):
        self.digest.update(text.encode("utf-8"))
        self.file.write(text)

    def rows(self, table, columns, rows):
        batch = []
        def flush():
            if batch:
                self.write("START TRANSACTION;\nINSERT INTO " + table + " (" + ",".join(columns) + ") VALUES\n" + ",\n".join(batch) + ";\nCOMMIT;\n")
                batch.clear()
        for row in rows:
            batch.append("(" + ",".join(sql_value(v) for v in row) + ")")
            if len(batch) >= self.batch: flush()
        flush()

    def close(self):
        self.file.close()
        return self.digest.hexdigest()


def review(seed, ordinal, menus, id_base):
    rng = random.Random(f"burger-v{VERSION}:{seed}:{ordinal}")
    # About 70% of reviews target the first 20% of menus; remaining menus still receive traffic.
    hot = max(1, len(menus)//5)
    menu = menus[rng.randrange(hot if rng.random() < .7 else len(menus))]
    rating = rng.choices([1,2,3,4,5], weights=[5,10,25,40,20])[0]
    contexts = ["점심시간", "퇴근 후", "주말 저녁", "운동을 마친 뒤", "친구와의 모임", "산책 도중", "비 오는 날", "영화 보기 전"]
    orders = ["매장에서 먹었다", "포장해서 먹었다", "단품으로 주문했다", "동료와 나눠 먹었다", "천천히 맛을 봤다"]
    textures = ["패티의 씹는 맛이 또렷했다", "빵이 부드러워 먹기 편했다", "소스 향이 먼저 느껴졌다", "재료마다 식감 차이가 있었다", "끝까지 먹으니 소스가 조금 강했다", "먹는 중에 모양이 쉽게 흐트러졌다"]
    balances = ["재료 조합은 내 취향이었다", "담백한 음료와 잘 어울렸다", "첫입과 마지막 입의 인상이 달랐다", "내 기준에는 간이 조금 강했다", "양은 충분했지만 마무리가 아쉬웠다", "다음에는 다른 메뉴와 비교하고 싶다"]
    endings = ["다음에도 주문할 생각이다", "한 번쯤 경험해 볼 만했다", "가격이 오르면 다시 고민하겠다", "다음에는 소스를 적게 요청하고 싶다", "배가 많이 고플 때 더 잘 맞을 것 같다"]
    tags = set(rng.sample(menu["traits"], k=rng.randint(0,len(menu["traits"]))))
    if menu["price"] is not None and menu["price"] <= 6500 and rating >= 4: tags.add("GOOD_VALUE")
    if not menu["traits"] and rng.random() < .2: tags.add(rng.choice(list(TAG_LABELS)))
    title = rng.choice(["다시 먹어본 버거 후기", "한 끼로 먹어본 느낌", "기대와 달랐던 한입", "패티와 소스의 조합", "가격과 맛을 비교해 봄", "포장해서 먹은 후기"]) + f" {ordinal % 997}"
    price_text = f"메뉴 가격 {menu['price']}원을 기준으로 생각했다." if menu["price"] is not None else "가격은 확인하지 못했다."
    text = f"{rng.choice(contexts)}에 {menu['name']}를 {rng.choice(orders)}. {rng.choice(textures)}. {rng.choice(balances)}. {price_text} {rng.choice(endings)}. 개인적인 만족도는 {rating}점이다."
    # Fixed synthetic date: the same ordinal remains identical across all size profiles.
    day = 1 + ordinal % 28
    timestamp = f"2026-01-{day:02d} {ordinal%24:02d}:{ordinal%60:02d}:00.000000"
    return {"id":id_base+ordinal, "menu_id":menu["id"], "user_id":id_base+1+(ordinal-1)%1000,
            "title":title, "content":text, "rating":rating, "tags":sorted(tags), "timestamp":timestamp}


def workload(seed, menus):
    terms = [("치즈",8),("버거",8),("매콤",6),("패티",6),("가성비",5),("육즙",4),("바삭",4),("수제버거",3),
             ("갈릭",3),("치킨",3),("더블",3),("소스",3),("소고기",3),("새우",2),("담백",2),
             ("매콤하고 패티가 두꺼운 버거",1),("가성비 좋은 치즈버거",1),("피클 없는 햄버거",1),("존재하지않는메뉴xyz",1)]
    queries = [{"id":f"term-{i+1:03d}", "keyword":term, "weight":weight, "sort":"relevance"} for i,(term,weight) in enumerate(terms)]
    for i,m in enumerate(menus[:20]):
        queries.append({"id":f"menu-{i+1:03d}","keyword":m["name"],"menuId":m["id"],"brandId":m["brand_id"],"weight":2,"sort":"recent"})
    for i,term in enumerate(["점심시간","퇴근 후","주말 저녁","패티의 씹는 맛","빵이 부드러워","포장해서","소스 향","가격이 오르면","재료 조합","내 취향","처음 보는 조합"]):
        queries.append({"id":f"context-{i+1:03d}","keyword":term,"weight":1,"sort":"relevance"})
    return {"schemaVersion":1,"seed":seed,"queries":queries}


def generate(output, profile, seed=20261105, comments_per_review=0, id_base=1000000000, real_csv=None):
    if profile not in PROFILES or comments_per_review not in (0,1,2): raise ValueError("invalid profile or comments ratio")
    if not 1 <= id_base <= 8000000000000000000: raise ValueError("invalid ID base")
    output = Path(output)
    if output.exists() and any(output.iterdir()): raise ValueError("output directory must be empty")
    output.mkdir(parents=True,exist_ok=True)
    brands, menus = catalog(seed,id_base,real_csv)
    reviews = PROFILES[profile]
    catalog_bytes=json.dumps({"brands":brands,"menus":menus},ensure_ascii=False,sort_keys=True).encode()
    catalog_hash=hashlib.sha256(catalog_bytes).hexdigest()
    dump(output/"catalog.json",{"brands":brands,"menus":menus})
    writer=SqlWriter(output/"dataset.sql")
    date="2026-01-01 00:00:00.000000"
    writer.rows("brand",["brand_id","name","created_at","updated_at"],((b["id"],b["name"],date,date) for b in brands))
    writer.rows("menu",["menu_id","brand_id","name","description","price","source_type","source_url","created_at","updated_at"],
                ((m["id"],m["brand_id"],m["name"],m["description"],m["price"],m["source_type"],m["source_url"],date,date) for m in menus))
    # Deliberately unusable password: synthetic authors are for read-only search, not authentication.
    writer.rows("users",["user_id","email","password","nickname","created_at","updated_at"],
                ((id_base+i,f"burger-bench-{seed}-{i}@example.invalid","!benchmark-account-disabled",f"실험{i:06d}",date,date) for i in range(1,1001)))
    def posts():
        for i in range(1,reviews+1):
            v=review(seed,i,menus,id_base)
            yield (v["id"],v["user_id"],v["menu_id"],v["rating"],v["title"],v["content"],0,0,comments_per_review,v["timestamp"],v["timestamp"])
    writer.rows("post",["post_id","user_id","menu_id","rating","title","content","view_count","like_count","comment_count","created_at","updated_at"],posts())
    def tags():
        for i in range(1,reviews+1):
            v=review(seed,i,menus,id_base)
            for tag in v["tags"]: yield (v["id"],tag)
    writer.rows("post_tag",["post_id","tag"],tags())
    comments=["패티 식감에 대한 의견이 궁금하다.","다른 지점과 비교해서 먹어 보고 싶다.","포장해서 먹었을 때도 비슷한지 궁금하다.","가격과 양을 같이 보니 도움이 됐다."]
    def comment_rows():
        for i in range(1,reviews+1):
            for j in range(comments_per_review):
                ordinal=(i-1)*comments_per_review+j+1
                yield (id_base+ordinal,id_base+i,id_base+1+(i+j)%1000,comments[(i+j)%len(comments)],date,date)
    if comments_per_review: writer.rows("comment",["comment_id","post_id","user_id","content","created_at","updated_at"],comment_rows())
    sql_hash=writer.close()
    corpus=workload(seed,menus)
    dump(output/"workload.json",corpus)
    corpus_hash=hashlib.sha256((output/"workload.json").read_bytes()).hexdigest()
    # Empty grades are intentional: lexical matches are not human relevance judgments.
    templates=[]
    for target in ["menus","reviews"]:
        for i,q in enumerate(corpus["queries"][:50]):
            templates.append({"id":f"{target}-{i+1:03d}","target":target,"keyword":q["keyword"],"judged":False,"grades":{},"intent":"검수 후 구체적인 검색 의도를 입력", "expectedEmpty":False})
    dump(output/"judgments-template.json",{"schemaVersion":1,"datasetSha256":sql_hash,"queries":templates})
    manifest={"schemaVersion":1,"generatorVersion":VERSION,"profile":profile,"seed":seed,"idBase":id_base,
              "reviewSourceType":"SYNTHETIC","catalogSourceType":"REAL" if real_csv else "SYNTHETIC",
              "counts":{"brands":len(brands),"menus":len(menus),"users":1000,"reviews":reviews,"comments":reviews*comments_per_review},
              "catalogSha256":catalog_hash,"datasetSha256":sql_hash,"workloadSha256":corpus_hash,
              "files":{"dataset.sql":(output/"dataset.sql").stat().st_size},"commentsPerReview":comments_per_review}
    dump(output/"manifest.json",manifest)
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",required=True,type=Path)
    parser.add_argument("--profile",choices=PROFILES,default="10k")
    parser.add_argument("--seed",type=int,default=20261105)
    parser.add_argument("--comments-per-review",choices=[0,1,2],type=int,default=0)
    parser.add_argument("--id-base",type=int,default=1000000000)
    parser.add_argument("--real-catalog",type=Path,help="CSV: brand,name,description,price,source_url; provenance must be manually verified")
    args=parser.parse_args()
    try: manifest=generate(args.output,args.profile,args.seed,args.comments_per_review,args.id_base,args.real_catalog)
    except (ValueError,KeyError) as e: parser.error(str(e))
    print(json.dumps(manifest,ensure_ascii=False,indent=2))

if __name__=="__main__": main()
