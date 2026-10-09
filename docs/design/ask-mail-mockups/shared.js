// Renders the page's single <template id="ask"> into both a macOS window and an iPhone,
// so every concept is literally one component shown on two platforms.
(() => {
  const body = document.body;
  const macMode = body.dataset.mac || "panel"; // "panel" = inspector column, "full" = replaces list

  const icons = {
    inbox: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M2 9h3.5l1 2h3l1-2H14M3.5 3h9L14 9v4H2V9z"/></svg>',
    star: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="m8 2 1.8 3.8 4.2.5-3.1 2.9.8 4.1L8 11.3l-3.7 2 .8-4.1L2 6.3l4.2-.5z"/></svg>',
    send: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M2 8 14 2l-3 12-3-5z"/></svg>',
    arch: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M2 3h12v3H2zM3 6v7h10V6M6.5 9h3"/></svg>',
  };

  const fakeRows = [
    ["ZurichJS (via Slack)", "10:12", "You've got 2 unread messages", "ZurichJS 111 members · Your team has sent 50 messages recently", true],
    ["GitHub", "9:47", "[plainpost] CI failed on main", "Run #4821 failed: ios-unit (macos-15) · 3 annotations", true],
    ["Lena Brandt", "9:30", "Re: Flat viewing on Saturday", "Works for me — can you bring the signed form? I'll print a copy…", true],
    ["Swiss International Air Lines", "Yesterday", "Your booking LX 318 is confirmed", "Zurich → London Heathrow · Thu 2 Oct · 07:40", false],
    ["Figma", "Yesterday", "Config 2026 replays are live", "Catch every keynote and session from this year's Config…", true],
    ["Stripe", "Mon", "Your receipt from Linear", "Amount paid CHF 16.00 · Receipt #2291-4410", false],
    ["Marco Rossi", "Mon", "Invoice for September", "Hi Oleh, attached is the invoice for the September sprint…", true],
    ["The Pragmatic Engineer", "Sun", "The state of on-device AI", "This week: what shipping local models actually looks like…", true],
  ];

  const mac = () => `
    <div>
      <div class="mac">
        <div class="mac-lights"><i></i><i></i><i></i></div>
        <nav class="mac-side">
          <h6>Favorites</h6>
          <a class="on" href="#">${icons.inbox}<span>Inbox</span><span class="n">52</span></a>
          <a href="#">${icons.star}<span>Flagged</span></a>
          <a href="#">${icons.send}<span>Sent</span></a>
          <a href="#">${icons.arch}<span>Archive</span></a>
          <h6>Accounts</h6>
          <a href="#"><span class="av" style="width:15px;height:15px;font-size:8px;background:var(--accent)">O</span><span>olhapi.com</span><span class="n">38</span></a>
          <a href="#"><span class="av" style="width:15px;height:15px;font-size:8px;background:var(--orange)">G</span><span>Gmail</span><span class="n">14</span></a>
        </nav>
        <div class="mac-main">
          ${macMode === "full" ? `<div class="mac-full ask-slot" data-platform="mac"></div>` : `
          <div class="mac-list">
            <div class="mac-toolbar"><div><b>Inbox</b><div class="sub">52 unread</div></div>
              <span class="tb-btn">✦ Ask</span></div>
            ${fakeRows.map(r => `<div class="fake-row ${r[4] ? "unread" : ""}"><div class="top">${r[0]}<span>${r[1]}</span></div><div class="s">${r[2]}</div><div class="p">${r[3]}</div></div>`).join("")}
          </div>
          <div class="mac-panel ask-slot" data-platform="mac"></div>`}
        </div>
      </div>
      <div class="frame-label">macOS · ${macMode === "full" ? "Ask replaces the message list" : "Ask as an inspector column"}</div>
    </div>`;

  const phone = () => `
    <div>
      <div class="phone"><div class="phone-screen">
        <div class="phone-island"></div>
        <div class="phone-status"><span>9:41</span><span class="icons">
          <svg width="17" height="11" viewBox="0 0 17 11"><g fill="currentColor"><rect x="0" y="7" width="3" height="4" rx="1"/><rect x="4.5" y="5" width="3" height="6" rx="1"/><rect x="9" y="2.5" width="3" height="8.5" rx="1"/><rect x="13.5" y="0" width="3" height="11" rx="1"/></g></svg>
          <span class="batt"></span></span></div>
        <div class="phone-sheet ${body.dataset.phone === "flat" ? "flat" : ""} ask-slot" data-platform="ios"></div>
        <div class="home-ind"></div>
      </div></div>
      <div class="frame-label">iOS · same component, compact width</div>
    </div>`;

  const stage = document.getElementById("stage");
  stage.innerHTML = mac() + phone();
  const tpl = document.getElementById("ask");
  document.querySelectorAll(".ask-slot").forEach(slot => {
    const root = tpl.content.firstElementChild.cloneNode(true);
    root.dataset.platform = slot.dataset.platform;
    slot.appendChild(root);
  });

  // ---- state ----
  const setState = state => {
    body.dataset.state = state;
    document.querySelectorAll("[data-only]").forEach(el => {
      el.hidden = !el.dataset.only.split(" ").includes(state);
    });
    document.querySelectorAll("[data-set-state]").forEach(b => b.setAttribute("aria-pressed", b.dataset.setState === state));
    document.querySelectorAll(".done").forEach(el => el.classList.remove("done"));
    document.querySelectorAll(".toast").forEach(t => (t.hidden = true));
  };
  let timer;
  const run = () => {
    clearTimeout(timer);
    setState("working");
    timer = setTimeout(() => setState("answer"), 2200);
  };

  document.addEventListener("click", e => {
    const s = e.target.closest("[data-set-state]");
    if (s) { clearTimeout(timer); setState(s.dataset.setState); return; }
    const t = e.target.closest("[data-set-theme]");
    if (t) {
      document.documentElement.dataset.theme = t.dataset.setTheme;
      document.querySelectorAll("[data-set-theme]").forEach(b => b.setAttribute("aria-pressed", b === t));
      return;
    }
    const a = e.target.closest("[data-act]");
    if (!a) return;
    const root = a.closest(".ask-root");
    const act = a.dataset.act;
    if (act === "ask") run();
    if (act === "toggle") a.closest("[data-scope]").classList.toggle("open");
    if (act === "remove") a.closest("[data-removable]").hidden = true;
    if (act === "done") {
      const target = a.closest("[data-group]") || a;
      target.classList.add("done");
      const toast = root.querySelector(".toast");
      if (toast) {
        toast.querySelector(".toast-text").textContent = a.dataset.toast || "Done";
        toast.hidden = false;
        toast._target = target;
      }
    }
    if (act === "undo") {
      const toast = a.closest(".toast");
      toast._target?.classList.remove("done");
      toast.hidden = true;
    }
    if (act === "select") a.closest("[data-scope]").classList.toggle("sel");
  });

  document.addEventListener("keydown", e => {
    if (e.key === "Enter" && e.target.matches(".ask-input")) { e.preventDefault(); run(); }
  });

  const params = new URLSearchParams(location.search);
  const theme = params.get("theme");
  if (theme) document.querySelector(`[data-set-theme="${theme}"]`)?.click();
  setState(params.get("state") || body.dataset.state || "answer");
})();
