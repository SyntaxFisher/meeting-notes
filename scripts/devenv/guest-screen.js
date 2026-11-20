// Injected into simulated Teams guests: screen sharing captures an animated slide drawn on a
// canvas instead of a real screen, so guests can present without a screen picker or the Screen
// Recording permission.
(() => {
  MediaDevices.prototype.getDisplayMedia = async function () {
    const canvas = document.createElement("canvas");
    canvas.width = 1280;
    canvas.height = 720;
    const context = canvas.getContext("2d");
    const started = performance.now();
    setInterval(() => {
      const slide = Math.floor((performance.now() - started) / 8000) % 5 + 1;
      context.fillStyle = "#1d4e89";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#ffffff";
      context.font = "64px sans-serif";
      context.fillText(`Slide ${slide}`, 80, 360);
    }, 100);
    return canvas.captureStream(10);
  };
})();
