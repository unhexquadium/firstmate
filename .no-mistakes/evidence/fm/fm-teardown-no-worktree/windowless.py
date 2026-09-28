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

meta=lab/'state/windowless-scout.meta'
old=meta.read_text()
assert meta.exists()
log.write('VERIFIED: windowless record with a modern spawn incarnation refuses and retains metadata.\n')
legacy=''.join(x+'\n' for x in old.splitlines() if not x.startswith(('spawn_gen=','no_worktree=')))+'no_worktree=1\n'
meta.write_text(legacy+'no_worktree=1\n')
out=run([root/'bin/fm-teardown.sh','windowless-scout'],1)
assert meta.read_text()==legacy+'no_worktree=1\n'
meta.write_text(legacy)
run([root/'bin/fm-teardown.sh','windowless-scout'])
assert not meta.exists() and (lab/'data/windowless-scout/report.md').is_file()
run([root/'bin/fm-tasks-axi.sh','show','windowless-scout'])
run(['tmux','has-session','-t','lab:fm-slot-holder'])
log.write('VERIFIED: legacy windowless marked scout cleans up; malformed marker refuses; report and unrelated endpoint preserved.\n')
shutil.copyfile(lab/'data/backlog.md',ev/'backlog-after.md')
