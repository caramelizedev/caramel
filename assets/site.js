
(() => {
  const root = document.getElementById('caramel-site');

  const routes = {"home":"/","cookbook":"/cookbook/0.7.1/","learn":"/docs/0.7.1/getting-started/","map":"/docs/0.7.1/project-map/","crud":"/cookbook/0.7.1/create-a-resource/","json":"/cookbook/0.7.1/return-json/","uploads":"/cookbook/0.7.1/uploads/","jobs":"/cookbook/0.7.1/background-jobs/","webhooks":"/cookbook/0.7.1/webhooks/","agents":"/docs/0.7.1/agents/","i18n":"/docs/0.7.1/internationalization/","testing":"/docs/0.7.1/testing-html/","releases":"/docs/0.7.1/releases/","deploy":"/docs/0.7.1/deployment/","practices":"/docs/0.7.1/best-practices/","routing":"/docs/0.7.1/routes-and-contracts/","actions":"/docs/0.7.1/actions-and-responses/","views":"/docs/0.7.1/views/","sugarorm":"/docs/0.7.1/sugarorm/","coldbrew":"/docs/0.7.1/cold-brew/","corretto":"/docs/0.7.1/corretto/","security":"/docs/0.7.1/security/","commands":"/docs/0.7.1/commands/","local":"/docs/0.7.1/local-environment/"};
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
  const searchIndex = [{"page":"learn","title":"Your first application","type":"Learning path","terms":"setup install create macos apple silicon"},{"page":"map","title":"Project map","type":"Guide","terms":"directory files controller action model view frappe latte sugarorm corretto blueprint"},{"page":"agents","title":"Work with an agent","type":"Guide","terms":"AI AGENTS manifest check commands mrdp diagnostics patch expand"},{"page":"i18n","title":"Internationalization","type":"Guide","terms":"i18n translate translations localization locales language French plurals formatting dates number fallback cookie accept language rtl wording make locale catalog reference keys errors pages directives plural rules languages"},{"page":"testing","title":"Test rendered HTML","type":"Guide","terms":"corretto have_html blueprint lexbor render_partial render_page doctype strict count scope assertions"},{"page":"releases","title":"Current release","type":"Guide","terms":"current release i18n internationalization translations locales version 0.7.1 crystal postgres lock shard lexbor only url server unique render_errors requirements limits"},{"page":"practices","title":"Best practices","type":"Guide","terms":"best practices conventions guidelines style lint service nouns contracts changesets preload migrations escaping csrf security jobs idempotent retries testing corretto mocks translations proof checks agents"},{"page":"routing","title":"Routes and contracts","type":"Reference","terms":"routes router draw path parameters 404 405 head method override contract field params validation min max default nilable string int64 time uploadedfile json query duplicate unknown errors 422 resource_paths path helpers frappe routes contract_mismatch ingress"},{"page":"actions","title":"Actions and responses","type":"Reference","terms":"action controller handle render respond status page layout title_for markup htmx partials morph fragment redirect_to redirect_external not_found stream sse server-sent events render_errors contract_failure_page session sign_out csrf_token negotiation accept json"},{"page":"views","title":"Views","type":"Reference","terms":"views blueprint templates html elements escaping attributes plain raw safe markup islands render partials forms csrf _method layout lang"},{"page":"sugarorm","title":"SugarORM","type":"Reference","terms":"sugarorm orm database model schema field belongs_to has_many has_one index scope query where order_by find preload n+1 sql changeset validations validate_presence unique_constraint create update transaction migrations db diff migrate linter dev-override branch"},{"page":"coldbrew","title":"Cold Brew","type":"Reference","terms":"cold brew jobs background queue worker enqueue param perform retry_on backoff run_at priority work concurrency schedules every cron pubsub publish subscribe cache drain_queue"},{"page":"corretto","title":"Corretto","type":"Reference","terms":"corretto testing specs request specs session client get post json body files upload headers csrf forged follow_redirect matchers have_status have_header redirect_to render_page have_row stub_wire wire fixtures mocks drain_queue concurrency env.test"},{"page":"security","title":"Security defaults","type":"Reference","terms":"security csrf token origin session cookie host headers content security policy csp referrer nosniff 421 escaping xss safe ingress authenticate webhook redirect external url outbound static files errors request id"},{"page":"commands","title":"Commands","type":"Reference","terms":"commands cli frappe reference help syntax flags latte binary serve work seed routes schema drift migrate lint translations check format expand db dump restore diff branch logs services sites installations doctor open lsp corretto agent-manifest mrdp"},{"page":"local","title":"Local environment","type":"Reference","terms":"local environment latte services postgres dns caddy https sites origins localhost resolver trust frappe dev logs doctor databases env seed dump restore installations releases editor lsp zed crystalline ameba"},{"page":"crud","title":"Create a resource","type":"Draft recipe","terms":"A small CRUD feature, from model and changeset to a passing request spec. database validation model controller"},{"page":"json","title":"Read and write JSON","type":"Draft recipe","terms":"Return JSON and bind typed JSON input through the same action contract. api endpoint content negotiation accept json post csrf ingress"},{"page":"uploads","title":"Upload and keep a file","type":"Draft recipe","terms":"Go from a request-scoped temporary file to a complete persistence recipe. storage image multipart upload"},{"page":"jobs","title":"Run a background job","type":"Draft recipe","terms":"Track job status, observe failure hooks, and run workers without HTTP. queue cold brew worker work status retry hooks scheduler"},{"page":"webhooks","title":"Receive a signed webhook","type":"Draft recipe","terms":"Use raw-body ingress and provider authentication before contract binding. accept json post api csrf signature ingress raw body authenticate"},{"page":"deploy","title":"Deploy an application","type":"Framework gap","terms":"Follow the remaining gates from a local app to a supported production release. ship hosting linux binary release"}];
  function persist(){}
  function renderTask(){const el=root.querySelector('#c-map-result');if(!el)return;const task=tasks[selectedTask];el.innerHTML=`<strong>${task.title}</strong>${task.files.map(f=>`<code>${f}</code>`).join('')}<p>${task.detail}</p><small>${task.proof}</small>`;root.querySelectorAll('[data-task]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.task===selectedTask)));}
  function renderRecipes(){const term=root.querySelector('#c-recipe-search').value.toLowerCase();const list=recipes.filter(r=>(recipeFilter==='all'||r.status===recipeFilter)&&(r.title+' '+r.text+' '+r.keywords).toLowerCase().includes(term));root.querySelector('#c-recipes').innerHTML=list.map(r=>`<button class="c-recipe cursor-interaction" data-page="${r.page}"><span class="c-tag ${r.status==='gap'?'c-draft':''}">${r.status==='gap'?'Framework gap':'Draft recipe'}</span><h2>${r.title}</h2><p>${r.text}</p><footer><span>${r.category} · 0.7.1</span><span aria-hidden="true">↗</span></footer></button>`).join('');root.querySelector('#c-empty').hidden=list.length>0;root.querySelectorAll('[data-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.filter===recipeFilter)));}
  function search(){const term=root.querySelector('#c-search-input').value.trim().toLowerCase();const found=searchIndex.filter(r=>(r.title+' '+r.terms).toLowerCase().includes(term));root.querySelector('#c-results').innerHTML=found.length?found.map(r=>`<button class="cursor-interaction" data-page="${r.page}" data-search-result="true">${r.title}<small>${r.type} · 0.7.1</small></button>`).join(''):'<p>No results. Try “controller”, “JSON”, or “deploy”.</p>';}
  function toggleSearch(open){root.querySelector('#c-search-area').hidden=!open;root.querySelector('.c-search-open').setAttribute('aria-expanded',String(open));if(open){search();root.querySelector('#c-search-input').focus();}else root.querySelector('.c-search-open').focus();}
  root.addEventListener('click',event=>{const b=event.target.closest('button');if(!b)return;if(b.dataset.task){selectedTask=b.dataset.task;renderTask();persist();}if(b.dataset.filter){recipeFilter=b.dataset.filter;renderRecipes();persist();}if(b.classList.contains('c-search-open'))toggleSearch(root.querySelector('#c-search-area').hidden);if(b.id==='c-search-close')toggleSearch(false);if(b.id==='c-agent-plain'){const el=root.querySelector('#c-agent-markdown');el.hidden=!el.hidden;b.textContent=el.hidden?'View compact guide as Markdown':'Hide Markdown guide';b.setAttribute('aria-expanded',String(!el.hidden));}});
  root.querySelector('#c-search-input').addEventListener('input',search);root.querySelector('#c-recipe-search')?.addEventListener('input',renderRecipes);
  document.addEventListener('keydown',event=>{if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'){event.preventDefault();toggleSearch(true);}if(event.key==='Escape'&&!root.querySelector('#c-search-area').hidden)toggleSearch(false);});
  renderTask(); if(currentPage === "cookbook") renderRecipes(); queueScrollUpdate();
})();
