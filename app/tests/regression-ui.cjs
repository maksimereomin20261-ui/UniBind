// Developer-only tests. Requires Node.js and Playwright; never starts AutoHotkey.
const {chromium}=require('playwright');
const fs=require('fs'), path=require('path');
const {pathToFileURL}=require('url');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined,headless:true,args:['--no-sandbox']});
 const results=[];
 for(const width of [1280,1024,390]){
  const page=await browser.newPage({viewport:{width,height:800}});const errors=[],failed=[];
  page.on('pageerror',e=>errors.push(e.message));page.on('requestfailed',r=>failed.push(r.url()));
  await page.route(/^https?:/,r=>r.abort());
  await page.addInitScript(()=>{window.__messages=[];window.__handlers=[];window.chrome=window.chrome||{};window.chrome.webview={postMessage:m=>__messages.push(m),addEventListener:(t,f)=>__handlers.push(f)};window.__receive=d=>__handlers.forEach(f=>f({data:d}));});
  await page.goto(pathToFileURL(path.join(__dirname,'..','ui','ui.html')).href);
  const checks=await page.evaluate(()=>{
   const checks=[],check=(name,pass)=>checks.push({name,pass:!!pass});
   const bind={id:1,name:'Тест',hotkey:'',enabled:true,category:'',statType:'',showInOverlay:true,sortOrder:1,preview:'Текст',lines:[{text:'Текст',delay:0}]};
   __receive({binds:[bind],categories:[],profile:{name:'',organization:'',rank:'',targetId:''},variables:[],profiles:{active:1,list:[{label:'Тест'}]}});
   openEditor(1);
   EDIT_LINES=Array.from({length:100},()=>({text:'Строка',delay:0}));addEditLine();check('101st line blocked',EDIT_LINES.length===100);
   saveEditor();check('100 lines submitted',__messages.at(-1).split('|~|')[7]==='100');
   const accepted=[{text:'x'.repeat(4096),delay:120000},{text:'Текст',delay:0},{text:'Текст',delay:1},{text:'Текст',delay:119999}];
   for(const [i,line] of accepted.entries()){
    EDIT_LINES=[line];const before=__messages.length;saveEditor();check('valid boundary '+i,__messages.length===before+1&&__messages.at(-1).startsWith('save_bind|~|'));
   }
   const rejected=[{text:'x'.repeat(4097),delay:0},{text:'Текст',delay:120001},{text:'Текст',delay:-1},{text:'Текст',delay:NaN},{text:'Текст',delay:1.5},{text:'',delay:0},{text:'first\n[Injected]',delay:0},{text:'tab\there',delay:0}];
   for(const [i,line] of rejected.entries()){
    EDIT_LINES=[line];const before=__messages.length;saveEditor();check('invalid line rejected '+i,__messages.length===before);let throws=false;
    try{buildSaveBindMsg({...bind,lines:[line]})}catch{throws=true}check('quick-toggle validation '+i,throws);
   }
   EDIT_LINES=Array.from({length:101},()=>({text:'Строка',delay:0}));let before=__messages.length;saveEditor();check('oversized protocol not sent',before===__messages.length);
   EDIT_LINES=[{text:'Текст',delay:0}];renderEditLines();check('text maxLength',document.querySelector('.line-text').maxLength===4096);check('delay maximum',document.querySelector('.line-delay').max==='120000');
   const delay=document.querySelector('.line-delay');delay.value='';delay.dispatchEvent(new Event('input'));check('empty numeric draft not silently zero',Number.isNaN(EDIT_LINES[0].delay));
   before=__messages.length;saveEditor();check('empty delay save blocked',__messages.length===before);
   EDIT_LINES=[{text:'Текст',delay:0}];saveEditor();__receive('bind_error:Диск недоступен');check('bind error retains editor',document.getElementById('editModal').classList.contains('active'));__receive('bind_saved:1');check('bind ack closes editor',!document.getElementById('editModal').classList.contains('active'));
   openUnifiedSettings('binder');document.getElementById('setChatKey').value='{';document.getElementById('setBaseDelay').value='2401';refreshSettingsSaveButtons();before=__messages.length;saveSettings();check('invalid chat key not sent',__messages.length===before);
   document.getElementById('setChatKey').value='t';saveSettings();check('integer ms without step rounding',!!SETTINGS_SAVE.binder.pending);__receive('settings_error:Диск недоступен');check('native rejection permits retry',!SETTINGS_SAVE.binder.pending&&settingsFormChanged('binder'));closeUnifiedSettings();
   openProfileModal();document.getElementById('profileEditLabel').value='Новый';saveProfile();check('profile open until ack',document.getElementById('profileModal').classList.contains('active'));__receive('profile_saved');check('profile closes on ack',!document.getElementById('profileModal').classList.contains('active'));
   window.__PROFILES__={active:1,list:Array.from({length:50},()=>({label:'Тест'}))};profileCreateMode=false;newProfile();check('51st profile blocked',profileCreateMode===false);
   USER_VARS=Array.from({length:200},(_,i)=>({name:'V'+i,value:'x'}));addVarRow();check('201st variable blocked',USER_VARS.length===200);
   return checks;
  });
  results.push({width,checks,errors,failedRequests:failed});await page.close();
 }
 await browser.close();fs.writeFileSync(path.join(__dirname,'regression-ui-results.json'),JSON.stringify(results,null,2));
 console.log(JSON.stringify(results.map(r=>({width:r.width,passed:r.checks.filter(c=>c.pass).length,total:r.checks.length,failures:r.checks.filter(c=>!c.pass),errors:r.errors,failedRequests:r.failedRequests})),null,2));
 process.exit(results.some(r=>r.errors.length||r.failedRequests.length||r.checks.some(c=>!c.pass))?1:0);
})().catch(e=>{console.error(e);process.exit(1)});
