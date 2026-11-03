// Injected into simulated Teams guests before any page script runs. Every microphone stream the
// page requests carries audio from one Web Audio destination, so devenv.py can make the guest
// "speak" a preloaded clip at an exact moment instead of relying on a looping fake device.
(() => {
  if (window.__meetingNotesGuest) return;
  const context = new AudioContext({ sampleRate: 48000 });
  const destination = context.createMediaStreamDestination();
  const clips = new Map();
  const original = MediaDevices.prototype.getUserMedia;

  MediaDevices.prototype.getUserMedia = async function (constraints) {
    const stream = await original.call(this, constraints);
    if (constraints && constraints.audio) {
      for (const track of stream.getAudioTracks()) {
        stream.removeTrack(track);
        track.stop();
      }
      stream.addTrack(destination.stream.getAudioTracks()[0].clone());
      window.__meetingNotesGuest.captured = true;
    }
    return stream;
  };

  // Keeps peer connections reachable so devenv.py can check that speech is actually sent.
  const connections = [];
  const NativeConnection = window.RTCPeerConnection;
  if (NativeConnection) {
    window.RTCPeerConnection = function (...args) {
      const connection = new NativeConnection(...args);
      connections.push(connection);
      return connection;
    };
    window.RTCPeerConnection.prototype = NativeConnection.prototype;
    Object.setPrototypeOf(window.RTCPeerConnection, NativeConnection);
  }

  window.__meetingNotesGuest = {
    captured: false,
    async audioStats() {
      const result = [];
      for (const connection of connections) {
        const stats = await connection.getStats();
        stats.forEach((report) => {
          if (report.kind === "audio" && ["media-source", "outbound-rtp"].includes(report.type)) {
            result.push({ type: report.type, audioLevel: report.audioLevel,
              bytesSent: report.bytesSent, totalAudioEnergy: report.totalAudioEnergy });
          }
          if (report.kind === "audio" && report.type === "inbound-rtp") {
            result.push({ type: report.type, audioLevel: report.audioLevel,
              bytesReceived: report.bytesReceived, totalAudioEnergy: report.totalAudioEnergy });
          }
        });
        for (const sender of connection.getSenders()) {
          if (sender.track && sender.track.kind === "audio") {
            result.push({ type: "sender", label: sender.track.label, enabled: sender.track.enabled,
              muted: sender.track.muted, readyState: sender.track.readyState });
          }
        }
      }
      return { contextState: context.state, connections: connections.length, result };
    },
    async load(id, base64) {
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      clips.set(id, await context.decodeAudioData(bytes.buffer));
      return clips.get(id).duration;
    },
    async play(id) {
      if (context.state !== "running") await context.resume();
      const source = context.createBufferSource();
      source.buffer = clips.get(id);
      source.connect(destination);
      source.start();
      return source.buffer.duration;
    },
  };
})();
