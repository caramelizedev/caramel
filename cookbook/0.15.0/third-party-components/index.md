Cookbook / Views

# Mount a third-party component.

Wrap a headless JavaScript library in a Caramel island. The worked example is a11y-dialog 8.1.5 as a navigation dialog: vendor its file, mount it with props the server renders, clean up after it, survive history navigation and refresh a region beside it.

Draft recipe · Target: 0.15.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Needs | Locales enabled with `frappe make locale en`, because the view reads its text through `t.` |
| You will have | An a11y-dialog 8.1.5 navigation dialog mounted as an island, with a region beside it that refreshes from a server event |
| Proved by | `frappe corretto spec/requests/guide_spec.cr`, then the nine browser checks under “Test it” |

## Where the change goes {#c-island-files}

- `app/assets/vendor/a11y-dialog-8.1.5.min.js`: Vendored library
- `app/views/layouts/application.cr`: Loads scripts once
- `app/views/guide/show.cr`: Fallback and mount point
- `app/views/activity/show.cr`: Refreshed region
- `app/assets/javascript/app.js`: Island adapter
- `app/assets/stylesheets/app.css`: Dialog appearance
- `app/actions/guide/show.cr`: Passes links to the view
- `app/actions/activity/show.cr`: Answers region refresh
- `app/actions/activity/stream.cr`: Event stream
- `app/locales/en.cr`: Navigation text keys
- `config/routes.cr`: Central routes
- `spec/requests/guide_spec.cr`: Server-side checks

## Vendor the library and load it once {#c-island-assets}

Frappé publishes every file under `app/assets/` at `/assets/`. Copy the library’s minified bundle there under a versioned name, so nothing is fetched from a CDN at run time. The view below reads its text through `t.`, so enable locales first with `frappe make locale en`.

1. **Vendor the bundle**

   **Terminal**

   ```bash
   npm pack a11y-dialog@8.1.5 --ignore-scripts
   tar xzf a11y-dialog-8.1.5.tgz package/dist/a11y-dialog.min.js
   cp package/dist/a11y-dialog.min.js app/assets/vendor/a11y-dialog-8.1.5.min.js
   rm -r package a11y-dialog-8.1.5.tgz
   ```

   **Expect:** The bundle sits at `app/assets/vendor/a11y-dialog-8.1.5.min.js`, and Frappé publishes it as `/assets/a11y-dialog-8.1.5.min.js`.
2. **Load it before app.js**

   The bundle is a UMD file that defines `window.A11yDialog` in a browser, so the adapter below uses that name. Load it in the shared layout, before `app.js`: deferred scripts run in order, so the global exists when the adapter file runs.

   **app/views/layouts/application.cr · the head**

   ```crystal
             script src: "/assets/htmx-4.0.0.min.js", defer: true
             script src: "/assets/caramel-islands.js", defer: true
             script src: "/assets/a11y-dialog-8.1.5.min.js", defer: true
             script src: "/assets/app.js", defer: true
   ```

The default Content-Security-Policy is `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; …`, quoted from the security reference. Keep the dialog’s appearance in `app/assets/stylesheets/app.css` and toggle classes or the library’s `aria-hidden` attribute instead of writing `style` attributes.

| Condition | Outcome |
| --- | --- |
| Script file from your own origin | allowed |
| Inline script | refused by the default Content-Security-Policy |
| Inline style, or a `style` attribute | refused by the default Content-Security-Policy |
| A script tag written by one page’s view under boosted navigation, which does not run a new page’s `<head>` again | never loads |

[Read the security reference →](https://caramelize.dev/docs/0.15.0/security/index.md)

## Write the fallback, then the mount point {#c-island-mount}

The view writes the navigation as plain links, which work with JavaScript off, then the island. Resolve every localized string in the view and pass it as a prop; the browser code never looks up a catalog.

**app/views/guide/show.cr**

```crystal
module App::Views::Guide
  class Show < App::ApplicationView
    def initialize(@links : Array(NamedTuple(label: String, href: String)))
    end

    private def blueprint
      h1 { "Guide" }
      nav class: "fallback", aria_label: t.nav.title do
        ul do
          @links.each { |link| li { a(href: link[:href]) { link[:label] } } }
        end
      end
      island "NavigatorDialog", {
        title:  t.nav.title,
        open:   t.nav.open,
        close:  t.nav.close,
        links:  @links,
        region: "activity",
      }
      section id: "activity", "hx-get": "/activity", "hx-trigger": "activity",
        "hx-sync": "this:queue last" do
        render App::Views::Activity::Show.new(Time.utc)
      end
    end
  end
end
```

**config/routes.cr · the central routes**

```crystal
    get "/guide", App::Guide::Show
    get "/activity", App::Activity::Show
    get "/activity/stream", App::Activity::Stream
```

**app/views/activity/show.cr**

```crystal
module App::Views::Activity
  class Show < App::ApplicationView
    def initialize(@at : Time)
    end

    private def blueprint
      h2 { t.nav.activity }
      p { "Updated #{@at.to_s("%H:%M:%S")} UTC" }
    end
  end
end
```

The island writes no children of its own, so the adapter hides the fallback once it has mounted. The library toggles `aria-hidden` on the dialog container and leaves its appearance to you, so the stylesheet must hide a closed dialog, and a `:has` rule hides the fallback links next to a mounted island. Stylesheet:

**app/assets/stylesheets/app.css · appended**

```markdown
.dialog-container {
  position: fixed;
  inset: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: center;
}
.dialog-container[aria-hidden="true"] {
  display: none;
}
.dialog-overlay {
  position: fixed;
  inset: 0;
  background: rgb(0 0 0 / 0.4);
}
.dialog-content {
  position: relative;
  z-index: 1;
  padding: 1.5rem;
  background: #faf8f3;
  border-radius: 0.5rem;
}
nav.fallback:has(+ caramel-island[data-island-state="mounted"]) {
  display: none;
}
```

The island contract is set out in the views guide and in [ADR 0005 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0005-island-props-helper.md).

| Condition | Outcome |
| --- | --- |
| The island has mounted | the element gets `data-island-state="mounted"` and the `:has` rule hides the fallback links |
| The script fails | the state is `error` and the fallback links stay |
| A mount returns `{update, unmount}` and a morph changes the props | calls `update(props)` |
| A mount returns a function or nothing and a morph changes the props | unmounts, then mounts again |
| The element is removed | calls `unmount` |
| A mount throws | sets `data-island-state="error"` and dispatches a bubbling `caramel:island-error` event |

[Read the views reference →](https://caramelize.dev/docs/0.15.0/views/index.md)

**app/actions/guide/show.cr**

```crystal
module App::Guide
  struct Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      links = [
        {label: t.nav.home, href: "/"},
        {label: t.nav.health, href: "/health"},
      ]
      page "Guide", Views::Guide::Show.new(links)
    end
  end
end
```

**app/locales/en.cr · the keys the view reads**

```crystal
  nav: {
    title:    "Browse & search",
    open:     "Open the navigation",
    close:    "Close",
    home:     "Home",
    health:   "Health",
    activity: "Recent activity",
  },
```

## Adapt the library to the island lifecycle {#c-island-adapter}

The adapter builds the dialog’s DOM itself. It never writes a `data-a11y-dialog` attribute, so the library’s own start-up scan, which instantiates every element that has one, finds nothing to take over; the adapter calls `new A11yDialog(container)` exactly once. The links are created by script, so it calls `htmx.process` on them to keep them boosted.

**app/assets/javascript/app.js**

```javascript
CaramelIslands.define('NavigatorDialog', (element, props) => {
  const container = document.createElement('div');
  container.id = 'navigator-dialog';
  container.className = 'dialog-container';
  container.setAttribute('aria-labelledby', 'navigator-dialog-title');
  container.setAttribute('aria-hidden', 'true');

  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.setAttribute('data-a11y-dialog-hide', '');

  const content = document.createElement('div');
  content.className = 'dialog-content';
  const title = document.createElement('h2');
  title.id = 'navigator-dialog-title';
  const list = document.createElement('ul');
  const close = document.createElement('button');
  close.type = 'button';
  close.setAttribute('data-a11y-dialog-hide', 'navigator-dialog');
  content.append(title, list, close);
  container.append(overlay, content);

  const opener = document.createElement('button');
  opener.type = 'button';
  opener.setAttribute('data-a11y-dialog-show', 'navigator-dialog');

  element.replaceChildren(opener, container);
  const dialog = new A11yDialog(container);

  function render(next) {
    opener.textContent = next.open;
    title.textContent = next.title;
    close.textContent = next.close;
    list.replaceChildren(...next.links.map((link) => {
      const item = document.createElement('li');
      const anchor = document.createElement('a');
      anchor.href = link.href;
      anchor.textContent = link.label;
      item.append(anchor);
      return item;
    }));
    htmx.process(list);
  }
  render(props);

  const onShortcut = (event) => {
    if (event.altKey && event.code === 'KeyM') dialog.show();
  };
  document.addEventListener('keydown', onShortcut);

  // htmx:after:settle fires on the element that received the swap and bubbles.
  const closeOnSwap = (event) => {
    if (event.target.contains(element)) dialog.hide();
  };
  document.addEventListener('htmx:after:settle', closeOnSwap);

  const region = document.getElementById(props.region);
  const refresh = () => {
    if (region) region.dispatchEvent(new CustomEvent('activity'));
  };
  const source = new EventSource('/activity/stream');
  source.addEventListener('open', refresh);
  source.addEventListener('activity', refresh);

  return {
    update(next) {
      render(next);
    },
    unmount() {
      source.close();
      document.removeEventListener('htmx:after:settle', closeOnSwap);
      document.removeEventListener('keydown', onShortcut);
      dialog.destroy();
      element.replaceChildren();
    },
  };
});
```

Return `{update, unmount}`.

| Call | What it does |
| --- | --- |
| `update(props)` | Relabels the dialog and rebuilds the links, then processes them again, so the server stays the source of the text |
| `unmount`, job 1: `destroy()` | Hides the dialog, removes the library’s document-level click listener and replaces the dialog node with a clone |
| `unmount`, job 2: remove other document listeners | Removes each listener the adapter added, here the keyboard shortcut and the swap handler, or each visit leaves another behind |
| `unmount`, job 3: `source.close()` | Closes the event stream |

## Keep it correct across navigation {#c-island-history}

htmx 4 names its events `htmx:phase:action`, for example `htmx:before:swap` and `htmx:after:settle`; see the [htmx events guide ↗](https://four.htmx.org/docs/htmx-events-guide). The detail differs by event, so read the version you ship:

| Event | What it carries |
| --- | --- |
| `htmx:before:init`, `htmx:after:init` | The element lifecycle |
| `htmx:before:history:restore` | History |
| `htmx:after:swap` | `ctx`, in the vendored htmx 4.0.0 |
| `htmx:after:settle` | Only `task`, `newContent` and `settleTasks`; htmx dispatches it on the element that received the swap, and it bubbles to `document` |

A document-wide handler that closes the dialog on a swap must first check that the swap’s target contains the island. The adapter does it in `closeOnSwap`: it listens for `htmx:after:settle` on `document` and closes only when `event.target`, the swapped element, contains the island. The island itself survives a navigation swap into `#content`, so this is what closes a dialog after one of its links is followed.

| Condition | Outcome |
| --- | --- |
| Back or Forward restores the page by swapping the body | the island element leaves and a new one arrives; the island lifecycle calls `unmount`, then `mount`, so no htmx listener is needed for cleanup |
| A swap whose target contains the island, such as a navigation swap into `#content` | `closeOnSwap` closes the dialog |
| A swap into another region, such as the activity region below | leaves an open dialog alone |

## Refresh a region from a server event {#c-island-updates}

A region beside the island, outside its skip-children subtree, can follow a server event. The adapter opens an `EventSource` to a stream action and closes it in `unmount`. On each event it dispatches an `activity` event on the region; the region fetches itself with `hx-trigger="activity"` and `hx-sync="this:queue last"`, so a burst of events leaves one request in flight and one queued. A stream action sends events from `Caramel::ColdBrew.subscribe` through `Caramel::SSE.write`; see the Cold Brew and actions references, and publish with `Caramel::ColdBrew.publish("activity", "changed")` from the code that changes the data.

[Read the Cold Brew reference →](https://caramelize.dev/docs/0.15.0/cold-brew/index.md)[Read the actions reference →](https://caramelize.dev/docs/0.15.0/actions-and-responses/index.md)

**app/actions/activity/stream.cr**

```crystal
module App::Activity
  struct Stream < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      stream "text/event-stream" do |io|
        Caramel::ColdBrew.subscribe("activity") do |updates|
          # Subscribed: now send the headers, so the browser's open event follows.
          io << ": open\n\n"
          io.flush
          loop { Caramel::SSE.write(io, event: "activity", data: updates.receive) }
        end
      end
    end
  end
end
```

**app/actions/activity/show.cr**

```crystal
module App::Activity
  struct Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      morph "#activity", with: Views::Activity::Show.new(Time.utc)
    end
  end
end
```

The server-sent stream drops events while a client is disconnected, and a browser reconnects by itself. The stream action therefore subscribes first, then writes and flushes a comment line before it blocks: a response sends its headers with its first write, so without that frame the browser’s `open` event would wait for the next real event. The adapter asks the region to fetch on every `open`, the first one included: that covers events published between rendering the page and subscribing, and a reconnect loads a fresh snapshot instead of trusting the events it missed. The cost is one extra request per mount.

## Test it {#c-island-tests}

A Corretto request spec proves what the server owes the browser: the mount point, its escaped props and the fallback links.

**spec/requests/guide_spec.cr**

```crystal
require "../spec_helper"

describe "Guide" do
  it "writes the island, its escaped props and the fallback links" do
    Corretto.session do |client|
      page = client.get("/guide")
      page.should have_status(200)
      page.body.should contain(%(<caramel-island component="NavigatorDialog"))
      page.body.should contain("Browse &amp; search")
      page.body.should contain(%(<a href="/health">Health</a>))
      page.body.should contain(%(<a href="/">Home</a>))
    end
  end

  it "answers the region's refresh with a partial for #activity" do
    Corretto.session do |client|
      client.get("/activity").body.should contain("Recent activity")
    end
  end
end
```

Library behaviour needs a browser. Before you ship, check each of these by hand:

- Focus moves into the dialog on open and returns to the opener on close.
- Tab and Shift-Tab wrap inside the dialog.
- Escape closes the dialog.
- If the dialog holds a native `<select>`, its open picker closes alone on the first Escape and the dialog stays.
- Repeated visits to the page keep exactly one dialog.
- Back and Forward with the dialog open leave one working dialog.
- Removing the island through a morph unmounts it and closes the event stream.
- No `caramel:island-error` event and no console error appears.
- The fallback links work with JavaScript off.

> **The library owns focus; the island owns its DOM**
>
> Let the library manage focus, `aria-hidden` and the Escape key; do not reimplement them. Everything the adapter creates or listens to, the adapter removes in `unmount`.

Prove it

## Prove the island {#c-island-prove}

**Terminal · inside the application**

```bash
frappe corretto spec/requests/guide_spec.cr
```

**Passing:** Both examples pass: the page writes the island, its escaped props and the fallback links, and the region’s refresh answers with the activity partial. Check the nine browser points above by hand; a request spec cannot show library behaviour.

> Draft **Written for 0.15.0, not yet run end to end.**
>
> The commands are the release’s own. The recipe keeps its Draft label until it has been run from a new application to a passing spec.

[← All recipes](https://caramelize.dev/cookbook/0.15.0/) · [Read the views reference →](https://caramelize.dev/docs/0.15.0/views/index.md)

Caramel 0.15.0 · https://caramelize.dev/cookbook/0.15.0/third-party-components/
