import os, subprocess, pathlib, json, shutil
root=pathlib.Path.cwd(); lab=root/'.test-lab/l'
ev=pathlib.Path('/home/kalvira/.no-mistakes/evidence/01M3MVAEX3RFVNZE30S9GA8X8W')
e=os.environ.copy()
for k in list(e):
    if k in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX_PANE') or (k.startswith('FM_') and k.endswith('_OVERRIDE')): e.pop(k,None)
e['PATH']=str(root/'.test-lab/tmux-3.5a')+':'+e['PATH']; e['FM_HOME']=str(lab)
e['TMUX_TMPDIR']=(lab/'state/.fm-lab-tmux-dir').read_text().strip()
e['TMUX']=e['TMUX_TMPDIR']+'/tmux-'+str(os.getuid())+'/fm-lab,0,0'
log=open(ev/'live-cleanup.log','w',buffering=1)
def run(args,rc=0):
    p=subprocess.run([str(a) for a in args],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    print(p.stdout.strip(),flush=True)
    if rc is not None: assert (p.returncode==0)==(rc==0), (args,p.returncode,p.stdout)
    return p.stdout
meta=lab/'state/scout.meta'
project=lab/'projects/project'; project.mkdir(parents=True,exist_ok=True)
run(['git','-C',project,'init','-q'])
other=lab/'projects/slot'; other.mkdir(exist_ok=True)
(other/'uncommitted.txt').write_text('Other worker unfinished work.\n')
(other/'.fm-slot-owner').write_text('task=slot-holder\nhome='+str(lab)+'\n')
run(['tmux','new-window','-d','-t','lab','-n','fm-slot-holder','-c',other,'sleep 600'])
(lab/'state/slot-holder.meta').write_text('window=lab:fm-slot-holder\nworktree='+str(other)+'\nkind=ship\n')
protected={p:p.read_bytes() for p in [other/'uncommitted.txt',other/'.fm-slot-owner',lab/'state/slot-holder.meta']}
base=f'window=lab:fm-scout\nendpoint_task_id=scout\nproject={project}\nkind=scout\nharness=codex\nbackend=tmux\nspawn_gen=s1790630000.123.456\ndecisions_reviewed=1\ndecision_keys=\n'
good=base+'no_worktree=1\n'
meta.write_text(good)
run([root/'bin/fm-tasks-axi.sh','add','scout','Disposable no-worktree scout','--kind','scout'])
run([root/'bin/fm-tasks-axi.sh','start','scout'])
# Reproduce the previous public-interface refusal with the baseline scripts.
bdir=root/'.test-lab/base'; shutil.copytree(root/'bin',bdir/'bin',dirs_exist_ok=True)
for name in ['fm-backend.sh','fm-control.sh','fm-teardown.sh']:
    (bdir/'bin'/name).write_bytes(subprocess.check_output(['git','show','b3dbc67af3414006fff0f9eb5d5d016823a8bfa0:bin/'+name]))
for args in [[bdir/'bin/fm-control.sh','scout','exit'],[bdir/'bin/fm-teardown.sh','scout']]:
    out=run(args,1); assert 'worktree identity' in out
cases={'unmarked':base,'ship':good.replace('kind=scout','kind=ship'),'kindless':good.replace('kind=scout\n',''),'duplicate':good+'no_worktree=1\n','bad-value':good.replace('no_worktree=1','no_worktree=yes'),'conflicting-worktree':good+f'worktree={other}\n','orca':good+'orca_worktree_id=owned-slot\n','wrong-endpoint':good.replace('endpoint_task_id=scout','endpoint_task_id=slot-holder')}
for name,value in cases.items():
    log.write('\nSCENARIO: refuse '+name+'\n'); meta.write_text(value)
    for cmd in [[root/'bin/fm-control.sh','scout','exit'],[root/'bin/fm-teardown.sh','scout']]:
        run(cmd,1); assert meta.read_text()==value
    run(['tmux','has-session','-t','lab:fm-scout'])
    for p,b in protected.items(): assert p.read_bytes()==b
meta.write_text(good)
out=run([root/'bin/fm-teardown.sh','scout'],1); assert 'has no report' in out
report=lab/'data/scout/report.md'; report.parent.mkdir(exist_ok=True); report.write_text('# Scout report\nInvestigation complete. Preserve this work product.\n')
meta.write_text(good.replace('decisions_reviewed=1','decisions_reviewed=0'))
run([root/'bin/fm-teardown.sh','scout'],1)
meta.write_text(good)
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
