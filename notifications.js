export function createNotifications({P,esc,avatar,badge,icon,date,check,navigate,draw,toast}){
 const N={rows:[],count:0,loaded:false,error:false,channel:null,timer:null,busy:false,again:false,generation:0};
 const verbs={like:'нравится твоя публикация',follow:'подписался на тебя',comment:'прокомментировал твою публикацию',reply:'ответил на твой комментарий',repost:'сделал репост твоей публикации'};
 const glyph={like:'heart',follow:'user',comment:'comment',reply:'comment',repost:'repost'};
 function paintBadge(){document.querySelectorAll('[data-nav="notifications"]').forEach(button=>{const badge=button.querySelector('.notification-count');if(!badge)return;badge.hidden=N.count<=0;badge.textContent=N.count>99?'99+':String(N.count);button.setAttribute('aria-label',N.count?`Уведомления, непрочитанных: ${N.count}`:'Уведомления');button.title=N.count?`Уведомления: ${N.count} непрочитанных`:'Уведомления'})}
 async function refresh(){
  const uid=P.session?.user?.id;if(!uid||!P.client)return;if(N.busy){N.again=true;return}N.busy=true;const generation=N.generation;
  try{
   const requests=[P.client.from('pear_notifications').select('id',{count:'exact',head:true}).eq('recipient_id',uid).is('read_at',null)];
   if(P.page==='notifications')requests.push(P.client.from('pear_notifications').select('id,kind,actor_id,post_id,comment_id,created_at,read_at,actor:profiles!pear_notifications_actor_id_fkey(id,username,display_name,avatar_path),post:posts(id,body),comment:comments(id,body)').eq('recipient_id',uid).order('created_at',{ascending:false}).limit(80));
   const [countResult,rowsResult]=await Promise.all(requests);if(generation!==N.generation||P.session?.user?.id!==uid)return;if(countResult.error)throw countResult.error;
   N.count=countResult.count||0;paintBadge();
   if(rowsResult){if(rowsResult.error)throw rowsResult.error;N.rows=rowsResult.data||[];N.loaded=true;N.error=false;if(P.page==='notifications')draw()}
  }catch(e){if(generation===N.generation&&P.session?.user?.id===uid&&P.page==='notifications'){N.error=true;draw()}}
  finally{N.busy=false;if(N.again){N.again=false;setTimeout(refresh,0)}}
 }
 function html(){
  const heading=`<header class="topline notification-header"><div><h1>Уведомления</h1><p>Всё важное — в одном месте</p></div>${N.count?'<button type="button" class="quiet notifications-read-all" data-notifications-read-all>Прочитать все</button>':''}</header>`;
  if(N.error)return heading+'<div class="empty">Не удалось загрузить уведомления. Проверь подключение и обновление базы.</div><button class="quiet notifications-retry" data-notifications-retry>Повторить</button>';
  if(!N.loaded)return heading+'<div class="empty">Загружаем уведомления…</div>';
  if(!N.rows.length)return heading+`<div class="notifications-empty"><div class="notifications-empty-icon">${icon('bell')}</div><strong>Здесь пока тихо</strong><p>Лайки, комментарии и новые подписчики появятся здесь.</p></div>`;
  return heading+`<div class="notifications-list">${N.rows.map(n=>{const a=n.actor||{id:n.actor_id,display_name:'Пользователь',username:'user'}, unread=!n.read_at,summary=n.kind==='reply'||n.kind==='comment'?n.comment?.body:(n.kind==='like'||n.kind==='repost')?n.post?.body:'';return `<button type="button" class="notification-item ${unread?'is-unread':''}" data-notification-id="${esc(n.id)}" aria-label="${esc(a.display_name)}: ${esc(verbs[n.kind]||'новое событие')}${unread?', не прочитано':''}"><span class="notification-avatar">${avatar(a)}<span class="notification-kind ${esc(n.kind)}">${icon(glyph[n.kind]||'bell')}</span></span><span class="notification-content"><span class="notification-title"><strong>${esc(a.display_name)}</strong>${badge(a.id)} <span>${esc(verbs[n.kind]||'новое событие')}</span></span>${summary?`<span class="notification-preview">${esc(summary)}</span>`:''}<span class="notification-time">${esc(date(n.created_at))}${unread?' · Новое':''}</span></span>${unread?'<span class="notification-dot" aria-hidden="true"></span>':''}</button>`}).join('')}</div><p class="notification-foot">Показаны последние 80 уведомлений</p>`;
 }
 async function mark(id){check(await P.client.rpc('pear_mark_notifications_read',{p_id:id}));N.rows=N.rows.map(n=>(id===null||n.id===id)?{...n,read_at:n.read_at||new Date().toISOString()}:n);await refresh()}
 function bind(main){main.querySelector('[data-notifications-retry]')?.addEventListener('click',refresh);main.querySelector('[data-notifications-read-all]')?.addEventListener('click',async ev=>{ev.currentTarget.disabled=true;try{await mark(null)}catch(e){ev.currentTarget.disabled=false;toast('Не удалось отметить уведомления прочитанными')}});main.querySelectorAll('[data-notification-id]').forEach(button=>button.onclick=async()=>{const row=N.rows.find(n=>n.id===button.dataset.notificationId);if(!row)return;if(!row.read_at){button.disabled=true;try{await mark(row.id)}catch(e){button.disabled=false;toast('Не удалось отметить уведомление прочитанным');return}}if(row.kind==='follow')navigate('profile',row.actor_id);else if(row.post_id)navigate('post',row.post_id)})}
 function start(){stop();if(!P.session?.user?.id)return;const uid=P.session.user.id;N.channel=P.client.channel('pear-notifications-'+uid).on('postgres_changes',{event:'*',schema:'public',table:'pear_notifications',filter:'recipient_id=eq.'+uid},()=>refresh()).subscribe();N.timer=setInterval(()=>{if(document.visibilityState==='visible')refresh()},15000);refresh()}
 function stop(){N.generation++;if(N.channel&&P.client)P.client.removeChannel(N.channel);N.channel=null;clearInterval(N.timer);N.timer=null;N.rows=[];N.count=0;N.loaded=false;N.error=false;N.again=false;paintBadge()}
 return {html,bind,refresh,start,stop,paintBadge};
}
