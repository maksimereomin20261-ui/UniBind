const {chromium}=require('playwright');
const fs=require('fs'),path=require('path');
const {pathToFileURL}=require('url');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined,headless:true,args:['--no-sandbox']});
 const out=[];
 for(const width of [1280,1024,390]){
  const page=await browser.newPage({viewport:{width,height:800}});
  const errors=[], failed=[];
  page.on('pageerror',e=>errors.push(e.message)); page.on('requestfailed',r=>failed.push(r.url()));
  await page.route(/^https?:/,r=>r.abort());
  await page.addInitScript(()=>{window.__messages=[];window.__hostHandlers=[];window.chrome=window.chrome||{};window.chrome.webview={postMessage:m=>window.__messages.push(m),addEventListener:(t,f)=>window.__hostHandlers.push(f)};window.__receive=d=>window.__hostHandlers.forEach(f=>f({data:d}));});
  await page.goto(pathToFileURL(path.join(__dirname,'..','ui','ui.html')).href);
  await page.waitForTimeout(100);
  const checks=await page.evaluate(async()=>{
   const checks=[];function check(name,value){checks.push({name,pass:!!value});}
   const bad='<img src=x onerror="window.__injected=1">';
   const fixture={profile:{name:'Тест',organization:'Организация',rank:'Ранг',targetId:'42'},binderEnabled:true,profiles:{active:1,list:[{label:'Тест',name:'Тест',organization:'Организация',rank:'Ранг'}]},overlayVisible:false,stats:{totalSent:0,stat1:0,stat2:0,stat3:0,stat4:0,stat5:0},settings:{chatKey:'t',baseDelay:2300,afterChatDelay:300,afterEnterDelay:400,patientFormat:'plain',onlyGTA:true,jitter:0},overlaySettings:{enabled:true,hotkey:'F10',stopHotkey:'Backspace',idInputHotkey:'p',modeHotkey:'m',opacity:235,width:260,height:-1,x:-1,y:20,screenW:1920,screenH:1080,showId:true,hints:'all',mode:'full',visible:false},categories:[{name:'Основные',icon:'fa-bolt'}],variables:[{name:'VAR',value:'Значение'}],binds:[{id:1,name:'Тестовый бинд',hotkey:'F2',enabled:true,category:'Основные',statType:'',showInOverlay:true,sortOrder:1,preview:'/me текст {T}',lineCount:1,lines:[{text:'/me текст {T}',delay:2300}]}]};
   window.__receive(JSON.stringify(fixture));
   check('data render',document.querySelector('#bindsList').textContent.includes('Тестовый бинд'));
   const ids=[...document.querySelectorAll('[id]')].map(e=>e.id);check('unique HTML ids',new Set(ids).size===ids.length);
   check('no horizontal page overflow',document.documentElement.scrollWidth<=innerWidth);
   openUnifiedSettings('binder');
   check('settings starts clean',!settingsFormChanged('binder'));
   document.getElementById('setBaseDelay').value='2400';refreshSettingsSaveButtons();
   check('settings dirty',settingsFormChanged('binder'));
   saveSettings();check('settings command sent',window.__messages.at(-1).startsWith('save_settings__|~|'));
   check('settings pending',!!SETTINGS_SAVE.binder.pending);
   window.__receive('settings_error:Проверка');check('settings retry preserved',!SETTINGS_SAVE.binder.pending&&settingsFormChanged('binder'));
   saveSettings();window.__receive('settings_saved');check('settings acknowledgment',!settingsFormChanged('binder'));
   document.getElementById('setBaseDelay').value='2500';refreshSettingsSaveButtons();saveSettings();document.getElementById('setBaseDelay').value='2600';window.__receive('settings_saved');check('edits during save preserved',settingsFormChanged('binder'));
   closeUnifiedSettings();openUnifiedSettings('binder');check('unsaved close reverts',document.getElementById('setBaseDelay').value==='2500');
   switchSettingsTab('overlay');
   const opacity=document.getElementById('ovOpacity');opacity.value='80';opacity.dispatchEvent(new Event('input',{bubbles:true}));
   check('opacity preview',window.__messages.some(m=>m==='preview_overlay_opacity:80'));
   saveOverlaySettings();check('overlay command sent',window.__messages.at(-1).startsWith('save_overlay_settings__|~|'));
   window.__receive('overlay_settings_saved');check('overlay acknowledgment',!settingsFormChanged('overlay'));
   closeUnifiedSettings();check('opacity preview cleared',window.__messages.includes('clear_overlay_opacity_preview'));
   for(const text of ['|~|','%7C','~ub2~literal','Русский "текст" \\ %25','a|~|%7C~ub2~']){
    const m=buildSaveBindMsg({...fixture.binds[0],name:text,lines:[{text,delay:0}]});
    const parts=m.split('|~|').map((v,i)=>i>0&&v.startsWith('~ub2~')?v.slice(5).replaceAll('%7C','|').replaceAll('%25','%'):v);
    check('protocol roundtrip '+text,parts[2]===text&&parts[9]===text&&parts.length===11);
   }
   openEditor(1);check('editor opens',document.getElementById('editModal').classList.contains('active'));
   document.getElementById('editName').value='Изменённый бинд';saveEditor();check('bind save command',window.__messages.at(-1).startsWith('save_bind|~|'));
   window.__receive('bind_saved:1');check('editor closes on acknowledgment',!document.getElementById('editModal').classList.contains('active'));
   exportConfig();check('export command',window.__messages.at(-1)==='export_config');importConfig();check('import command',window.__messages.at(-1)==='import_config');
   fixture.binds[0].name=bad;fixture.binds[0].preview=bad;fixture.binds[0].lines[0].text=bad;fixture.profile.name=bad;fixture.categories[0].name=bad;fixture.variables[0].value=bad;
   window.__receive(JSON.stringify(fixture));renderBackupsList([{file:'a.medbind',label:bad,time:'2026-11-01'}]);openEditor(1);openVarsEditor();
   await new Promise(r=>setTimeout(r,100));check('HTML injection blocked',!window.__injected&&!document.querySelector('img[onerror]'));
   return checks;
  });
  out.push({width,checks,errors,failed});await page.close();
 }
 await browser.close();fs.writeFileSync(path.join(__dirname,'browser-results.json'),JSON.stringify(out,null,2));
 console.log(JSON.stringify(out.map(x=>({width:x.width,passed:x.checks.filter(c=>c.pass).length,total:x.checks.length,failures:x.checks.filter(c=>!c.pass),errors:x.errors,failedRequests:x.failed})),null,2));
 process.exit(out.some(r=>r.errors.length||r.failed.length||r.checks.some(c=>!c.pass))?1:0);
})().catch(e=>{console.error(e);process.exit(1)});
