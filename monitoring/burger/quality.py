#!/usr/bin/env python3
"""Human-judged relevance evaluation, separate from load testing. No auto-generated truth labels."""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import urllib.parse
import urllib.request


def score(ids, grades, k=10):
    if len(ids)!=len(set(ids)): raise ValueError("duplicate document IDs in results")
    top=ids[:k]
    precision=sum(grades.get(str(i),0)>0 for i in top)/k
    dcg=sum((2**grades.get(str(doc),0)-1)/math.log2(rank+2) for rank,doc in enumerate(top))
    ideal=sum((2**grade-1)/math.log2(rank+2) for rank,grade in enumerate(sorted(grades.values(),reverse=True)[:k]))
    return {"precisionAt10":precision,"ndcgAt10":dcg/ideal if ideal else 0.0}


def evaluate(base_url, judgments, allow_unjudged=False, fetch=None):
    if judgments.get("schemaVersion")!=1 or not judgments.get("datasetSha256"): raise ValueError("datasetSha256 and schemaVersion=1 are required")
    if not judgments.get("queries"): raise ValueError("queries must not be empty")
    def retrieve(path):
        with urllib.request.urlopen(base_url.rstrip('/')+path,timeout=30) as response:
            return json.load(response)
    fetch=fetch or retrieve
    rows=[];seen=set();intents=set();aggregate=[];negative=[]
    for q in judgments["queries"]:
        if q["id"] in seen: raise ValueError("duplicate query ID")
        seen.add(q["id"])
        identity=(q["target"],q["keyword"].strip(),json.dumps(q.get("filters",{}),sort_keys=True))
        if identity in intents: raise ValueError("duplicate target/keyword/filter evaluation")
        intents.add(identity)
        if not q.get("judged"):
            rows.append({"id":q["id"],"status":"needs-human-judgment"});continue
        if q["target"] not in ("menus","reviews") or not q["keyword"].strip(): raise ValueError("invalid target or keyword")
        grades=q["grades"]
        if any(type(g)!=int or g<0 or g>3 for g in grades.values()): raise ValueError("grades must be integers 0..3")
        is_negative=q.get("expectedEmpty",False)
        if is_negative and any(grades.values()): raise ValueError("negative query has relevant documents")
        if not is_negative and not any(grades.values()): raise ValueError("positive query needs at least one relevant document")
        params={"keyword":q["keyword"],"limit":10,"sort":"relevance"}
        filters=q.get("filters",{})
        allowed={"brandId","maxPrice"} if q["target"]=="menus" else {"menuId"}
        if set(filters)-allowed: raise ValueError("unsupported evaluation filter")
        if any(type(value)!=int or value<(0 if key=="maxPrice" else 1) for key,value in filters.items()): raise ValueError("invalid evaluation filter")
        params.update(filters)
        path='/v1/menus' if q["target"]=='menus' else '/v1/posts/search'
        try:
            payload=fetch(path+'?'+urllib.parse.urlencode(params))
            if payload.get("code") is not None: raise ValueError("API returned an error payload")
            ids=[str(d["id"]) for d in payload["data"]["content"]]
            if len(ids)>10 or len(ids)!=len(set(ids)): raise ValueError("invalid result size or duplicate IDs")
            unjudged=[d for d in ids if d not in grades]
            row={"id":q["id"],"target":q["target"],"keyword":q["keyword"],"results":ids,"unjudgedIds":unjudged}
            if is_negative:
                row.update(status="evaluated",emptyCorrect=not ids);negative.append(not ids)
            elif unjudged and not allow_unjudged:
                row["status"]="needs-pool-judgment"
            else:
                row.update(score(ids,grades),status="provisional" if unjudged else "evaluated");aggregate.append(row)
            rows.append(row)
        except Exception as e:
            rows.append({"id":q["id"],"status":"retrieval-failed","error":str(e)})
    complete=all(row["status"]=="evaluated" for row in rows)
    return {"schemaVersion":1,"baseUrl":base_url,"datasetSha256":judgments["datasetSha256"],"complete":complete,
            "timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat(),"queries":rows,
            "aggregate":None if not complete else {"positiveQueries":len(aggregate),"negativeQueries":len(negative),
              "precisionAt10":sum(v["precisionAt10"] for v in aggregate)/len(aggregate) if aggregate else None,
              "ndcgAt10":sum(v["ndcgAt10"] for v in aggregate)/len(aggregate) if aggregate else None,
              "emptyAccuracy":sum(negative)/len(negative) if negative else None}}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url',required=True)
    parser.add_argument('--judgments',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--allow-unjudged',action='store_true',help='capture provisional rows; aggregate remains absent')
    args=parser.parse_args()
    if not args.base_url.startswith(('http://','https://')):parser.error('base URL must use HTTP(S)')
    raw=args.judgments.read_bytes()
    try: report=evaluate(args.base_url,json.loads(raw),args.allow_unjudged)
    except (ValueError,KeyError) as e:parser.error(str(e))
    report['judgmentsSha256']=hashlib.sha256(raw).hexdigest()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({"complete":report['complete'],"aggregate":report['aggregate']},ensure_ascii=False))
    raise SystemExit(0 if report['complete'] else 2)

if __name__=='__main__':main()
