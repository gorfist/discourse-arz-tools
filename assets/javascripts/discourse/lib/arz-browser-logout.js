const ACCOUNTS_ORIGIN = "https://accounts.arzdigital.com";
const NAMESPACE = "arz-accounts";

function createOverlay(hostDocument, text) {
  const overlay = hostDocument.createElement("div");
  overlay.className = "arz-browser-logout-overlay";
  overlay.setAttribute("role", "dialog");
  overlay.setAttribute("aria-modal", "true");
  overlay.setAttribute("aria-label", text);
  overlay.tabIndex = -1;
  const content = hostDocument.createElement("div");
  content.className = "arz-browser-logout-content";
  const spinner = hostDocument.createElement("span");
  spinner.className = "arz-browser-logout-spinner";
  spinner.setAttribute("aria-hidden", "true");
  const status = hostDocument.createElement("p");
  status.setAttribute("role", "status");
  status.textContent = text;
  content.append(spinner, status);
  overlay.appendChild(content);
  hostDocument.body.appendChild(overlay);
  // Block keyboard interaction with the page as well as pointer interaction.
  for (const child of hostDocument.body.children) {
    if (child !== overlay) child.inert = true;
  }
  overlay.focus();
  return (message) => { status.textContent = message; };
}

export function createBrowserLogoutCoordinator({
  hostWindow = window,
  hostDocument = document,
  reload = () => hostWindow.location.reload(),
  showOverlay = (text) => createOverlay(hostDocument, text),
} = {}) {
  let operation;

  return {
    start({
      timeoutSeconds = 30,
      logoutHub,
      loadingText = "در حال خروج از حساب کاربری…",
      waitingText = "خروج کامل از همهٔ سرویس‌ها تأیید نشد؛ صفحه به‌زودی تازه می‌شود…",
    }) {
      if (operation) return operation;
      let resolveOperation;
      operation = new Promise((resolve) => { resolveOperation = resolve; });
      const seconds = Number.isInteger(timeoutSeconds) && timeoutSeconds >= 1 && timeoutSeconds <= 120
        ? timeoutSeconds : 30;
      let finished = false;
      let hubComplete = false;
      let accountsComplete = false;
      let failed = false;
      let iframe;
      let requestId;
      let updateText = () => {};

      const finish = (reason) => {
        if (finished) return;
        finished = true;
        hostWindow.clearTimeout(timer);
        hostWindow.removeEventListener("message", onMessage);
        try {
          reload(reason);
        } finally {
          resolveOperation(reason);
        }
      };
      const checkComplete = () => {
        if (hubComplete && accountsComplete) finish(failed ? "failed" : "success");
      };
      const onMessage = (event) => {
        if (finished || !iframe || event.origin !== ACCOUNTS_ORIGIN || event.source !== iframe.contentWindow) return;
        const message = event.data;
        if (!message || message.namespace !== NAMESPACE || message.version !== 1 ||
            message.requestId !== requestId || message.action !== "accounts:logout") return;
        if (typeof message.data?.success !== "boolean") return;
        accountsComplete = true;
        if (!message.data.success) {
          failed = true;
          updateText(waitingText);
        }
        checkComplete();
      };

      // This is the only deadline: it includes server work, loading and handshake.
      const timer = hostWindow.setTimeout(() => finish("timeout"), seconds * 1000);
      try {
        updateText = showOverlay(loadingText);
      } catch {
        // A rendering failure must not prevent logout or the mandatory reload.
      }

      Promise.resolve().then(logoutHub).then(() => {
        if (finished) return;
        hubComplete = true;
        checkComplete();
      }, () => {
        if (finished) return;
        hubComplete = true;
        failed = true;
        updateText(waitingText);
        checkComplete();
      });

      try {
        const bytes = new Uint8Array(16);
        hostWindow.crypto.getRandomValues(bytes);
        requestId = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
        iframe = hostDocument.createElement("iframe");
        iframe.hidden = true;
        iframe.setAttribute("aria-hidden", "true");
        iframe.setAttribute("title", "Accounts logout");
        hostWindow.addEventListener("message", onMessage);
        iframe.addEventListener("load", () => {
          if (finished) return;
          iframe.contentWindow.postMessage({
            namespace: NAMESPACE,
            version: 1,
            action: "accounts:init",
            requestId,
            data: {},
          }, ACCOUNTS_ORIGIN);
        });
        iframe.src = `${ACCOUNTS_ORIGIN}/background.html?f=logout`;
        hostDocument.body.appendChild(iframe);
      } catch {
        updateText(waitingText);
      }

      return operation;
    },
  };
}
