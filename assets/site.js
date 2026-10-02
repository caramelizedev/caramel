
(() => {
  const root = document.getElementById('caramel-site');

  const routes = {"home":"/","cookbook":"/cookbook/0.7.0/","learn":"/docs/0.7.0/getting-started/","map":"/docs/0.7.0/project-map/","crud":"/cookbook/0.7.0/create-a-resource/","json":"/cookbook/0.7.0/return-json/","uploads":"/cookbook/0.7.0/uploads/","jobs":"/cookbook/0.7.0/background-jobs/","webhooks":"/cookbook/0.7.0/webhooks/","agents":"/docs/0.7.0/agents/","i18n":"/docs/0.7.0/internationalization/","testing":"/docs/0.7.0/testing-html/","releases":"/docs/0.7.0/releases/","deploy":"/docs/0.7.0/deployment/"};
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
  const steam = root.querySelector('.l-steam');
  const chapters = Array.from(root.querySelectorAll('.l-chapter'));
  const pieces = ['caramel','foam','milk','espresso'].map(name=>root.querySelector('.l-'+name));
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let scrollFrame = 0, activeChapter = -1;
  let scrollProgress = null, previousFrameTime = 0;
  const clamp = value => Math.max(0,Math.min(1,value));
  const smooth = value => value*value*(3-2*value);
  function updateScroll(time){
    scrollFrame=0;
    if(currentPage!=='home')return;
    const headerHeight=root.querySelector('.c-header').offsetHeight;
    if(root.style.getPropertyValue('--header-height')!==headerHeight+'px'){
      root.style.setProperty('--header-height',headerHeight+'px');
    }
    const storyStart=story.offsetTop-headerHeight;
    const target=clamp((window.scrollY-storyStart)/Math.max(1,story.offsetHeight-stage.offsetHeight));
    // Ease trackpad bursts without detaching the illustration from the scroll.
    const elapsed=previousFrameTime?Math.min(time-previousFrameTime,64):16;
    previousFrameTime=time;
    if(scrollProgress===null||reducedMotion.matches)scrollProgress=target;
    else scrollProgress+=(target-scrollProgress)*(1-Math.exp(-elapsed/140));
    if(Math.abs(target-scrollProgress)<.0002)scrollProgress=target;
    const p=scrollProgress;
    // Give the first lift more scroll travel, then settle between ingredients.
    const steps=[
      {start:.045,end:.29,lift:235,spread:16},
      {start:.35,end:.52,lift:197,spread:-10},
      {start:.58,end:.75,lift:154,spread:8},
      {start:.80,end:.94,lift:116,spread:-8},
    ];
    const thresholds=[.06,.365,.595,.815,.97];
    const chapter=thresholds.filter(t=>p>=t).length;
    pieces.forEach((piece,i)=>{
      const step=steps[i], raw=clamp((p-step.start)/(step.end-step.start));
      const amount=reducedMotion.matches?(raw>0?1:0):smooth(raw);
      piece.style.transform=`translate(${step.spread*amount}px,${-step.lift*amount}px)`;
    });
    // The camera pulls back gradually, independently of the caramel lifting.
    const framing=reducedMotion.matches?(chapter?1:0):smooth(clamp((p-.015)/.385));
    const mobile=root.clientWidth<=700, zoom=mobile?1.15:1.35, lift=mobile?80:130;
    diagram.style.transform=`translateY(${-lift*(1-framing)}px) scale(${zoom-(zoom-1)*framing})`;
    steam.style.opacity=String(1-smooth(clamp((p-.04)/.25)));
    if(chapter!==activeChapter){activeChapter=chapter;chapters.forEach((el,i)=>{el.hidden=i!==chapter;});root.querySelector('#l-current').textContent=String(chapter).padStart(2,'0');story.dataset.chapter=String(chapter);}
    if(scrollProgress!==target)scrollFrame=requestAnimationFrame(updateScroll);
    else previousFrameTime=0;
  }
  function queueScrollUpdate(){if(!scrollFrame)scrollFrame=requestAnimationFrame(updateScroll);}
  window.addEventListener('scroll',queueScrollUpdate,{passive:true});
  new ResizeObserver(queueScrollUpdate).observe(root);
  window.addEventListener('resize',queueScrollUpdate,{passive:true});
  reducedMotion.addEventListener('change',queueScrollUpdate);
  const tasks = {"endpoint":{"title":"Add or change an endpoint","files":["config/routes.cr","app/actions/"],"detail":"Declare the route, then its typed contract and behavior. Keep the response and failure cases in a request spec.","proof":"frappe routes · frappe check · frappe corretto"},"data":{"title":"Change the data your application stores","files":["app/models/","app/changesets/","db/migrations/"],"detail":"Describe the stored shape and write rules, derive the migration, and review it before applying it.","proof":"frappe db diff · frappe migrate · frappe corretto"},"view":{"title":"Change what the browser renders","files":["app/views/","app/assets/","spec/requests/"],"detail":"Use Blueprint classes for typed HTML, have_html for rendered requirements, and browser checks for client behavior.","proof":"frappe check · have_html · browser inspection"},"language":{"title":"Translate the application","files":["app/locales/","config/application.cr","app/views/","spec/requests/"],"detail":"Enable locales with frappe make locale, define typed messages, and check translated pages, errors, and language selection.","proof":"frappe translations · frappe check · frappe corretto"},"job":{"title":"Move work into a background job","files":["app/jobs/","spec/"],"detail":"Define the job payload and behavior. Enqueue within the intended transaction and test the observable result.","proof":"Corretto session · drain_queue! · database assertion"}};
  const recipes = [{"page":"crud","title":"Create a resource","text":"A small CRUD feature, from model and changeset to a passing request spec.","category":"Data & forms","status":"draft","keywords":"database validation model controller"},{"page":"json","title":"Read and write JSON","text":"Return JSON and bind typed JSON input through the same action contract.","category":"Requests & responses","status":"draft","keywords":"api endpoint content negotiation accept json post csrf ingress"},{"page":"uploads","title":"Upload and keep a file","text":"Go from a request-scoped temporary file to a complete persistence recipe.","category":"Files","status":"draft","keywords":"storage image multipart upload"},{"page":"jobs","title":"Run a background job","text":"Track job status, observe failure hooks, and run workers without HTTP.","category":"Background work","status":"draft","keywords":"queue cold brew worker work status retry hooks scheduler"},{"page":"webhooks","title":"Receive a signed webhook","text":"Use raw-body ingress and provider authentication before contract binding.","category":"External integrations","status":"draft","keywords":"accept json post api csrf signature ingress raw body authenticate"},{"page":"deploy","title":"Deploy an application","text":"Follow the remaining gates from a local app to a supported production release.","category":"Production","status":"gap","keywords":"ship hosting linux binary release"}];
  const searchIndex = [{"page":"learn","title":"Your first application","type":"Learning path","terms":"setup install create macos apple silicon"},{"page":"map","title":"Project map","type":"Guide","terms":"directory files controller action model view frappe latte sugarorm corretto blueprint"},{"page":"agents","title":"Work with an agent","type":"Guide","terms":"AI AGENTS manifest check commands"},{"page":"i18n","title":"Internationalization","type":"Guide","terms":"i18n translate translations localization locales language French plurals formatting dates number fallback cookie accept language rtl wording make locale"},{"page":"testing","title":"Test rendered HTML","type":"Guide","terms":"corretto have_html blueprint lexbor render_partial render_page doctype strict count scope assertions"},{"page":"releases","title":"Current release","type":"Guide","terms":"current release i18n internationalization translations locales version 0.7.0 crystal postgres lock shard lexbor only url server unique render_errors requirements limits"},{"page":"crud","title":"Create a resource","type":"Draft recipe","terms":"A small CRUD feature, from model and changeset to a passing request spec. database validation model controller"},{"page":"json","title":"Read and write JSON","type":"Draft recipe","terms":"Return JSON and bind typed JSON input through the same action contract. api endpoint content negotiation accept json post csrf ingress"},{"page":"uploads","title":"Upload and keep a file","type":"Draft recipe","terms":"Go from a request-scoped temporary file to a complete persistence recipe. storage image multipart upload"},{"page":"jobs","title":"Run a background job","type":"Draft recipe","terms":"Track job status, observe failure hooks, and run workers without HTTP. queue cold brew worker work status retry hooks scheduler"},{"page":"webhooks","title":"Receive a signed webhook","type":"Draft recipe","terms":"Use raw-body ingress and provider authentication before contract binding. accept json post api csrf signature ingress raw body authenticate"},{"page":"deploy","title":"Deploy an application","type":"Framework gap","terms":"Follow the remaining gates from a local app to a supported production release. ship hosting linux binary release"}];
  function persist(){}
  function renderTask(){const el=root.querySelector('#c-map-result');if(!el)return;const task=tasks[selectedTask];el.innerHTML=`<strong>${task.title}</strong>${task.files.map(f=>`<code>${f}</code>`).join('')}<p>${task.detail}</p><small>${task.proof}</small>`;root.querySelectorAll('[data-task]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.task===selectedTask)));}
  function renderRecipes(){const term=root.querySelector('#c-recipe-search').value.toLowerCase();const list=recipes.filter(r=>(recipeFilter==='all'||r.status===recipeFilter)&&(r.title+' '+r.text+' '+r.keywords).toLowerCase().includes(term));root.querySelector('#c-recipes').innerHTML=list.map(r=>`<button class="c-recipe cursor-interaction" data-page="${r.page}"><span class="c-tag ${r.status==='gap'?'c-draft':''}">${r.status==='gap'?'Framework gap':'Draft recipe'}</span><h2>${r.title}</h2><p>${r.text}</p><footer><span>${r.category} · 0.7.0</span><span aria-hidden="true">↗</span></footer></button>`).join('');root.querySelector('#c-empty').hidden=list.length>0;root.querySelectorAll('[data-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.filter===recipeFilter)));}
  function search(){const term=root.querySelector('#c-search-input').value.trim().toLowerCase();const found=searchIndex.filter(r=>(r.title+' '+r.terms).toLowerCase().includes(term));root.querySelector('#c-results').innerHTML=found.length?found.map(r=>`<button class="cursor-interaction" data-page="${r.page}" data-search-result="true">${r.title}<small>${r.type} · 0.7.0</small></button>`).join(''):'<p>No results. Try “controller”, “JSON”, or “deploy”.</p>';}
  function toggleSearch(open){root.querySelector('#c-search-area').hidden=!open;root.querySelector('.c-search-open').setAttribute('aria-expanded',String(open));if(open){search();root.querySelector('#c-search-input').focus();}else root.querySelector('.c-search-open').focus();}
  root.addEventListener('click',event=>{const b=event.target.closest('button');if(!b)return;if(b.dataset.task){selectedTask=b.dataset.task;renderTask();persist();}if(b.dataset.filter){recipeFilter=b.dataset.filter;renderRecipes();persist();}if(b.classList.contains('c-search-open'))toggleSearch(root.querySelector('#c-search-area').hidden);if(b.id==='c-search-close')toggleSearch(false);if(b.id==='c-agent-plain'){const el=root.querySelector('#c-agent-markdown');el.hidden=!el.hidden;b.textContent=el.hidden?'View compact guide as Markdown':'Hide Markdown guide';b.setAttribute('aria-expanded',String(!el.hidden));}});
  root.querySelector('#c-search-input').addEventListener('input',search);root.querySelector('#c-recipe-search')?.addEventListener('input',renderRecipes);
  document.addEventListener('keydown',event=>{if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'){event.preventDefault();toggleSearch(true);}if(event.key==='Escape'&&!root.querySelector('#c-search-area').hidden)toggleSearch(false);});
  renderTask(); if(currentPage === "cookbook") renderRecipes(); queueScrollUpdate();
})();
