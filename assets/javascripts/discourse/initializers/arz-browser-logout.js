import { action } from "@ember/object";
import { schedule } from "@ember/runloop";
import { createBrowserLogoutCoordinator } from "discourse/plugins/discourse-arz-tools/discourse/lib/arz-browser-logout";
import { withPluginApi } from "discourse/lib/plugin-api";
import { getCurrentPushSubscription } from "discourse/lib/push-notifications";
import { i18n } from "discourse-i18n";

const LOGOUT_NOTICE_KEY = "arz-browser-logout-notice";

export default {
  name: "arz-browser-logout",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.discourse_arz_tools_enabled) return;

    // Keep incomplete logout visible after the mandatory page refresh, once.
    try {
      const storedNotice = window.sessionStorage.getItem(LOGOUT_NOTICE_KEY);
      window.sessionStorage.removeItem(LOGOUT_NOTICE_KEY);
      const notice = JSON.parse(storedNotice || "null");
      const age = Date.now() - notice?.at;
      if (["timeout", "failed"].includes(notice?.reason) && age >= 0 && age < 60000) {
        schedule("afterRender", () => container.lookup("service:dialog").alert({
          message: i18n("discourse_arz_tools.browser_logout_incomplete"),
        }));
      }
    } catch {
      // Blocked storage must not prevent logout initialization.
    }

    const keyValueStore = container.lookup("service:key-value-store");
    const coordinator = createBrowserLogoutCoordinator({
      reload: (reason) => {
        try {
          if (reason === "timeout" || reason === "failed") {
            window.sessionStorage.setItem(LOGOUT_NOTICE_KEY, JSON.stringify({ reason, at: Date.now() }));
          }
        } catch { /* Reload must proceed even when storage is unavailable. */ }
        try {
          keyValueStore.abandonLocal();
        } finally {
          window.location.reload();
        }
      },
    });

    withPluginApi("1.8.0", (api) => {
      api.modifyClass("route:application", (Superclass) => class extends Superclass {
        @action
        logout() {
          const { isReadOnly, isStaffWritesOnly } = this.site;
          if (!siteSettings.discourse_arz_tools_enabled || !this.currentUser || (isReadOnly && !isStaffWritesOnly)) {
            return super.logout(...arguments);
          }

          return coordinator.start({
            timeoutSeconds: siteSettings.discourse_arz_tools_browser_logout_timeout_seconds,
            loadingText: i18n("discourse_arz_tools.browser_logout_loading"),
            waitingText: i18n("discourse_arz_tools.browser_logout_waiting"),
            logoutHub: async () => {
              const pushSubscription = await getCurrentPushSubscription();
              await this.currentUser.destroySession(pushSubscription);
            },
          });
        }
      });
    });
  },
};
