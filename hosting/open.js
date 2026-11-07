(() => {
  const button = document.getElementById("open-meeting");
  const unavailable = document.getElementById("unavailable");
  try {
    const url = new URL(window.location.href);
    const match = /^\/meeting\/([^/]+)$/.exec(url.pathname);
    if (!match) throw new Error("Missing meeting");
    const id = decodeURIComponent(match[1]);
    if (!id.trim() || /[\/\x00-\x1f\x7f]/.test(id)) throw new Error("Invalid meeting");
    const keys = [...url.searchParams.keys()];
    if (keys.some(key => key !== "p" && key !== "t") || keys.length > 1) {
      throw new Error("Invalid target");
    }
    const passage = url.searchParams.get("p");
    const time = url.searchParams.get("t");
    let query = "";
    if (passage !== null) {
      if (!/^s[1-9][0-9]*$/.test(passage)) throw new Error("Invalid passage");
      query = "?p=" + passage;
    } else if (time !== null) {
      if (!time.trim() || !Number.isFinite(Number(time)) || Number(time) < 0) {
        throw new Error("Invalid time");
      }
      query = "?t=" + encodeURIComponent(time);
    }
    button.href = "meetingnotes://meeting/" + encodeURIComponent(id) + query;
    button.hidden = false;
  } catch {
    unavailable.hidden = false;
  }
})();
