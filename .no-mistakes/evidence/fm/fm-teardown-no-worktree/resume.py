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

meta=lab/'state/scout.meta'
report=lab/'data/scout/report.md'
other=lab/'projects/slot'
protected={p:p.read_bytes() for p in [other/'uncommitted.txt',other/'.fm-slot-owner',lab/'state/slot-holder.meta']}
(lab/'data/scout/brief.md').write_text('# Task\nDisposable finished scout.\n')
out=run([root/'bin/fm-control.sh','scout','relaunch','--note','Cannot relaunch without a local copy'],1); assert 'no recorded worktree' in out
run(['tmux','capture-pane','-p','-t','lab:fm-scout'])
run([root/'bin/fm-control.sh','scout','interrupt'])
out=run([root/'bin/fm-control.sh','scout','exit']); assert 'stopped scout' in out and 'worktree=none' in out
run([root/'bin/fm-control.sh','scout','exit'])
report_bytes=report.read_bytes()
(lab/'state/scout.status').write_text('done: report ready\n')
(lab/'state/scout.turn-ended').touch()
out=run([root/'bin/fm-teardown.sh','scout']); assert 'record marks no worktree' in out
assert not meta.exists() and not (lab/'state/scout.status').exists() and not (lab/'state/scout.turn-ended').exists()
assert report.read_bytes()==report_bytes
run(['tmux','has-session','-t','lab:fm-scout'],1)
run(['tmux','has-session','-t','lab:fm-slot-holder'])
for p,b in protected.items(): assert p.read_bytes()==b
run([root/'bin/fm-tasks-axi.sh','show','scout','--json'])
log.write('VERIFIED: report bytes unchanged; scout volatile metadata/status/turn marker absent; scout endpoint gone; other worker endpoint, metadata, slot claim, and unfinished work unchanged.\n')
shutil.copyfile(report,ev/'retained-report.md')
shutil.copyfile(lab/'data/backlog.md',ev/'backlog-after.md')
print('ALL LIVE SCENARIOS PASSED',flush=True)
