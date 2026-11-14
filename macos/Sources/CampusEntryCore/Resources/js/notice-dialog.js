(function(hide){
// 日志前缀是**跨端协议字符串**：Android 宿主按它把本脚本的 console 输出挑进应用日志
// （EntryHost.kt 的 onConsoleMessage）。改名时不能跟着产品显示名走——这里用 ASCII 技术标识，
// 与 exe 文件名、命名空间、数据目录同名同源。改这一行必须同时改 Android 侧的前缀判据。
var LOG='campus-entry 公告弹窗: ';
try{
var MARK='data-campus-hidden';
function dialogs(){
 var out=[],all=document.querySelectorAll('.el-dialog__wrapper');
 for(var i=0;i<all.length;i++){if(all[i].querySelector('.alert-notice-item'))out.push(all[i]);}
 return out;}
function mark(e){if(!e.hasAttribute(MARK))e.setAttribute(MARK,e.style.display||'');}
function restore(){
 var m=document.querySelectorAll('['+MARK+']'),n=0;
 for(var i=0;i<m.length;i++){var e=m[i];e.style.display=e.getAttribute(MARK);e.removeAttribute(MARK);n++;}
 if(document.body.hasAttribute('data-campus-lock')){
  document.body.classList.add('el-popup-parent--hidden');
  document.body.removeAttribute('data-campus-lock');n++;}
 return n;}
function hideAll(){
 var ws=dialogs();
 if(ws.length===0)return 'none';
 var n=0,i,e;
 for(i=0;i<ws.length;i++){e=ws[i];mark(e);if(e.style.display!=='none'){e.style.display='none';n++;}}
 var masks=document.querySelectorAll('.v-modal');
 for(i=0;i<masks.length;i++){e=masks[i];mark(e);if(e.style.display!=='none'){e.style.display='none';n++;}}
 if(document.body.classList.contains('el-popup-parent--hidden')){
  document.body.classList.remove('el-popup-parent--hidden');
  document.body.setAttribute('data-campus-lock','1');n++;}
 return 'hid|'+ws.length+'|'+n;}
var r=hide?hideAll():('restored|'+restore());
if(hide){
 if(!window.__noticeWatch){window.__noticeWatch=true;
  window.__noticeObserver=new MutationObserver(function(){
   if(window.__noticeTimer)return;
   window.__noticeTimer=setTimeout(function(){
    window.__noticeTimer=null;
    try{var x=hideAll();if(x!=='none')console.log(LOG+x);}catch(e){console.log(LOG+'err|'+e);}},400);});
  window.__noticeObserver.observe(document.documentElement,{childList:true,subtree:true});}}
else if(window.__noticeWatch){window.__noticeWatch=false;
 if(window.__noticeObserver)window.__noticeObserver.disconnect();
 if(window.__noticeTimer){clearTimeout(window.__noticeTimer);window.__noticeTimer=null;}}
return r;}catch(e){return 'err|'+e;}})(__HIDE__)
