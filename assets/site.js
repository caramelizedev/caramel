
(() => {
  const root = document.getElementById('caramel-site');

  const routes = {"home":"/","cookbook":"/cookbook/0.4.0/","learn":"/docs/0.4.0/getting-started/","map":"/docs/0.4.0/project-map/","agents":"/docs/0.4.0/agents/","deploy":"/docs/0.4.0/deployment/","crud":"/cookbook/0.4.0/create-a-resource/","json":"/cookbook/0.4.0/return-json/","uploads":"/cookbook/0.4.0/uploads/","jobs":"/cookbook/0.4.0/background-jobs/","webhooks":"/cookbook/0.4.0/webhooks/"};
  function linkify(){root.querySelectorAll('button[data-page]').forEach(button=>{const a=document.createElement('a');for(const attr of button.attributes)a.setAttribute(attr.name,attr.value);a.href=routes[button.dataset.page];a.innerHTML=button.innerHTML;button.replaceWith(a);});}
  new MutationObserver(linkify).observe(root,{childList:true,subtree:true});
  linkify();

  const main = root.querySelector('#c-main');
  const article = root.querySelector('#c-article');
  let currentPage = document.body.dataset.page;
  let recipeFilter = 'all';
  let selectedTask = 'endpoint';
  const story = root.querySelector('#l-story');
  const stage = root.querySelector('.l-sticky');
  const diagram = root.querySelector('.l-diagram');
  const chapters = Array.from(root.querySelectorAll('.l-chapter'));
  const pieces = ['caramel','foam','milk','espresso'].map(name=>root.querySelector('.l-'+name));
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let scrollFrame = 0, activeChapter = -1;
  const clamp = value => Math.max(0,Math.min(1,value));
  const smooth = value => value*value*(3-2*value);
  function updateScroll(){
    scrollFrame=0;
    if(currentPage!=='home')return;
    root.style.setProperty('--header-height',root.querySelector('.c-header').offsetHeight+'px');
    const p=clamp(window.scrollY/Math.max(1,story.offsetHeight-stage.offsetHeight));
    const thresholds=[.015,.22,.40,.58,.80];
    const chapter=thresholds.filter(t=>p>=t).length;
    const starts=[0,.22,.40,.58], lifts=[235,197,154,116], spreads=[16,-10,8,-8];
    pieces.forEach((piece,i)=>{const raw=clamp((p-starts[i])/.16);const amount=reducedMotion.matches?(raw>0?1:0):smooth(raw);piece.style.transform=`translate(${spreads[i]*amount}px,${-lifts[i]*amount}px)`;});
    const framing=reducedMotion.matches?(chapter?1:0):smooth(clamp(p/.16));
    const mobile=root.clientWidth<=700, zoom=mobile?1.15:1.35, lift=mobile?80:130;
    diagram.style.transform=`translateY(${-lift*(1-framing)}px) scale(${zoom-(zoom-1)*framing})`;
    if(chapter!==activeChapter){activeChapter=chapter;chapters.forEach((el,i)=>{el.hidden=i!==chapter;});root.querySelector('#l-current').textContent=String(chapter).padStart(2,'0');story.dataset.chapter=String(chapter);}
  }
  function queueScrollUpdate(){if(!scrollFrame)scrollFrame=requestAnimationFrame(updateScroll);}
  window.addEventListener('scroll',queueScrollUpdate,{passive:true});
  new ResizeObserver(queueScrollUpdate).observe(root);
  reducedMotion.addEventListener('change',queueScrollUpdate);
  const tasks = {
    endpoint:{title:'Add or change an endpoint',files:['config/routes.cr','app/actions/'],detail:'Declare the route, then its typed contract and behavior. Keep the response and failure cases in a request spec.',proof:'frappe routes · frappe check · frappe corretto'},
    data:{title:'Change the data your application stores',files:['app/models/','app/changesets/','db/migrations/'],detail:'Describe the stored shape and write rules, derive the migration, and review it before applying it.',proof:'frappe db diff · frappe migrate · frappe corretto'},
    view:{title:'Change what the browser renders',files:['app/views/','app/assets/'],detail:'Use Blueprint classes for typed HTML and application assets for styles or client behavior.',proof:'frappe check · request spec · browser inspection'},
    job:{title:'Move work into a background job',files:['app/jobs/','spec/'],detail:'Define the job payload and behavior. Enqueue within the intended transaction and test the observable result.',proof:'Corretto session · drain_queue! · database assertion'}
  };
  const recipes = [
    {page:'crud',title:'Create a resource',text:'A small CRUD feature, from model and changeset to a passing request spec.',category:'Data & forms',status:'draft',keywords:'database validation model controller'},
    {page:'json',title:'Return JSON',text:'Use the same action for a browser page and an explicit JSON response.',category:'Requests & responses',status:'draft',keywords:'api endpoint content negotiation'},
    {page:'uploads',title:'Upload and keep a file',text:'Go from a request-scoped temporary file to a complete persistence recipe.',category:'Files',status:'draft',keywords:'storage image multipart upload'},
    {page:'jobs',title:'Run a background job',text:'Connect a transaction, a typed job, and a synchronous test.',category:'Background work',status:'draft',keywords:'queue cold brew worker'},
    {page:'webhooks',title:'Receive a signed webhook',text:'Understand the JSON input and request-policy gaps that need a supported API.',category:'External integrations',status:'gap',keywords:'accept json post api csrf signature'},
    {page:'deploy',title:'Deploy an application',text:'Follow the remaining gates from a local app to a supported production release.',category:'Production',status:'gap',keywords:'ship hosting linux binary release'}
  ];
  const searchIndex = [{page:'learn',title:'Your first application',type:'Learning path',terms:'setup install create macos apple silicon'}, {page:'map',title:'Project map',type:'Guide',terms:'directory files controller action model view frappe latte sugarorm corretto blueprint'}, {page:'agents',title:'Work with an agent',type:'Proposed guide',terms:'AI AGENTS manifest check commands'}].concat(recipes.map(r=>({page:r.page,title:r.title,type:r.status==='gap'?'Framework gap':'Draft recipe',terms:r.text+' '+r.keywords})));
  function persist(){}
  function renderTask(){const el=root.querySelector('#c-map-result');if(!el)return;const task=tasks[selectedTask];el.innerHTML=`<strong>${task.title}</strong>${task.files.map(f=>`<code>${f}</code>`).join('')}<p>${task.detail}</p><small>${task.proof}</small>`;root.querySelectorAll('[data-task]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.task===selectedTask)));}
  function renderRecipes(){const term=root.querySelector('#c-recipe-search').value.toLowerCase();const list=recipes.filter(r=>(recipeFilter==='all'||r.status===recipeFilter)&&(r.title+' '+r.text+' '+r.keywords).toLowerCase().includes(term));root.querySelector('#c-recipes').innerHTML=list.map(r=>`<button class="c-recipe cursor-interaction" data-page="${r.page}"><span class="c-tag ${r.status==='gap'?'c-draft':''}">${r.status==='gap'?'Framework gap':'Draft recipe'}</span><h2>${r.title}</h2><p>${r.text}</p><footer><span>${r.category} · 0.4.0</span><span aria-hidden="true">↗</span></footer></button>`).join('');root.querySelector('#c-empty').hidden=list.length>0;root.querySelectorAll('[data-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.filter===recipeFilter)));}
  function search(){const term=root.querySelector('#c-search-input').value.trim().toLowerCase();const found=searchIndex.filter(r=>(r.title+' '+r.terms).toLowerCase().includes(term));root.querySelector('#c-results').innerHTML=found.length?found.map(r=>`<button class="cursor-interaction" data-page="${r.page}" data-search-result="true">${r.title}<small>${r.type} · 0.4.0</small></button>`).join(''):'<p>No results. Try “controller”, “JSON”, or “deploy”.</p>';}
  function toggleSearch(open){root.querySelector('#c-search-area').hidden=!open;root.querySelector('.c-search-open').setAttribute('aria-expanded',String(open));if(open){search();root.querySelector('#c-search-input').focus();}else root.querySelector('.c-search-open').focus();}
  root.addEventListener('click',event=>{const b=event.target.closest('button');if(!b)return;if(b.dataset.task){selectedTask=b.dataset.task;renderTask();persist();}if(b.dataset.filter){recipeFilter=b.dataset.filter;renderRecipes();persist();}if(b.classList.contains('c-search-open'))toggleSearch(root.querySelector('#c-search-area').hidden);if(b.id==='c-search-close')toggleSearch(false);if(b.id==='c-agent-plain'){const el=root.querySelector('#c-agent-markdown');el.hidden=!el.hidden;b.textContent=el.hidden?'View compact guide as Markdown':'Hide Markdown guide';b.setAttribute('aria-expanded',String(!el.hidden));}});
  root.querySelector('#c-search-input').addEventListener('input',search);root.querySelector('#c-recipe-search')?.addEventListener('input',renderRecipes);
  document.addEventListener('keydown',event=>{if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'){event.preventDefault();toggleSearch(true);}if(event.key==='Escape'&&!root.querySelector('#c-search-area').hidden)toggleSearch(false);});
  renderTask(); if(currentPage === "cookbook") renderRecipes(); queueScrollUpdate();
})();
