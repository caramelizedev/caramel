// Caramel islands: client components mounted inside server-rendered
// <caramel-island component="Name" props="{...}"> elements. Register a
// component with CaramelIslands.define(name, mount); mount(element, props) may
// return nothing, an unmount function, or {update(props), unmount()}.
(() => {
  "use strict";
  if (window.CaramelIslands) return;
  const NAME = /^[A-Z][A-Za-z0-9]{0,63}$/;
  const registry = new Map();
  const pending = new Set();

  class CaramelIsland extends HTMLElement {
    static observedAttributes = ["props", "data-island-state"];

    #instance = null;
    #mounted = false;
    #state = null;

    connectedCallback() {
      this.#mount();
    }

    disconnectedCallback() {
      pending.delete(this);
      this.#unmount();
    }

    attributeChangedCallback(name, previous, current) {
      if (name === "data-island-state") {
        // Morphs copy the server's attributes and drop this client-owned one.
        if (this.#state !== null && current !== this.#state) this.dataset.islandState = this.#state;
        return;
      }
      if (!this.#mounted || previous === current) return;
      const props = this.#props();
      if (props === undefined) {
        this.#unmount();
        return;
      }
      if (this.#instance && typeof this.#instance.update === "function") {
        this.#instance.update(props);
      } else {
        this.#unmount();
        this.#mount();
      }
    }

    mountIfRegistered() {
      this.#mount();
    }

    #mount() {
      if (this.#mounted || !this.isConnected) return;
      const name = this.getAttribute("component") || "";
      const mount = registry.get(name);
      if (!mount) {
        pending.add(this);
        this.#setState("pending");
        return;
      }
      pending.delete(this);
      const props = this.#props();
      if (props === undefined) return;
      try {
        this.#instance = mount(this, props) ?? null;
      } catch (error) {
        this.#fail(error);
        return;
      }
      this.#mounted = true;
      this.#setState("mounted");
    }

    #unmount() {
      if (!this.#mounted) return;
      const instance = this.#instance;
      this.#instance = null;
      this.#mounted = false;
      if (typeof instance === "function") {
        instance();
      } else if (instance && typeof instance.unmount === "function") {
        instance.unmount();
      }
    }

    #props() {
      try {
        return JSON.parse(this.getAttribute("props") || "{}");
      } catch (error) {
        this.#fail(error);
        return undefined;
      }
    }

    #fail(error) {
      this.#setState("error");
      this.dispatchEvent(new CustomEvent("caramel:island-error", {
        bubbles: true,
        detail: { component: this.getAttribute("component"), error },
      }));
    }

    #setState(state) {
      this.#state = state;
      this.dataset.islandState = state;
    }
  }

  window.CaramelIslands = {
    define(name, mount) {
      if (typeof name !== "string" || !NAME.test(name)) {
        throw new TypeError(`Island component names are PascalCase: ${name}`);
      }
      if (typeof mount !== "function") {
        throw new TypeError(`Island ${name} needs a mount function`);
      }
      if (registry.has(name)) {
        throw new Error(`Island ${name} is already defined`);
      }
      registry.set(name, mount);
      for (const element of [...pending]) {
        if (element.getAttribute("component") === name) element.mountIfRegistered();
      }
    },
  };

  if (!customElements.get("caramel-island")) {
    customElements.define("caramel-island", CaramelIsland);
  }
})();
