import concurrent.futures,json,pathlib,subprocess,datetime
base=pathlib.Path(__file__).parent
work=[]
for n in [5216,5221,5117,5116,5133,5092,4513,3786,3791]:
 work += [(n,'pr-view.json',['gh','pr','view','-R','NVIDIA/NVFlare',str(n),'--json','number,title,body,state,isDraft,createdAt,updatedAt,closedAt,mergedAt,baseRefOid,headRefOid,mergeCommit,url,files,comments,reviews']), (n,'pr-comments.txt',['gh','pr','view','-R','NVIDIA/NVFlare',str(n),'--comments'])]
 for name,endpoint in [('reviews',f'pulls/{n}/reviews'),('inline-comments',f'pulls/{n}/comments'),('timeline-comments',f'issues/{n}/comments')]:work.append((n,name+'.json',['gh','api','--paginate','--slurp',f'repos/NVIDIA/NVFlare/{endpoint}?per_page=100']))
def fetch(w):
 n,name,cmd=w;p=subprocess.run(cmd,capture_output=True,text=True);(base/f'{n}-{name}').write_text(p.stdout)
 return dict(number=n,record=name,rc=p.returncode,bytes=len(p.stdout),stderr=p.stderr)
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:results=list(pool.map(fetch,work))
(base/'fetch-fix-results.json').write_text(json.dumps(results,indent=2));print([r for r in results if r['rc']])
for n in [5216,5221,5117,5116,5133,5092,4513,3786,3791]:
 d=json.loads((base/f'{n}-pr-view.json').read_text());out=[f"# {n}: {d['title']}\n",str({k:d[k] for k in ['state','headRefOid','mergeCommit','mergedAt']}),'\n## Body\n'+d['body']]
 for name in ['timeline-comments','reviews','inline-comments']:
  rows=[r for p in json.loads((base/f'{n}-{name}.json').read_text()) for r in p]
  for r in rows:out.append(f"\n## {name} {r['id']} by {r['user']['login']}; {r.get('html_url','')}; {r.get('state','')}; {r.get('path','')}\n{r.get('body','')}\n")
 (base/f'{n}-readable.md').write_text('\n'.join(out));print(n,len('\n'.join(out)))
