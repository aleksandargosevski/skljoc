import { error, handleApi } from "./api.js";
import { handlePublic } from "./public.js";
import { isAuthorized } from "./security.js";
import { cleanUp } from "./links.js";

export default {
  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    try {
      if (path === "/api" || path.startsWith("/api/")) {
        if (!env.UPLOAD_TOKEN) return error(500, "UPLOAD_TOKEN is not set on the Worker");
        if (!(await isAuthorized(request, env))) return error(401, "Wrong or missing upload token");
        return await handleApi(request, env, path);
      }
      return await handlePublic(request, env, path, ctx);
    } catch (failure) {
      console.error(failure);
      return error(500, failure instanceof Error ? failure.message : "Something went wrong");
    }
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(cleanUp(env).then((removed) => console.log(`Removed ${removed} expired links`)));
  },
};
