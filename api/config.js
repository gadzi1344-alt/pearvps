module.exports = function handler(req,res) {
  res.setHeader('Cache-Control','no-store');
  const url=(process.env.SUPABASE_URL||'').replace(/\/+$/,'');
  const key=process.env.SUPABASE_ANON_KEY||'';
  let isPublic=key.startsWith('sb_publishable_');
  if(!isPublic && key.split('.').length===3) {try {isPublic=JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString('utf8')).role==='anon'}catch{}}
  if(!/^https:\/\/[a-z0-9.-]+(?::\d+)?$/i.test(url)||!isPublic) return res.status(503).json({error:'Укажите SUPABASE_URL и публичный ключ SUPABASE_ANON_KEY на сервере.'});
  return res.status(200).json({url,key});
};
