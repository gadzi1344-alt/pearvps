// Appearance is a browser-local preference, never an account or security setting.
export function createAppearance({dialog,verificationHTML,bindVerification}) {
  const key='pear.appearance.v1';
  let value={liquid:false,snow:true};
  try { const saved=JSON.parse(localStorage.getItem(key)||'null'); if(saved&&typeof saved==='object'){if(typeof saved.liquid==='boolean')value.liquid=saved.liquid;if(typeof saved.snow==='boolean')value.snow=saved.snow} } catch (_) {}
  let layer=document.querySelector('.pear-snow');
  if(!layer){
    layer=document.createElement('div');layer.className='pear-snow';layer.setAttribute('aria-hidden','true');
    for(let i=0;i<30;i++){
      const flake=document.createElement('span');
      flake.style.setProperty('--x',`${(i*37+7)%100}%`);
      flake.style.setProperty('--size',`${2+(i%3)}px`);
      flake.style.setProperty('--duration',`${15+(i*7)%13}s`);
      flake.style.setProperty('--delay',`${-((i*11)%28)}s`);
      flake.style.setProperty('--drift',`${(i%2?1:-1)*(15+(i*13)%40)}px`);
      layer.appendChild(flake);
    }
    document.body.prepend(layer);
  }
  function apply(){document.body.classList.toggle('pear-liquid',value.liquid);layer.hidden=!value.snow}
  function save(){try{localStorage.setItem(key,JSON.stringify(value))}catch(_){}apply()}
  function open(){
    const m=dialog('Настройки',`<div class="tabs settings-tabs" role="tablist" aria-label="Разделы настроек"><button type="button" role="tab" id="settings-tab-appearance" aria-controls="settings-panel-appearance" aria-selected="true" class="tab active" data-settings-tab="appearance">Оформление</button><button type="button" role="tab" id="settings-tab-verification" aria-controls="settings-panel-verification" aria-selected="false" class="tab" data-settings-tab="verification">Верификация</button></div><div role="tabpanel" id="settings-panel-appearance" aria-labelledby="settings-tab-appearance"><section class="appearance-settings" aria-labelledby="appearance-heading"><div class="settings-kicker">ТВОЁ ПРОСТРАНСТВО</div><h3 id="appearance-heading">Оформление</h3><p class="settings-intro">Сделай Pear уютнее — выбери эффекты, которые нравятся тебе.</p><div class="settings-options"><label class="settings-option"><span class="settings-option-icon liquid-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 2.8c3.9 4.6 6.5 7.8 6.5 11.2a6.5 6.5 0 0 1-13 0C5.5 10.6 8.1 7.4 12 2.8Z"/><path d="M8.8 14a3.3 3.3 0 0 0 3.2 3.3"/></svg></span><span class="settings-copy"><strong>Liquid Glass</strong><small>Прозрачное стекло, светлые края и мягкое размытие</small></span><input type="checkbox" class="settings-switch" id="setting-liquid" aria-label="Включить Liquid Glass"></label><label class="settings-option"><span class="settings-option-icon snow-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 3v18M4.2 7.5l15.6 9M4.2 16.5l15.6-9M9.5 4.8 12 7l2.5-2.2M9.5 19.2 12 17l2.5 2.2"/></svg></span><span class="settings-copy"><strong>Снег на фоне</strong><small>Лёгкие снежинки на страницах</small></span><input type="checkbox" class="settings-switch" id="setting-snow" aria-label="Включить снег на фоне"></label></div><p class="settings-foot">Настройки сохраняются в этом браузере. Если в системе включено уменьшение движения, анимации отключаются.</p></section></div><div role="tabpanel" id="settings-panel-verification" aria-labelledby="settings-tab-verification" hidden>${verificationHTML()}</div>`);
    m.querySelector('.modal').classList.add('settings-modal');
    m.querySelectorAll('[data-settings-tab]').forEach(button=>button.onclick=()=>{const tab=button.dataset.settingsTab;m.querySelectorAll('[data-settings-tab]').forEach(b=>{const active=b.dataset.settingsTab===tab;b.classList.toggle('active',active);b.setAttribute('aria-selected',String(active))});m.querySelector('#settings-panel-appearance').hidden=tab!=='appearance';m.querySelector('#settings-panel-verification').hidden=tab!=='verification'});
    bindVerification(m);
    for(const name of ['liquid','snow']){const input=m.querySelector(`#setting-${name}`);input.checked=value[name];input.addEventListener('change',()=>{value[name]=input.checked;save()})}
  }
  apply();return {open};
}
