import concurrent.futures,json,pathlib,subprocess,datetime
base=pathlib.Path(__file__).parent
prs=json.loads((base.parent/'open-prs.json').read_text())
issues=[5220,5215,5132,5115,5083,4908,4445,3877,3730,3671]
work=[]
for p in prs:
 n=p['number']
 work += [(n,'pr-view.json',['gh','pr','view','-R','NVIDIA/NVFlare',str(n),'--json','number,title,body,state,isDraft,createdAt,updatedAt,closedAt,mergedAt,baseRefOid,headRefOid,mergeCommit,url,files,comments,reviews']), (n,'pr-comments.txt',['gh','pr','view','-R','NVIDIA/NVFlare',str(n),'--comments']), (n,'reviews.json',['gh','api','--paginate','--slurp',f'repos/NVIDIA/NVFlare/pulls/{n}/reviews?per_page=100']), (n,'inline-comments.json',['gh','api','--paginate','--slurp',f'repos/NVIDIA/NVFlare/pulls/{n}/comments?per_page=100'])]
for n in issues:
 work += [(n,'issue-view.json',['gh','issue','view','-R','NVIDIA/NVFlare',str(n),'--json','number,title,body,state,createdAt,updatedAt,closedAt,url,labels,comments']), (n,'issue-comments.txt',['gh','issue','view','-R','NVIDIA/NVFlare',str(n),'--comments'])]
for n in issues+[p['number'] for p in prs]:
 work += [(n,'timeline-comments.json',['gh','api','--paginate','--slurp',f'repos/NVIDIA/NVFlare/issues/{n}/comments?per_page=100'])]
def fetch(w):
 n,name,cmd=w
 p=subprocess.run(cmd,capture_output=True,text=True)
 (base/f'{n}-{name}').write_text(p.stdout)
 if p.stderr: (base/f'{n}-{name}.stderr').write_text(p.stderr)
 return dict(number=n,record=name,rc=p.returncode,bytes=len(p.stdout),stderr=p.stderr)
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: results=list(pool.map(fetch,work))
(base/'fetch-results.json').write_text(json.dumps({'fetched_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'results':results},indent=2))
print(json.dumps({'requests':len(results),'failures':[r for r in results if r['rc']],'bytes':sum(r['bytes'] for r in results)},indent=2))
