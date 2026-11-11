'use strict';
const http=require('node:http');
const fs=require('node:fs');
const path=require('node:path');
const config=require('./api/config');
const deleteAccount=require('./api/delete-account');
const root=__dirname;
const files=new Set(['/index.html','/app.js','/appearance.js','/chat.js','/notifications.js','/style.css','/favicon.ico','/manifest.webmanifest']);
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png','.jpg':'image/jpeg','.webp':'image/webp','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
function json(res,status,body){res.statusCode=status;res.setHeader('content-type','application/json; charset=utf-8');res.end(JSON.stringify(body));}
const server=http.createServer(async(req,res)=>{
  res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('X-Frame-Options','DENY');res.setHeader('Cache-Control','no-store');
  res.status=function(code){this.statusCode=code;return this};res.json=function(obj){this.setHeader('content-type','application/json; charset=utf-8');this.end(JSON.stringify(obj));return this};
  let url;try{url=new URL(req.url,'http://localhost')}catch{return json(res,400,{error:'Bad request'})}
  if(url.pathname==='/api/config'){if(req.method!=='GET')return json(res,405,{error:'Method not allowed'});return config(req,res)}
  if(url.pathname==='/api/delete-account'){try{return await deleteAccount(req,res)}catch{return json(res,500,{error:'Server error'})}}
  if(req.method!=='GET'&&req.method!=='HEAD')return json(res,405,{error:'Method not allowed'});
  const file=url.pathname==='/'?'/index.html':url.pathname;
  if(!files.has(file)&&!/^\/assets\/[a-zA-Z0-9_-]+\.(png|jpg|webp)$/.test(file))return json(res,404,{error:'Not found'});
  const full=path.join(root,file);fs.readFile(full,(err,data)=>{if(err)return json(res,404,{error:'Not found'});res.setHeader('content-type',types[path.extname(file)]||'application/octet-stream');res.statusCode=200;if(req.method==='HEAD')return res.end();res.end(data)});
});
const port=Number(process.env.PORT||3000),host=process.env.HOST||'127.0.0.1';
server.listen(port,host,()=>console.log(`Pear listening on ${host}:${port}`));
