// This script helps enable SharedArrayBuffer and multi-threading on browsers
// that might restrict it for security reasons
// This is for local development only and should be replaced with proper COOP/COEP headers in production
if (window.crossOriginIsolated === false) {
  console.log("Cross-Origin-Isolation is not enabled. WebAssembly threads may not be available.");
  
  // Try to provide a workaround for Chrome
  if (window.chrome !== undefined) {
    console.log("Attempting to enable Cross-Origin-Isolation for Chrome...");
    
    // This is a simplified version of the workaround, for a full solution check:
    // https://github.com/keyur2maru/vad/blob/master/example/web/enable-threads.js
    
    const params = new URLSearchParams(window.location.search);
    if (!params.has('crossOriginIsolated')) {
      console.log("Reloading with crossOriginIsolated flag...");
      params.set('crossOriginIsolated', '1');
      window.location.search = params.toString();
    } else {
      console.warn("Failed to enable cross-origin isolation. VAD may not work correctly.");
    }
  }
}