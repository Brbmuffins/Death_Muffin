const form = document.querySelector("#account-form");
const switchModeButton = document.querySelector(".switch-mode");
const submitButton = document.querySelector(".enter-button");
const submitLabel = document.querySelector(".enter-button__label");
const formKicker = document.querySelector("#form-kicker");
const status = document.querySelector(".form-status");
const nameField = document.querySelector(".field--name");
const confirmField = document.querySelector(".field--confirm");
const displayName = document.querySelector("#display-name");
const email = document.querySelector("#email");
const emailField = email.closest(".field");
const password = document.querySelector("#password");
const confirmPassword = document.querySelector("#confirm-password");
const remember = document.querySelector(".remember");
const forgotAction = document.querySelector(".forgot-action");
const forgotDialog = document.querySelector(".forgot-dialog");
const recoveryEmail = document.querySelector("#recovery-email");
const revealPassword = document.querySelector(".reveal-password");
const soundToggle = document.querySelector(".sound-toggle");
const gateway = document.querySelector(".gateway");
const spellCanvas = document.querySelector(".spell-canvas");

let mode = "login";
let soundEnabled = true;
let audioContext;
let ambienceGain;
try { soundEnabled = localStorage.getItem("dm_login_sound") !== "off"; } catch {}
soundToggle.setAttribute("aria-pressed", String(soundEnabled));
soundToggle.textContent = `Sound effects: ${soundEnabled ? "on" : "off"}`;

function getAudioContext() {
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextClass) return null;
  audioContext ??= new AudioContextClass();
  if (audioContext.state === "suspended") audioContext.resume();
  return audioContext;
}

function createNoiseBuffer(context, duration, weight = 0) {
  const frameCount = Math.ceil(context.sampleRate * duration);
  const buffer = context.createBuffer(1, frameCount, context.sampleRate);
  const data = buffer.getChannelData(0);
  let previous = 0;

  for (let index = 0; index < frameCount; index += 1) {
    const white = Math.random() * 2 - 1;
    previous = previous * weight + white * (1 - weight);
    data[index] = previous;
  }

  return buffer;
}

function startAmbience() {
  if (!soundEnabled) return;
  const context = getAudioContext();
  if (!context) return;
  if (!ambienceGain) {
    ambienceGain = context.createGain();
    ambienceGain.gain.value = 0;
    ambienceGain.connect(context.destination);
    const wind = context.createBufferSource();
    const filter = context.createBiquadFilter();
    wind.buffer = createNoiseBuffer(context, 4, 0.97);
    wind.loop = true;
    filter.type = "lowpass";
    filter.frequency.value = 420;
    wind.connect(filter);
    filter.connect(ambienceGain);
    wind.start();
    const drone = context.createOscillator();
    const droneGain = context.createGain();
    drone.type = "sine";
    drone.frequency.value = 55;
    droneGain.gain.value = 0.18;
    drone.connect(droneGain);
    droneGain.connect(ambienceGain);
    drone.start();
  }
  ambienceGain.gain.setTargetAtTime(document.hidden ? 0 : 0.2, context.currentTime, 0.5);
}

// Chrome unlocks audio after the first click or keypress on this page.
function unlockLoginAudio(event) {
  if (event.target instanceof Element && event.target.closest(".sound-toggle")) return;
  startAmbience();
}
window.addEventListener("pointerdown", unlockLoginAudio, { passive: true });
window.addEventListener("keydown", unlockLoginAudio, { passive: true });
document.addEventListener("visibilitychange", () => {
  if (ambienceGain && audioContext) ambienceGain.gain.setTargetAtTime(soundEnabled && !document.hidden ? 0.2 : 0, audioContext.currentTime, 0.2);
});

function playBoneClatter(context, output, startTime) {
  const impacts = [0, 0.055, 0.128, 0.205];

  impacts.forEach((offset, index) => {
    const hitTime = startTime + offset + Math.random() * 0.018;
    const source = context.createBufferSource();
    const band = context.createBiquadFilter();
    const highpass = context.createBiquadFilter();
    const gain = context.createGain();

    source.buffer = createNoiseBuffer(context, 0.095, 0.08);
    source.playbackRate.value = 0.92 + Math.random() * 0.22;
    band.type = "bandpass";
    band.frequency.value = 1050 + index * 420 + Math.random() * 580;
    band.Q.value = 3.4 + Math.random() * 2;
    highpass.type = "highpass";
    highpass.frequency.value = 560 + Math.random() * 220;

    gain.gain.setValueAtTime(0.0001, hitTime);
    gain.gain.exponentialRampToValueAtTime(0.2 - index * 0.022, hitTime + 0.004);
    gain.gain.exponentialRampToValueAtTime(0.0001, hitTime + 0.075 + Math.random() * 0.035);

    source.connect(band);
    band.connect(highpass);
    highpass.connect(gain);
    gain.connect(output);
    source.start(hitTime);
    source.stop(hitTime + 0.12);
  });
}

function playSpectralGrowl(context, output, startTime) {
  const growlGain = context.createGain();
  const lowpass = context.createBiquadFilter();
  const distortion = context.createWaveShaper();
  const fundamental = context.createOscillator();
  const overtone = context.createOscillator();
  const vibration = context.createOscillator();
  const vibrationDepth = context.createGain();
  const rumble = context.createBufferSource();
  const rumbleFilter = context.createBiquadFilter();
  const rumbleGain = context.createGain();
  const duration = 0.82;

  const curve = new Float32Array(256);
  for (let index = 0; index < curve.length; index += 1) {
    const value = (index * 2) / (curve.length - 1) - 1;
    curve[index] = Math.tanh(value * 2.4);
  }

  distortion.curve = curve;
  distortion.oversample = "2x";
  lowpass.type = "lowpass";
  lowpass.Q.value = 4.2;
  lowpass.frequency.setValueAtTime(640, startTime);
  lowpass.frequency.exponentialRampToValueAtTime(150, startTime + duration);

  growlGain.gain.setValueAtTime(0.0001, startTime);
  growlGain.gain.exponentialRampToValueAtTime(0.12, startTime + 0.07);
  growlGain.gain.setValueAtTime(0.095, startTime + 0.31);
  growlGain.gain.exponentialRampToValueAtTime(0.0001, startTime + duration);

  fundamental.type = "sawtooth";
  overtone.type = "triangle";
  fundamental.frequency.setValueAtTime(78, startTime);
  fundamental.frequency.exponentialRampToValueAtTime(43, startTime + duration);
  overtone.frequency.setValueAtTime(128, startTime);
  overtone.frequency.exponentialRampToValueAtTime(67, startTime + duration);

  vibration.type = "sine";
  vibration.frequency.value = 15.5;
  vibrationDepth.gain.value = 8;
  vibration.connect(vibrationDepth);
  vibrationDepth.connect(fundamental.frequency);
  vibrationDepth.connect(overtone.frequency);

  rumble.buffer = createNoiseBuffer(context, duration, 0.965);
  rumbleFilter.type = "bandpass";
  rumbleFilter.frequency.value = 118;
  rumbleFilter.Q.value = 1.2;
  rumbleGain.gain.setValueAtTime(0.0001, startTime);
  rumbleGain.gain.exponentialRampToValueAtTime(0.055, startTime + 0.09);
  rumbleGain.gain.exponentialRampToValueAtTime(0.0001, startTime + duration);

  fundamental.connect(distortion);
  overtone.connect(distortion);
  distortion.connect(lowpass);
  lowpass.connect(growlGain);
  growlGain.connect(output);
  rumble.connect(rumbleFilter);
  rumbleFilter.connect(rumbleGain);
  rumbleGain.connect(output);

  fundamental.start(startTime);
  overtone.start(startTime);
  vibration.start(startTime);
  rumble.start(startTime);
  fundamental.stop(startTime + duration);
  overtone.stop(startTime + duration);
  vibration.stop(startTime + duration);
  rumble.stop(startTime + duration);
}

function playGateSound() {
  if (!soundEnabled) return;
  const context = getAudioContext();
  if (!context) return;

  const compressor = context.createDynamicsCompressor();
  const master = context.createGain();
  const startTime = context.currentTime + 0.015;

  compressor.threshold.value = -22;
  compressor.knee.value = 18;
  compressor.ratio.value = 5;
  compressor.attack.value = 0.004;
  compressor.release.value = 0.16;
  master.gain.value = 0.48;
  master.connect(compressor);
  compressor.connect(context.destination);

  playBoneClatter(context, master, startTime);
  playSpectralGrowl(context, master, startTime + 0.075);
}

function createGraveAtmosphere(canvas) {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (!canvas || reducedMotion.matches) return;

  const context = canvas.getContext("2d");
  const smoke = [];
  const ash = [];
  let width = 0;
  let height = 0;
  let pixelRatio = 1;
  let animationFrame = 0;
  let lastTime = performance.now();
  let smokeTimer = 0;
  let ashTimer = 0;
  let awakenedUntil = 0;

  function resize() {
    width = window.innerWidth;
    height = window.innerHeight;
    pixelRatio = Math.min(window.devicePixelRatio || 1, 1.5);
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
  }

  function source(kind) {
    const compact = width <= 900;
    const mobile = width <= 560;
    const ritualX = width * (mobile ? 0.27 : compact ? 0.3 : 0.328);
    const staffX = width * (mobile ? 0.285 : compact ? 0.307 : 0.333);
    return kind === "staff"
      ? { x: staffX, y: height * 0.574 }
      : { x: ritualX, y: height * 0.185 };
  }

  function breatheSmoke(kind = "ground", count = 1, force = 1) {
    for (let index = 0; index < count; index += 1) {
      const origin = kind === "ground"
        ? { x: width * (0.05 + Math.random() * 0.52), y: height * (0.72 + Math.random() * 0.2) }
        : source(kind);
      const ground = kind === "ground";
      const size = (ground ? 70 + Math.random() * 100 : 34 + Math.random() * 58) * force;

      smoke.push({
        x: origin.x + (Math.random() - 0.5) * (ground ? width * 0.13 : 28),
        y: origin.y + (Math.random() - 0.5) * (ground ? 30 : 20),
        vx: (ground ? 4 + Math.random() * 9 : -2 + Math.random() * 6) * (Math.random() > 0.45 ? 1 : -1),
        vy: -(ground ? 3 + Math.random() * 5 : 6 + Math.random() * 9),
        size,
        squash: ground ? 0.26 + Math.random() * 0.18 : 0.42 + Math.random() * 0.2,
        age: 0,
        life: ground ? 9 + Math.random() * 7 : 6 + Math.random() * 5,
        phase: Math.random() * Math.PI * 2,
        curl: (10 + Math.random() * 22) * (Math.random() > 0.5 ? 1 : -1),
        tone: Math.random(),
      });
    }
  }

  function loosenAsh(count = 1) {
    for (let index = 0; index < count; index += 1) {
      ash.push({
        x: width * (0.03 + Math.random() * 0.57),
        y: height * (0.48 + Math.random() * 0.5),
        vx: -3 + Math.random() * 7,
        vy: -(5 + Math.random() * 10),
        age: 0,
        life: 5 + Math.random() * 6,
        length: 1.5 + Math.random() * 3.5,
        phase: Math.random() * Math.PI * 2,
        angle: Math.random() * Math.PI,
        spin: (Math.random() - 0.5) * 0.35,
      });
    }
  }

  function drawGlow(origin, radius, strength) {
    const glow = context.createRadialGradient(origin.x, origin.y, 0, origin.x, origin.y, radius);
    glow.addColorStop(0, `rgba(220, 196, 255, ${strength})`);
    glow.addColorStop(0.22, `rgba(155, 92, 255, ${strength * 0.42})`);
    glow.addColorStop(1, "rgba(124, 58, 237, 0)");
    context.fillStyle = glow;
    context.beginPath();
    context.arc(origin.x, origin.y, radius, 0, Math.PI * 2);
    context.fill();
  }

  function drawGroundHaze(now, strength) {
    const sway = Math.sin(now / 6200) * width * 0.018;
    const haze = context.createRadialGradient(
      width * 0.29 + sway,
      height * 0.83,
      0,
      width * 0.29 + sway,
      height * 0.83,
      Math.max(width * 0.42, 340),
    );
    haze.addColorStop(0, `rgba(72, 52, 89, ${0.05 * strength})`);
    haze.addColorStop(0.44, `rgba(46, 38, 53, ${0.035 * strength})`);
    haze.addColorStop(1, "rgba(12, 10, 15, 0)");
    context.fillStyle = haze;
    context.fillRect(0, height * 0.48, width * 0.72, height * 0.52);
  }

  function drawSmokeCloud(cloud, now) {
    const progress = cloud.age / cloud.life;
    const fade = Math.sin(progress * Math.PI);
    const curl = Math.sin(now / 2100 + cloud.phase) * cloud.curl;
    const x = cloud.x + curl * progress;
    const y = cloud.y;
    const scale = 0.72 + progress * 0.58;
    const alpha = fade * (cloud.tone > 0.72 ? 0.16 : 0.1);
    const color = cloud.tone > 0.72 ? "120, 83, 153" : "78, 67, 86";

    context.save();
    context.translate(x, y);
    context.rotate(Math.sin(now / 5400 + cloud.phase) * 0.08);
    context.scale(scale, scale);
    context.filter = `blur(${Math.max(10, cloud.size * 0.12)}px)`;
    context.fillStyle = `rgba(${color}, ${alpha})`;

    const lobes = [
      { x: -0.34, y: 0.06, size: 0.68 },
      { x: 0, y: -0.07, size: 1 },
      { x: 0.4, y: 0.08, size: 0.62 },
    ];
    lobes.forEach((lobe) => {
      context.beginPath();
      context.ellipse(
        cloud.size * lobe.x,
        cloud.size * lobe.y,
        cloud.size * lobe.size,
        cloud.size * cloud.squash * lobe.size,
        0,
        0,
        Math.PI * 2,
      );
      context.fill();
    });
    context.restore();
  }

  function render(now) {
    const delta = Math.min((now - lastTime) / 1000, 0.05);
    lastTime = now;
    smokeTimer += delta;
    ashTimer += delta;

    context.clearRect(0, 0, width, height);
    const awakened = now < awakenedUntil ? 1.75 : 1;
    const slowPulse = 0.5 + Math.sin(now / 1900) * 0.5;
    const nervousFlicker = 0.88 + Math.sin(now / 317) * 0.06 + Math.sin(now / 773) * 0.06;

    drawGroundHaze(now, awakened);
    context.globalCompositeOperation = "screen";
    drawGlow(source("ritual"), Math.min(width * 0.065, 100), (0.01 + slowPulse * 0.013) * nervousFlicker * awakened);
    drawGlow(source("staff"), 42, (0.027 + slowPulse * 0.02) * nervousFlicker * awakened);

    if (smokeTimer > 0.72) {
      breatheSmoke("ground", 1);
      if (Math.random() > 0.58) breatheSmoke("staff", 1);
      smokeTimer = 0;
    }

    if (ashTimer > 0.48) {
      loosenAsh(Math.random() > 0.72 ? 2 : 1);
      ashTimer = 0;
    }

    context.globalCompositeOperation = "source-over";
    for (let index = smoke.length - 1; index >= 0; index -= 1) {
      const cloud = smoke[index];
      cloud.age += delta;
      if (cloud.age >= cloud.life) {
        smoke.splice(index, 1);
        continue;
      }
      cloud.x += cloud.vx * delta * 1.4;
      cloud.y += cloud.vy * delta * 1.3;
      drawSmokeCloud(cloud, now);
    }

    for (let index = ash.length - 1; index >= 0; index -= 1) {
      const fleck = ash[index];
      fleck.age += delta;
      if (fleck.age >= fleck.life) {
        ash.splice(index, 1);
        continue;
      }

      const progress = fleck.age / fleck.life;
      fleck.x += (fleck.vx + Math.sin(now / 1300 + fleck.phase) * 2.4) * delta;
      fleck.y += fleck.vy * delta;
      fleck.angle += fleck.spin * delta;
      context.save();
      context.translate(fleck.x, fleck.y);
      context.rotate(fleck.angle);
      context.fillStyle = `rgba(187, 178, 166, ${Math.sin(progress * Math.PI) * 0.5})`;
      context.fillRect(-0.45, -fleck.length * 0.5, 0.9, fleck.length);
      context.restore();
    }

    animationFrame = requestAnimationFrame(render);
  }

  resize();
  breatheSmoke("ground", 7);
  breatheSmoke("staff", 3);
  loosenAsh(10);
  animationFrame = requestAnimationFrame(render);
  window.addEventListener("resize", resize, { passive: true });

  window.awakenGraveAtmosphere = () => {
    awakenedUntil = performance.now() + 1400;
    breatheSmoke("staff", 4, 1.16);
    breatheSmoke("ground", 2, 1.08);
    loosenAsh(7);
  };

  document.addEventListener("visibilitychange", () => {
    cancelAnimationFrame(animationFrame);
    if (!document.hidden) {
      lastTime = performance.now();
      animationFrame = requestAnimationFrame(render);
    }
  });
}

createGraveAtmosphere(spellCanvas);

function setError(input, message) {
  const field = input.closest(".field");
  const error = field.querySelector(".field__error");
  field.classList.toggle("has-error", Boolean(message));
  input.setAttribute("aria-invalid", String(Boolean(message)));
  error.textContent = message;
}

function clearErrors() {
  form.querySelectorAll(".field").forEach((field) => field.classList.remove("has-error"));
  form.querySelectorAll("input").forEach((input) => input.removeAttribute("aria-invalid"));
  form.querySelectorAll(".field__error").forEach((error) => {
    error.textContent = "";
  });
  status.textContent = "";
}

function validate() {
  clearErrors();
  let valid = true;

  // Signing up needs a username only. Mirror the server's rule so the error is readable here
  // instead of arriving as a 400 from /register.
  if (mode === "register" && !/^[a-zA-Z0-9_]{3,32}$/.test(displayName.value.trim())) {
    setError(displayName, "Use 3–32 letters, numbers or underscores.");
    valid = false;
  }

  // The shared field is the username (or an email, for accounts that chose to add one) at login;
  // registration hides it entirely, so there is nothing to check in that mode.
  if (mode === "login" && !email.validity.valid) {
    setError(email, "Enter your username.");
    valid = false;
  }

  if (password.value.length < (mode === "register" ? 8 : 1)) {
    setError(password, mode === "register" ? "Your password needs at least eight characters." : "Enter your password.");
    valid = false;
  }

  if (mode === "register" && confirmPassword.value !== password.value) {
    setError(confirmPassword, "The passwords do not match.");
    valid = false;
  }

  return valid;
}

function setMode(nextMode) {
  mode = nextMode;
  const registering = mode === "register";

  clearErrors();
  nameField.hidden = !registering;
  confirmField.hidden = !registering;
  displayName.required = registering;
  displayName.maxLength = 32;
  displayName.placeholder = registering ? "Pick a username" : "Name your wanderer";
  confirmPassword.required = registering;
  password.autocomplete = registering ? "new-password" : "current-password";
  password.minLength = registering ? 8 : 1;
  // No email is collected at signup — this covenant is friends-only. Existing accounts that have
  // an email can still log in with it, so the field stays as username-or-email in login mode.
  emailField.hidden = registering;
  email.required = !registering;
  email.type = "text";
  email.autocomplete = registering ? "off" : "username";
  email.placeholder = "Your username";
  document.querySelector('label[for="email"]').textContent = "Username or email";
  document.querySelector('label[for="display-name"]').textContent = "Username";
  remember.hidden = registering;
  forgotAction.hidden = registering;
  formKicker.textContent = "Muffin Developed";
  submitLabel.textContent = registering ? "Join" : "Enter";
  document.querySelector(".account-switch p").textContent = registering
    ? "Already sworn?"
    : "New to the covenant?";
  switchModeButton.textContent = registering ? "Return to login" : "Create account";

  (registering ? displayName : email).focus();
}

switchModeButton.addEventListener("click", () => {
  setMode(mode === "login" ? "register" : "login");
});

revealPassword.addEventListener("click", () => {
  const revealing = password.type === "password";
  password.type = revealing ? "text" : "password";
  revealPassword.setAttribute("aria-pressed", String(revealing));
  revealPassword.setAttribute("aria-label", revealing ? "Hide password" : "Show password");
});

forgotAction.addEventListener("click", () => {
  status.textContent = "Email recovery is not configured. Contact the game administrator for a password reset.";
});

soundToggle.addEventListener("click", () => {
  soundEnabled = !soundEnabled;
  soundToggle.setAttribute("aria-pressed", String(soundEnabled));
  soundToggle.textContent = `Sound effects: ${soundEnabled ? "on" : "off"}`;
  try { localStorage.setItem("dm_login_sound", soundEnabled ? "on" : "off"); } catch {}
  if (soundEnabled) { startAmbience(); playGateSound(); }
  else if (ambienceGain && audioContext) ambienceGain.gain.setTargetAtTime(0, audioContext.currentTime, 0.1);
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!validate()) return;
  const openingStartedAt = performance.now();
  startAmbience();
  playGateSound();
  window.awakenGraveAtmosphere?.();
  submitButton.disabled = true;
  submitButton.classList.add("is-loading");
  gateway.classList.add("spell-surge");
  status.textContent = mode === "login" ? "Opening the gate…" : "Binding your oath…";
  try {
    const response = await fetch(`api/${mode === "login" ? "login" : "register"}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mode === "login"
        ? { username: email.value.trim(), password: password.value }
        : { username: displayName.value.trim(), password: password.value }),
    });
    const data = await response.json();
    if (!response.ok || !data.token) throw new Error(data.error || "Could not open the gate.");
    sessionStorage.setItem("dm_jwt", data.token);
    if (form.querySelector('[name="remember"]').checked && mode === "login") localStorage.setItem("dm_jwt", data.token);
    else localStorage.removeItem("dm_jwt");
    await new Promise(resolve => window.setTimeout(resolve, Math.max(0, 950 - (performance.now() - openingStartedAt))));
    window.location.assign("play/");
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : "Cannot reach the account service. Please try again.";
    submitButton.disabled = false;
    submitButton.classList.remove("is-loading");
    gateway.classList.remove("spell-surge");
  }
});
