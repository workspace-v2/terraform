#!/usr/bin/env python3
import importlib.util,json,time
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description='Prepare isolated fixtures for ElasticsearchLiveTest; never changes burger-main/dev aliases')
parser.add_argument('--url',required=True)
parser.add_argument('--admin-password-file',required=True,type=Path)
parser.add_argument('--reader-password-file',required=True,type=Path)
parser.add_argument('--receipt',required=True,type=Path)
args=parser.parse_args()
s=importlib.util.spec_from_file_location('indexer',Path(__file__).with_name('burger-search-index.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
c=m.Elastic(args.url,'elastic',m.protected_file(args.admin_password_file).read_text().strip())
prefix='burger-feat9-smoke'
menus=[]
for i,brand,price,name in [(1,1,5000,'cheese burger'),(2,2,9000,'garlic burger'),(3,1,None,'spicy burger')]:
 response=dict(id=i,brandId=brand,brandName='brand '+str(brand),name=name,description='garlic sauce',price=price,sourceType='SYNTHETIC',sourceUrl=None)
 menus.append({'kind':'menus','document':{k:v for k,v in response.items() if k not in ['sourceType','sourceUrl']}})
 menus[-1]['document']['response']=response
reviews=[]
for i,menu,title,content,tags in [(1,1,'garlic review','cheese sauce',[]),(2,1,'other review','garlic sauce',['CHEESY']),(3,2,'garlic burger','garlic',['SPICY'])]:
 response=dict(id=i,menuId=menu,menuName='menu '+str(menu),brandName='brand',rating=4,tags=tags,title=title,createdAt='2026-11-08 12:00:00',likeCount=0,commentCount=0,viewCount=0,author=dict(userId=1,nickname='tester',profileImageUrl=None))
 reviews.append({'kind':'reviews','document':dict(id=i,menuId=menu,menuName=response['menuName'],brandName='brand',title=title,content=content,tags=tags,response=response)})
r=m.reindex(c,iter(menus+reviews),prefix,time.strftime('%Y%m%d%H%M%S'),2)
# Reader can search but must not be able to create indices.
reader=m.Elastic(args.url,'burger_search',m.protected_file(args.reader_password_file).read_text().strip())
assert reader.request('POST','/'+prefix+'-reviews/_search',{'query':{'match_all':{}}})['hits']['total']['value']==3
try:reader.request('PUT','/'+prefix+'-forbidden',m.index_definition('menus'))
except RuntimeError as e:assert '403' in str(e)
else:raise RuntimeError('reader write unexpectedly allowed')
args.receipt.write_text(json.dumps(r,indent=2))
print(json.dumps({'counts':r['counts'],'prefix':prefix,'reader_write_denied':True}))
