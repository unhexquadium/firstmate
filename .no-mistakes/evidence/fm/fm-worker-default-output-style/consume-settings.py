import json, os, pathlib, shutil, subprocess
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6Q06JZZDJJJ772D774BMZXX')
consumer=root/'.nm-style-tmp/consumer'
settings=consumer/'.claude/settings.json'
settings.write_text(json.dumps({'outputStyle':'orchestrator','disableAllHooks':True}))
local=consumer/'.claude/settings.local.json'
rows=[]
cases=[('control',None,'orchestrator'),('ship-inline','dispatch-0-settings.json','default'),('scout-inline','dispatch-1-settings.json','default'),('keep-trailers-inline','dispatch-2-settings.json','default'),('secondmate-inline','dispatch-3-settings.json','orchestrator'),('t3-ship-local','t3-0-local.json','default'),('t3-scout-local','t3-1-local.json','default'),('t3-secondmate-local','t3-secondmate-local.json','orchestrator')]
for name,source,expected in cases:
    local.unlink(missing_ok=True)
    args=['claude','-p','Reply with one word only.','--setting-sources','project,local','--output-format','stream-json','--verbose','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--no-session-persistence']
    if source:
        if name.endswith('-local'): shutil.copyfile(evidence/source,local)
        else: args+=['--settings',str(evidence/source)]
    proc=subprocess.run(args,cwd=consumer,text=True,capture_output=True,timeout=50)
    (evidence/(name+'.jsonl')).write_text(proc.stdout)
    (evidence/(name+'.stderr')).write_text(proc.stderr)
    events=[json.loads(line) for line in proc.stdout.splitlines() if line.startswith('{')]
    init=next((x for x in events if x.get('type')=='system' and x.get('subtype')=='init'),{})
    result=next((x for x in events if x.get('type')=='result'),{})
    row={'scenario':name,'source':source,'expected':expected,'actual':init.get('output_style'),'exit_code':proc.returncode,'is_error':result.get('is_error'),'reply':result.get('result'),'command':args,'cwd':str(consumer)}
    rows.append(row)
    (evidence/'consumer-results.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(json.dumps({k:v for k,v in row.items() if k not in ('command','cwd')}),flush=True)
    assert proc.returncode==0 and result.get('is_error') is False and init.get('output_style')==expected,row
local.unlink(missing_ok=True)
