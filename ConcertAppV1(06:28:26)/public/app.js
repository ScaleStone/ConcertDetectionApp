const state = {
  user: JSON.parse(localStorage.getItem('serene:user') || 'null'),
  authMode: 'guest',
  avatar: 'sage',
  dashboard: null,
  breathTimer: null,
  voiceMemo: null,
  accountModalMode: 'signup'
};

const avatars = [
  ['sage', '#7cc9b4', '#0e745d'],
  ['luma', '#c9b7f4', '#6450a8'],
  ['sol', '#f6c873', '#9c6a00'],
  ['rose', '#f3a5ad', '#a44855'],
  ['sky', '#9ed5ee', '#226d8f'],
  ['moss', '#b9d88d', '#55752f']
];

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

window.addEventListener('unhandledrejection', (event) => {
  event.preventDefault();
  showToast(event.reason?.message || 'Something needs attention before continuing.');
});

window.addEventListener('error', (event) => {
  event.preventDefault();
  showToast(event.message || 'Something needs attention before continuing.');
});

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'content-type': 'application/json' },
    ...options,
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Request failed.');
  return data;
}

function saveUser(user) {
  state.user = user;
  localStorage.setItem('serene:user', JSON.stringify(user));
  updateProfileUI();
  refreshDashboard();
}

function syncAccountVisibility() {
  document.body.classList.toggle('account-mode', state.authMode === 'account');
  document.body.classList.toggle('guest-mode', state.authMode === 'guest');
  document.body.classList.toggle('guest-session', Boolean(state.user?.guest));
  document.body.classList.toggle('account-session', Boolean(state.user && !state.user.guest));
}

function setAccountModalMode(mode) {
  state.accountModalMode = mode;
  $('.account-card').classList.toggle('login-mode', mode === 'login');
  $$('[data-modal-mode]').forEach((button) => {
    button.classList.toggle('active', button.dataset.modalMode === mode);
  });
  $('.modal-name-field').hidden = mode !== 'signup';
  $('#modalDisplayName').disabled = mode !== 'signup';
  $('#modalDisplayName').required = mode === 'signup';
  $('.account-submit').textContent = mode === 'signup' ? 'Create account' : 'Log in';
  $('#accountModalTitle').textContent = mode === 'signup'
    ? 'Create your TherapyAI account'
    : 'Welcome back to TherapyAI';
  $('.modal-copy').textContent = mode === 'signup'
    ? 'Save your journal history, mood trends, sleep insights, and wellness streaks in one calm place.'
    : 'Your profile is already saved. Log in with your email and password to return to your wellness space.';
}

function openAccountModal(mode = 'signup') {
  setAccountModalMode(mode);
  $('#accountModal').hidden = false;
  setTimeout(() => $('#modalEmail').focus(), 0);
}

function closeAccountModal() {
  $('#accountModal').hidden = true;
}

function openAccountSignup() {
  state.authMode = 'account';
  $$('[data-auth-mode]').forEach((button) => {
    button.classList.toggle('active', button.dataset.authMode === 'account');
  });
  syncAccountVisibility();
  openAccountModal('signup');
}

function requireUser() {
  if (state.user) return state.user;
  throw new Error('Enter as guest or create an account first.');
}

function renderAvatars() {
  $('#avatarGrid').innerHTML = avatars
    .map(([name, fill, stroke]) => `
      <button type="button" class="avatar-option ${name === state.avatar ? 'active' : ''}" data-avatar="${name}" aria-label="${name} avatar">
        <svg viewBox="0 0 80 80" role="img" aria-hidden="true">
          <circle cx="40" cy="40" r="30" fill="${fill}" />
          <path d="M24 48c8 10 24 10 32 0" fill="none" stroke="${stroke}" stroke-width="5" stroke-linecap="round"/>
          <circle cx="30" cy="34" r="4" fill="${stroke}" />
          <circle cx="50" cy="34" r="4" fill="${stroke}" />
        </svg>
      </button>
    `)
    .join('');
}

function updateProfileUI() {
  if (state.user) {
    $('#displayName').value = state.user.displayName || '';
    $('#paidTier').checked = Boolean(state.user.paid);
    state.avatar = state.user.avatar || 'sage';
  }
  renderAvatars();
  syncAccountVisibility();
}

function showToast(message) {
  const toast = document.createElement('div');
  toast.className = 'toast';
  toast.textContent = message;
  document.body.append(toast);
  setTimeout(() => toast.remove(), 3200);
}

function handleCrisis(payload) {
  $('#crisisMessage').textContent = payload.message;
  $('#crisisSupportText').textContent = payload.support || '';
  $('#ackCrisis').checked = false;
  $('#continueAfterCrisis').disabled = true;
  $('#crisisOverlay').hidden = false;
  $('#emergencySupportBtn').focus();
}

function appendMessage(container, role, text) {
  const item = document.createElement('article');
  item.className = `message ${role}`;
  item.innerHTML = `<strong>${role === 'user' ? 'You' : role === 'peer' ? 'Peer' : 'Serene'}</strong><p></p>`;
  item.querySelector('p').textContent = text;
  container.append(item);
  container.scrollTop = container.scrollHeight;
}

function startSpeech(target, onDone) {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) {
    showToast('Speech recognition is not available in this browser.');
    return;
  }
  const recognition = new Recognition();
  recognition.lang = 'en-US';
  recognition.interimResults = true;
  recognition.onresult = (event) => {
    const text = [...event.results].map((result) => result[0].transcript).join('');
    target.value !== undefined ? (target.value = text) : (target.textContent = text);
  };
  recognition.onend = () => onDone?.();
  recognition.start();
}

async function refreshDashboard() {
  if (!state.user || state.user.guest) {
    renderGuestDashboard();
    return;
  }
  const dashboard = await api(`/api/dashboard?userId=${encodeURIComponent(state.user.id)}`);
  state.dashboard = dashboard;
  $('#dashboardName').textContent = dashboard.user?.displayName || state.user.displayName || 'Guest';
  $('.dashboard-grid').hidden = false;
  renderMetrics(dashboard.stats, dashboard.sleeps);
  renderMoodChart(dashboard.entries);
  renderActivity(dashboard);
  renderJournalCalendar(dashboard.entries);
  renderSleepChart(dashboard.sleeps);
  renderCommunity(dashboard.communityMessages || []);
}

function renderGuestDashboard() {
  state.dashboard = { entries: [], sleeps: [], sessions: [], communityMessages: [] };
  $('#dashboardName').textContent = state.user?.displayName || 'Guest';
  $('#metricGrid').innerHTML = `
    <article class="guest-dashboard-empty">
      <h2>Guest dashboard is private by default</h2>
      <p>Create an account to save progress, track streaks, see mood trends, keep journal history, and review sleep insights over time.</p>
      <button class="primary guest-account-cta" id="guestAccountCta" type="button">Create a free account</button>
    </article>
  `;
  $('.dashboard-grid').hidden = true;
  renderJournalCalendar([]);
  renderSleepChart([]);
  renderCommunity([]);
}

function renderMetrics(stats, sleeps = []) {
  const avgSleep = sleeps.length
    ? `${(sleeps.reduce((sum, log) => sum + log.hours, 0) / sleeps.length).toFixed(1)}h`
    : '0h';
  const metrics = [
    ['Current Streak', `${stats.streakDays ?? 0} days`, 'Keep it going!', '🏅'],
    ['Chat Sessions', stats.sessions ?? 0, 'This week', '💬'],
    ['Journal Entries', stats.journalEntries ?? 0, 'This week', '📖'],
    ['Avg Sleep', avgSleep, 'Last 7 days', '☾']
  ];
  $('#metricGrid').innerHTML = metrics.map(([label, value, caption, icon]) => `
    <article class="metric">
      <span class="metric-icon" aria-hidden="true">${icon}</span>
      <h2>${label}</h2>
      <strong>${value}</strong>
      <p>${caption}</p>
    </article>
  `).join('');
}

function renderMoodChart(entries) {
  if (!entries.length) {
    $('#moodChart').innerHTML = '<div class="empty-chart">No mood trend data yet.</div>';
    return;
  }
  const moods = { calm: 6, hopeful: 8, sad: 5, anxious: 6, angry: 4 };
  const values = entries.slice(-7).map((entry) => moods[entry.mood] || 6);
  $('#moodChart').innerHTML = lineChartSvg(values);
}

function renderSleepChart(logs = []) {
  const range = Number($('#sleepRange').value || 7);
  const points = logs.slice(-range).map((log, index) => [index * (320 / Math.max(1, range - 1)) + 18, 150 - Math.min(10, log.hours) * 13]);
  $('#sleepChart').innerHTML = points.length ? lineChartSvg(logs.slice(-range).map((log) => Math.min(10, log.hours))) : '';
}

function lineChartSvg(values) {
  const labels = ['4/22', '4/23', '4/24', '4/25', '4/26', '4/27', '4/28'];
  const x0 = 54;
  const y0 = 284;
  const width = 650;
  const height = 250;
  const points = values.map((value, index) => {
    const x = x0 + index * (width / 6);
    const y = y0 - (value / 10) * height;
    return [x, y];
  });
  const path = points.map(([x, y], index) => `${index ? 'L' : 'M'} ${x} ${y}`).join(' ');
  const circles = points.map(([x, y]) => `<circle cx="${x}" cy="${y}" r="9" />`).join('');
  const vGrid = labels.map((_, index) => `<path class="gridline" d="M${x0 + index * (width / 6)} ${y0 - height}V${y0}" />`).join('');
  const xLabels = labels.map((label, index) => `<text x="${x0 + index * (width / 6)}" y="${y0 + 30}" text-anchor="middle">${label}</text>`).join('');
  return `<svg viewBox="0 0 760 340" role="img" aria-label="Mood trend chart">
    <path class="axis" d="M${x0} ${y0 - height}V${y0}H${x0 + width}" />
    <path class="gridline" d="M${x0} ${y0 - height}H${x0 + width}M${x0} ${y0 - height * 0.6}H${x0 + width}M${x0} ${y0 - height * 0.3}H${x0 + width}" />
    ${vGrid}
    <path class="trend" d="${path}" />
    ${circles}
    <text x="${x0 - 20}" y="${y0 + 5}" text-anchor="end">0</text>
    <text x="${x0 - 20}" y="${y0 - height * 0.3 + 5}" text-anchor="end">3</text>
    <text x="${x0 - 20}" y="${y0 - height * 0.6 + 5}" text-anchor="end">6</text>
    <text x="${x0 - 20}" y="${y0 - height + 5}" text-anchor="end">10</text>
    ${xLabels}
  </svg>`;
}

function renderActivity(dashboard) {
  const values = [
    dashboard.sessions.length,
    dashboard.entries.length,
    15,
    dashboard.sleeps.length
  ];
  $('#activityList').innerHTML = barChartSvg(values);
}

function barChartSvg(values) {
  const labels = ['Chat Sessions', 'Journal Entries', 'Breathing', 'Sleep Logs'];
  const x0 = 70;
  const y0 = 284;
  const width = 650;
  const height = 250;
  const max = 16;
  const bars = values.map((value, index) => {
    const barWidth = 125;
    const gap = width / 4;
    const x = x0 + index * gap + 17;
    const h = Math.min(max, value) / max * height;
    return `<rect x="${x}" y="${y0 - h}" width="${barWidth}" height="${h}" rx="10" />
      <text x="${x + barWidth / 2}" y="${y0 + 24}" text-anchor="middle">${labels[index]}</text>`;
  }).join('');
  return `<svg viewBox="0 0 760 340" role="img" aria-label="Weekly activity bar chart">
    <path class="axis" d="M${x0} ${y0 - height}V${y0}H${x0 + width}" />
    <path class="gridline" d="M${x0} ${y0 - height}H${x0 + width}M${x0} ${y0 - height * 0.75}H${x0 + width}M${x0} ${y0 - height * 0.5}H${x0 + width}M${x0} ${y0 - height * 0.25}H${x0 + width}" />
    <path class="gridline" d="M${x0 + width * 0.25} ${y0 - height}V${y0}M${x0 + width * 0.5} ${y0 - height}V${y0}M${x0 + width * 0.75} ${y0 - height}V${y0}M${x0 + width} ${y0 - height}V${y0}" />
    <text x="${x0 - 12}" y="${y0 + 5}" text-anchor="end">0</text>
    <text x="${x0 - 12}" y="${y0 - height * 0.25 + 5}" text-anchor="end">4</text>
    <text x="${x0 - 12}" y="${y0 - height * 0.5 + 5}" text-anchor="end">8</text>
    <text x="${x0 - 12}" y="${y0 - height * 0.75 + 5}" text-anchor="end">12</text>
    <text x="${x0 - 12}" y="${y0 - height + 5}" text-anchor="end">16</text>
    ${bars}
  </svg>`;
}

function renderJournalCalendar(entries = []) {
  const activeDays = new Set(entries.map((entry) => new Date(entry.createdAt).getDate()));
  $('#journalCalendar').innerHTML = Array.from({ length: 31 }, (_, index) => {
    const day = index + 1;
    return `<span class="${activeDays.has(day) ? 'has-entry' : ''}">${day}</span>`;
  }).join('');
}

function renderCommunity(messages) {
  const room = $('#roomSelect').value;
  const list = messages.filter((message) => message.room === room);
  $('#communityLog').innerHTML = list.length ? '' : '<p class="empty">No peer messages in this room yet.</p>';
  list.forEach((message) => appendMessage($('#communityLog'), 'peer', `${message.displayName}: ${message.message}`));
}

function setupBreathing() {
  const patterns = {
    box: [['Inhale', 4], ['Hold', 4], ['Exhale', 4], ['Hold', 4]],
    478: [['Inhale', 4], ['Hold', 7], ['Exhale', 8]],
    calm: [['Inhale', 4], ['Exhale', 6]]
  };
  let stepIndex = 0;
  clearInterval(state.breathTimer);
  const tick = () => {
    const [label, seconds] = patterns[$('#breathPattern').value][stepIndex];
    $('#breathStep').textContent = label === 'Inhale' ? 'Breathe In' : label;
    $('#breathOrb strong').textContent = seconds;
    $('#breathOrb').style.animationDuration = `${seconds}s`;
    $('#breathOrb').classList.toggle('expand', label === 'Inhale');
    stepIndex = (stepIndex + 1) % patterns[$('#breathPattern').value].length;
  };
  tick();
  state.breathTimer = setInterval(tick, 4200);
}

function setupMeditations() {
  $$('.meditation').forEach((button) => {
    button.addEventListener('click', () => {
      const minutes = button.dataset.minutes;
      const audio = $('#meditationAudio');
      audio.src = `data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAESsAACJWAAACABAAZGF0YQAAAAA=`;
      showToast(`${minutes}-minute meditation selected. Connect hosted audio files when deploying.`);
    });
  });
}

function switchView(id, updateHash = true) {
  $$('.view').forEach((view) => view.classList.toggle('active', view.id === id));
  $$('.nav-btn').forEach((button) => button.classList.toggle('active', button.dataset.view === id));
  if (updateHash) location.hash = id;
  window.scrollTo(0, 0);
}

function bindEvents() {
  $$('.nav-btn').forEach((button) => button.addEventListener('click', () => switchView(button.dataset.view)));
  document.addEventListener('click', (event) => {
    if (event.target.closest('#guestAccountCta')) openAccountSignup();
  });
  $$('[data-modal-mode]').forEach((button) => {
    button.addEventListener('click', () => setAccountModalMode(button.dataset.modalMode));
  });
  $('#accountModalClose').addEventListener('click', closeAccountModal);
  $('#accountModal').addEventListener('click', (event) => {
    if (event.target === $('#accountModal')) closeAccountModal();
  });
  $('#accountModalForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const email = $('#modalEmail').value.trim();
    const password = $('#modalPassword').value;
    const displayName = $('#modalDisplayName').value.trim();
    try {
      const data = state.accountModalMode === 'signup'
        ? await api('/api/auth/register', {
            method: 'POST',
            body: { email, password, displayName, avatar: state.avatar, paid: false }
          })
        : await api('/api/auth/login', {
            method: 'POST',
            body: { email, password }
          });
      saveUser(data.user);
      closeAccountModal();
      $('#accountModalForm').reset();
      showToast(state.accountModalMode === 'signup' ? 'Account created. Progress will be saved now.' : 'Welcome back.');
    } catch (error) {
      showToast(error.message);
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !$('#accountModal').hidden) closeAccountModal();
  });
  $('#quickGuestBtn').addEventListener('click', async () => {
    if (state.user) {
      $('.auth-strip').classList.toggle('is-open');
      return;
    }
    const data = await api('/api/auth/guest', { method: 'POST', body: {} });
    const updated = await api('/api/profile', {
      method: 'POST',
      body: {
        userId: data.user.id,
        displayName: $('#displayName').value || data.user.displayName,
        avatar: state.avatar,
        paid: $('#paidTier').checked
      }
    });
    saveUser(updated.user);
    showToast(`Welcome, ${updated.user.displayName}.`);
  });
  $$('.oauth-btn').forEach((button) => {
    button.addEventListener('click', () => {
      showToast(`${button.dataset.oauth} OAuth is ready for Clerk/Auth.js wiring.`);
    });
  });
  $$('.mood-buttons button').forEach((button) => {
    button.addEventListener('click', () => {
      $$('.mood-buttons button').forEach((item) => item.classList.toggle('active', item === button));
      $('#moodSelect').value = button.dataset.mood;
    });
  });
  $$('.breath-choice').forEach((button) => {
    button.addEventListener('click', () => {
      $$('.breath-choice').forEach((item) => item.classList.toggle('active', item === button));
      $('#breathPattern').value = button.dataset.pattern;
      setupBreathing();
    });
  });
  $$('.mode-btn').forEach((button) => {
    button.addEventListener('click', () => {
      $$('.mode-btn').forEach((item) => item.classList.toggle('active', item === button));
      const copy = {
        text: 'Text mode reads the entry and offers written prompts.',
        voice: 'Voice mode can use browser speech recognition for spoken reflections.',
        video: 'Video mode is prepared for a future face-to-face companion surface.',
        chat: 'Chat mode keeps a back-and-forth reflection thread beside your entry.'
      };
      $('#journalReflection').textContent = copy[button.dataset.sidebarMode];
    });
  });
  $$('[data-auth-mode]').forEach((button) => {
    button.addEventListener('click', () => {
      state.authMode = button.dataset.authMode;
      $$('[data-auth-mode]').forEach((b) => b.classList.toggle('active', b === button));
      syncAccountVisibility();
    });
  });
  $('#avatarGrid').addEventListener('click', (event) => {
    const button = event.target.closest('[data-avatar]');
    if (!button) return;
    state.avatar = button.dataset.avatar;
    renderAvatars();
  });
  $('#authForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const endpoint = state.authMode === 'guest' ? '/api/auth/guest' : '/api/auth/register';
    const body = state.authMode === 'guest'
      ? {}
      : {
          email: $('#email').value,
          password: $('#password').value,
          displayName: $('#displayName').value,
          avatar: state.avatar,
          paid: $('#paidTier').checked
        };
    const data = await api(endpoint, { method: 'POST', body });
    const updated = await api('/api/profile', {
      method: 'POST',
      body: {
        userId: data.user.id,
        displayName: $('#displayName').value || data.user.displayName,
        avatar: state.avatar,
        paid: $('#paidTier').checked
      }
    });
    saveUser(updated.user);
    showToast(`Welcome, ${updated.user.displayName}.`);
  });
  $('#chatForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const user = requireUser();
    const message = $('#chatInput').value.trim();
    if (!message) return;
    appendMessage($('#chatLog'), 'user', message);
    $('#chatInput').value = '';
    const data = await api('/api/chat', { method: 'POST', body: { userId: user.id, message } });
    if (data.crisis) return handleCrisis(data);
    appendMessage($('#chatLog'), 'ai', data.reply);
    refreshDashboard();
  });
  $('#voiceChatBtn').addEventListener('click', () => startSpeech($('#chatInput')));
  $('#voiceJournalBtn').addEventListener('click', () => startSpeech($('#journalEditor'), () => (state.voiceMemo = 'Browser speech memo captured.')));
  $('#journalForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const user = requireUser();
    const content = $('#journalEditor').textContent.trim();
    const image = $('#journalImage').files[0]?.name;
    const data = await api('/api/journal', {
      method: 'POST',
      body: {
        userId: user.id,
        content,
        mood: $('#moodSelect').value,
        attachments: image ? [{ type: 'image', name: image }] : [],
        voiceMemo: state.voiceMemo
      }
    });
    if (data.crisis) return handleCrisis(data);
    $('#journalEditor').textContent = '';
    showToast('Journal entry saved.');
    refreshDashboard();
  });
  $('#reflectBtn').addEventListener('click', async () => {
    const user = requireUser();
    const content = $('#journalEditor').textContent.trim();
    const data = await api('/api/journal/reflect', { method: 'POST', body: { userId: user.id, content } });
    if (data.crisis) return handleCrisis(data);
    $('#journalReflection').textContent = data.reply;
  });
  $('#sleepForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const user = requireUser();
    await api('/api/sleep', {
      method: 'POST',
      body: {
        userId: user.id,
        bedtime: $('#bedtime').value,
        wakeTime: $('#wakeTime').value,
        quality: $('#quality').value
      }
    });
    showToast('Sleep log saved.');
    refreshDashboard();
  });
  $('#sleepRange').addEventListener('change', () => renderSleepChart(state.dashboard?.sleeps || []));
  $('#communityForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const user = requireUser();
    const message = $('#communityInput').value.trim();
    if (!message) return;
    const data = await api('/api/community', {
      method: 'POST',
      body: { userId: user.id, room: $('#roomSelect').value, message }
    });
    if (data.crisis) return handleCrisis(data);
    $('#communityInput').value = '';
    refreshDashboard();
  });
  $('#roomSelect').addEventListener('change', () => renderCommunity(state.dashboard?.communityMessages || []));
  $('#breathPattern').addEventListener('change', setupBreathing);
  $('#refreshDashboard').addEventListener('click', refreshDashboard);
  $('#ackCrisis').addEventListener('change', () => {
    $('#continueAfterCrisis').disabled = !$('#ackCrisis').checked;
  });
  $('#continueAfterCrisis').addEventListener('click', () => {
    if ($('#ackCrisis').checked) $('#crisisOverlay').hidden = true;
  });
  $('#emergencySupportBtn').addEventListener('click', async () => {
    const data = await api('/api/crisis-support', {
      method: 'POST',
      body: { userId: state.user?.id, message: 'Emergency AI Support selected' }
    });
    $('#crisisSupportText').textContent = data.support;
  });
}

function initDefaults() {
  const now = new Date();
  const bedtime = new Date(now);
  bedtime.setHours(22, 30, 0, 0);
  const wake = new Date(now);
  wake.setDate(wake.getDate() + 1);
  wake.setHours(6, 30, 0, 0);
  $('#bedtime').value = bedtime.toISOString().slice(0, 16);
  $('#wakeTime').value = wake.toISOString().slice(0, 16);
  $('#chatLog').innerHTML = '';
  appendMessage($('#chatLog'), 'ai', 'Hello, I am here to listen and support you. This is a safe, judgment-free space. How are you feeling today?');
}

window.addEventListener('hashchange', () => {
  const id = location.hash.replace('#', '') || 'dashboard';
  if (id.startsWith('figma')) return;
  if ($(`#${id}`)) switchView(id);
});

renderAvatars();
bindEvents();
setupBreathing();
setupMeditations();
initDefaults();
updateProfileUI();
refreshDashboard().catch(() => {});
const requestedView = new URLSearchParams(location.search).get('view');
const hashView = location.hash.replace('#', '');
const initialView = requestedView || (hashView.startsWith('figma') ? 'dashboard' : hashView) || 'dashboard';
switchView(initialView, !requestedView);
