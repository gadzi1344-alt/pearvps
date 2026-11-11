// Vercel server-only endpoint. Never place SUPABASE_SERVICE_ROLE_KEY in client code.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow','POST'); return res.status(405).json({error:'Неверный метод.'}); }
  const base=(process.env.SUPABASE_URL||'').replace(/\/+$/,'');
  const anon=process.env.SUPABASE_ANON_KEY||'', service=process.env.SUPABASE_SERVICE_ROLE_KEY||'';
  if (!/^https:\/\/[a-z0-9.-]+(?::\d+)?$/i.test(base) || !anon || !service) return res.status(503).json({error:'Удаление аккаунта ещё не настроено администратором.'});
  const auth=String(req.headers.authorization||'');
  if (!/^Bearer [A-Za-z0-9_.-]+$/.test(auth)) return res.status(401).json({error:'Войдите в аккаунт заново.'});
  const headers={apikey:anon,authorization:auth};
  const adminHeaders={apikey:service,authorization:'Bearer '+service,'content-type':'application/json'};
  try {
    // Auth verifies the access token and determines the only user we can delete.
    const me=await fetch(base+'/auth/v1/user',{headers,redirect:'manual'});
    if (!me.ok) return res.status(401).json({error:'Сессия недействительна. Войдите заново.'});
    const user=await me.json();
    if (!UUID.test(user.id||'')) return res.status(401).json({error:'Не удалось проверить аккаунт.'});
    // Supabase cannot delete a user who still owns Storage objects. Clean files
    // in this app's user folders, including legacy nested folders.
    for (const bucket of ['post-media','profile-media','chat-media']) {
      const queue=[user.id], paths=[];
      while(queue.length){
        const prefix=queue.shift(); let offset=0;
        for(;;){
          const r=await fetch(base+'/storage/v1/object/list/'+bucket,{method:'POST',headers:adminHeaders,body:JSON.stringify({prefix,limit:100,offset,sortBy:{column:'name',order:'asc'}}),redirect:'manual'});
          if(!r.ok) throw Error('list_failed');
          const items=await r.json(); if(!Array.isArray(items)) throw Error('list_failed');
          for(const item of items){
            if(!item.name || item.name.includes('/') || item.name==='.' || item.name==='..') throw Error('invalid_name');
            const path=prefix+'/'+item.name;
            if(item.id) paths.push(path); else queue.push(path);
            if(paths.length+queue.length>10000) throw Error('too_many');
          }
          if(items.length<100) break; offset+=items.length;
          if(offset>10000) throw Error('too_many');
        }
      }
      for(let i=0;i<paths.length;i+=100){
        const r=await fetch(base+'/storage/v1/object/'+bucket,{method:'DELETE',headers:adminHeaders,body:JSON.stringify({prefixes:paths.slice(i,i+100)}),redirect:'manual'});
        if(!r.ok) throw Error('storage_delete_failed');
      }
    }
    const deleted=await fetch(base+'/auth/v1/admin/users/'+encodeURIComponent(user.id),{method:'DELETE',headers:adminHeaders,redirect:'manual'});
    if (!deleted.ok) throw Error('auth_delete_failed');
    return res.status(200).json({ok:true});
  } catch (_) {
    // Never log tokens, service key or full URLs. Some files may already be removed.
    console.error('Account deletion failed; check server configuration and Storage ownership.');
    return res.status(500).json({error:'Не удалось полностью удалить аккаунт. Некоторые файлы могли уже удалиться. Обратитесь к администратору.'});
  }
};
