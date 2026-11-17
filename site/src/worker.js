// Sends plain HTTP to HTTPS and www.tapeloop.stream to tapeloop.stream, then serves the static site.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:" || url.hostname === "www.tapeloop.stream") {
      url.protocol = "https:";
      url.hostname = "tapeloop.stream";
      return Response.redirect(url.toString(), 301);
    }
    // The performance report moved into the docs.
    if (url.pathname === "/performance" || url.pathname.startsWith("/performance/")) {
      return Response.redirect("https://tapeloop.stream/docs/performance/", 301);
    }
    return env.ASSETS.fetch(request);
  },
};
