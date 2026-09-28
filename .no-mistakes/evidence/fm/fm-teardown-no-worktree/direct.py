import os, subprocess, pathlib, json, shutil
root=pathlib.Path.cwd(); lab=root/'.test-lab/l'
ev=pathlib.Path('/home/kalvira/.no-mistakes/evidence/01M3MVAEX3RFVNZE30S9GA8X8W')
e=os.environ.copy()
for k in list(e):
    if k in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX_PANE') or (k.startswith('FM_') and k.endswith('_OVERRIDE')): e.pop(k,None)
e['PATH']=str(root/'.test-lab/tmux-3.5a')+':'+e['PATH']; e['FM_HOME']=str(lab)
e['TMUX_TMPDIR']=(lab/'state/.fm-lab-tmux-dir').read_text().strip()
e['TMUX']=e['TMUX_TMPDIR']+'/tmux-'+str(os.getuid())+'/fm-lab,0,0'
log=open(ev/'live-cleanup.log','a',buffering=1)
def run(args,rc=0):
    p=subprocess.run([str(a) for a in args],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    print(p.stdout.strip(),flush=True)
    if rc is not None: assert (p.returncode==0)==(rc==0), (args,p.returncode,p.stdout)
    return p.stdout

import time
for id,window in [('direct-scout',True),('windowless-scout',False)]:
    d=lab/'data'/id; d.mkdir(exist_ok=True)
    report=d/'report.md'; report.write_text('# Finished report\nPreserve this report.\n')
    meta=lab/'state'/(id+'.meta')
    text=f'project={lab}/projects/project\nkind=scout\nharness=codex\nbackend=tmux\nspawn_gen=s1790630000.123.999\ndecisions_reviewed=1\ndecision_keys=\nno_worktree=1\n'
    if window:
        run(['tmux','new-window','-d','-t','lab','-n','fm-'+id,'-c',root])
        run(['tmux','send-keys','-t','lab:fm-'+id,'-l','codex --disable hooks -c check_for_update_on_startup=false'])
        run(['tmux','send-keys','-t','lab:fm-'+id,'Enter'])
        time.sleep(3)
        run(['tmux','capture-pane','-p','-t','lab:fm-'+id])
        text+=f'window=lab:fm-{id}\nendpoint_task_id={id}\n'
    meta.write_text(text)
    run([root/'bin/fm-tasks-axi.sh','add',id,'Disposable scout cleanup','--kind','scout'])
    run([root/'bin/fm-tasks-axi.sh','start',id])
    before=report.read_bytes()
    run([root/'bin/fm-teardown.sh',id])
    assert not meta.exists() and report.read_bytes()==before
    if window: run(['tmux','has-session','-t','lab:fm-'+id],1)
    run([root/'bin/fm-tasks-axi.sh','show',id])
    run(['tmux','has-session','-t','lab:fm-slot-holder'])
    log.write('VERIFIED '+id+': metadata removed, report preserved, other endpoint remains.\n')
shutil.copyfile(lab/'data/backlog.md',ev/'backlog-after.md')
