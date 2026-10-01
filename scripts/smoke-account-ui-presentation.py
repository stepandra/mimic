#!/usr/bin/env python3
"""Behavior-level out-of-order tests of the JS asset served by actual Mist.

Node's deterministic DOM/fetch fixture is synthetic presentation evidence,
not a browser qualification. No API/OAuth request is sent by the JS fixture.
All temporary state is inside this attached worktree's ignored build directory.
"""

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("f05_local_fixture", ROOT / "scripts/smoke-account-ui.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)

HARNESS = r"""
const fs = require('fs');
const vm = require('vm');
const assert = require('assert').strict;
const source = fs.readFileSync(0, 'utf8');
const CODE = 'SYNTHETIC-PRESENTATION-CODE';
const waiting = {accounts:[{id:'synthetic-kimi',credential:'missing_or_unavailable',login:'waiting',
  user_code:CODE,verification_uri:'http://127.0.0.1:43210/verify'}]};
const terminal = {accounts:[{id:'synthetic-kimi',credential:'missing_or_unavailable',login:'cancelled'}]};
const idle = {accounts:[{id:'synthetic-kimi',credential:'oauth',login:'idle'}]};
async function flush() { for (let i=0;i<15;i++) await Promise.resolve(); }
class Element {
  constructor(tag='div') { this.tag=tag;this.children=[];this.events={};this._text='';this.value='';this.hidden=false;this.disabled=false; }
  set textContent(value) { this._text=String(value);this.children=[]; }
  get textContent() { return this._text+this.children.map(c=>c.textContent).join(''); }
  appendChild(value) { this.children.push(value);return value; }
  replaceChildren(...values) { this._text='';this.children=values; }
  addEventListener(name, fn) { this.events[name]=fn; }
  trigger(name) { return this.events[name]({preventDefault(){}}); }
}
function environment() {
  const ids=['notice','accounts','bootstrap','operator','unlock','unlock-form','unlock-submit','refresh','logout'];
  const nodes=Object.fromEntries(ids.map(id=>[id,new Element()]));
  nodes.operator.hidden=true;
  const requests=[],timers=[],documentEvents={},windowEvents={};
  const document={hidden:false,getElementById:id=>nodes[id],createElement:tag=>new Element(tag),
    addEventListener:(name,fn)=>{documentEvents[name]=fn;}};
  const fetch=(path,options)=>new Promise(resolve=>{
    requests.push({path,options,done:false,resolve(value,status=200){
      this.done=true;resolve({ok:status>=200&&status<300,status,json:async()=>value});
    }});
  });
  vm.runInNewContext(source,{
    document,window:{addEventListener:(name,fn)=>{windowEvents[name]=fn;}},
    fetch,Date,Error,
    setTimeout:(fn,delay)=>{timers.push({fn,delay,active:true});return timers.length;},
    clearTimeout:id=>{if(timers[id-1])timers[id-1].active=false;}
  });
  const take=path=>{
    const pending=requests.filter(r=>!r.done&&r.path===path);
    const request=pending[pending.length-1];
    assert(request,'expected pending '+path);
    return request;
  };
  const buttons=()=>{
    const all=[];const walk=node=>{if(node.tag==='button')all.push(node);node.children.forEach(walk);};
    walk(nodes.accounts);return all;
  };
  const button=text=>{
    const value=buttons().find(b=>b.textContent===text);assert(value,'expected '+text);return value;
  };
  const noPrompt=()=>assert(!nodes.accounts.textContent.includes(CODE),'stale verification prompt reached DOM');
  async function unlock(csrf='mock-csrf-A',view=waiting) {
    nodes.bootstrap.value='x'.repeat(43);
    const task=nodes['unlock-form'].trigger('submit');
    assert.equal(nodes.bootstrap.value,'','bootstrap input not cleared before exchange');
    take('/api/session').resolve({csrf,session_expires_in_ms:1800000});
    await flush();
    take('/api/status').resolve(view);
    await task;
    assert.equal(nodes.operator.hidden,false);
  }
  return {nodes,requests,timers,document,documentEvents,windowEvents,take,button,noPrompt,unlock};
}
const tests={
  async old_status_after_cancel() {
    const e=environment();await e.unlock();
    const oldTask=e.nodes.refresh.trigger('click'),old=e.take('/api/status');
    const cancelTask=e.button('Cancel login').trigger('click');
    e.take('/api/cancel').resolve(terminal);await cancelTask;e.noPrompt();
    const scheduled=e.timers.length;
    old.resolve(waiting);await oldTask;e.noPrompt();
    assert.equal(e.timers.length,scheduled,'stale status scheduled a follow-up poll');
  },
  async old_login_after_cancel() {
    const e=environment();await e.unlock('mock-csrf-A',idle);
    const oldTask=e.button('Log in to Kimi').trigger('click'),old=e.take('/api/login');
    const statusTask=e.nodes.refresh.trigger('click');
    e.take('/api/status').resolve(waiting);await statusTask;
    const cancelTask=e.button('Cancel login').trigger('click');
    e.take('/api/cancel').resolve(terminal);await cancelTask;
    const scheduled=e.timers.length;
    old.resolve(waiting);await oldTask;e.noPrompt();
    assert.equal(e.timers.length,scheduled,'stale login scheduled a follow-up poll');
  },
  async old_status_after_logout() {
    const e=environment();await e.unlock();
    const oldTask=e.nodes.refresh.trigger('click'),old=e.take('/api/status');
    const logoutTask=e.nodes.logout.trigger('click');
    e.take('/api/logout').resolve({signed_out:true});await logoutTask;
    old.resolve(waiting);await oldTask;e.noPrompt();
    assert.equal(e.nodes.operator.hidden,true,'old status reopened operator session');
    assert.equal(e.timers.filter(t=>t.active).length,0,'old status scheduled polling after logout');
  },
  async old_401_cannot_clear_or_poll_under_new_session() {
    const e=environment();await e.unlock();
    const oldTask=e.nodes.refresh.trigger('click'),old=e.take('/api/status');
    const logoutTask=e.nodes.logout.trigger('click');
    e.take('/api/logout').resolve({signed_out:true});await logoutTask;
    await e.unlock('mock-csrf-B',idle);
    const scheduled=e.timers.length;
    old.resolve({error:'old session expired'},401);await oldTask;
    assert.equal(e.nodes.operator.hidden,false,'stale 401 cleared the new session');
    assert.equal(e.timers.length,scheduled,'old request scheduled work under new session');
    const freshTask=e.nodes.refresh.trigger('click'),fresh=e.take('/api/status');
    assert.equal(fresh.options.headers['X-CSRF-Token'],'mock-csrf-B','new session used stale capability');
    fresh.resolve(idle);await freshTask;e.noPrompt();
  },
  async hidden_page_drops_late_login_and_poll() {
    const e=environment();await e.unlock('mock-csrf-A',idle);
    const oldTask=e.button('Log in to Kimi').trigger('click'),old=e.take('/api/login');
    e.document.hidden=true;e.documentEvents.visibilitychange();
    const scheduled=e.timers.length;
    old.resolve(waiting);await oldTask;e.noPrompt();
    assert.equal(e.timers.length,scheduled,'hidden page scheduled a stale poll');
  },
  async unchanged_poll_preserves_keyboard_target() {
    const e=environment();await e.unlock('mock-csrf-A',idle);
    const before=e.button('Log in to Kimi');
    const task=e.nodes.refresh.trigger('click');
    e.take('/api/status').resolve(idle);await task;
    assert.equal(e.button('Log in to Kimi'),before,'unchanged poll replaced the focused button');
  }
};
const watchdog=setTimeout(()=>{console.log('presentation harness incomplete');process.exit(1);},10000);
(async()=>{
  let failed=0;
  for(const [name,test] of Object.entries(tests)) {
    try { await test();console.log('PASS '+name); }
    catch(error) { failed++;console.log('FAIL '+name+': '+error.message); }
  }
  console.log(JSON.stringify({axis:'served Mist JS asset + deterministic synthetic DOM/fetch',
    passed:Object.keys(tests).length-failed,failed,browser_qualification:'not performed'}));
  process.exitCode=failed?1:0;
})().catch(()=>{console.log('presentation harness failed');process.exitCode=1;})
  .finally(()=>clearTimeout(watchdog));
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui-command", default=local.DEFAULT_UI)
    args = parser.parse_args()
    scratch = ROOT / "build/account-ui/tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f05-presentation-", dir=scratch) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        fixture = local.Fixture(directory, SimpleNamespace(
            root_command=local.DEFAULT_ROOT, ui_command=args.ui_command, root_ui=False,
        ))
        try:
            fixture.start_ui()
            status, _, source = fixture.http(fixture.ui_port, "GET", "/panel.js")
            assert status == 200
            result = subprocess.run(["node", "-e", HARNESS], cwd=ROOT, env=fixture.env,
                                    input=source, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30)
            local.clean(result.stdout)
            print(result.stdout.decode(), end="")
            assert not any(fixture.provider.counts.values()), "presentation fixture sent provider I/O"
            if result.returncode:
                raise SystemExit(result.returncode)
            summaries = [json.loads(line) for line in result.stdout.decode().splitlines()
                         if line.startswith('{"axis":')]
            assert len(summaries) == 1 and summaries[0]["passed"] == 6 and summaries[0]["failed"] == 0, \
                "presentation harness did not finish all six cases"
        finally:
            fixture.close()


if __name__ == "__main__":
    main()
