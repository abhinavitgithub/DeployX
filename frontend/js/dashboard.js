/**
 * DeployX Dashboard Controller (dashboard.js)
 * Coordinates UI state, safe DOM updates, automated polling,
 * and error/disconnect handling.
 */

(function () {
  'use strict';

  const POLL_INTERVAL_MS = 10000; // 10 seconds
  let pollTimer = null;
  let isFetching = false;
  let isAutoRefreshActive = true;

  // Cache DOM elements
  const elements = {
    // Header & Badges
    connectionBadge: document.getElementById('connection-badge'),
    connectionStatusText: document.getElementById('connection-status-text'),
    lastUpdatedText: document.getElementById('last-updated-text'),
    btnRefresh: document.getElementById('btn-refresh'),
    apiUrlInput: document.getElementById('api-url-input'),
    alertBanner: document.getElementById('alert-banner'),
    alertMessage: document.getElementById('alert-message'),
    btnToggleAuto: document.getElementById('btn-toggle-auto'),
    menuToggle: document.getElementById('menu-toggle'),
    sidebar: document.getElementById('sidebar'),

    // System Overview Cards
    valLiveness: document.getElementById('val-liveness'),
    metaLiveness: document.getElementById('meta-liveness'),
    valReadiness: document.getElementById('val-readiness'),
    metaReadiness: document.getElementById('meta-readiness'),
    valAppVersion: document.getElementById('val-app-version'),
    metaAppVersion: document.getElementById('meta-app-version'),
    valUptime: document.getElementById('val-uptime'),
    metaUptime: document.getElementById('meta-uptime'),

    // Performance Metrics Cards
    valTotalRequests: document.getElementById('val-total-requests'),
    valAvgLatency: document.getElementById('val-avg-latency'),
    valSuccessRate: document.getElementById('val-success-rate'),
    valErrorCount: document.getElementById('val-error-count'),

    // Endpoints Table Body
    tableEndpointsBody: document.getElementById('table-endpoints-body'),

    // Chart Containers
    chartEndpointsContainer: 'chart-endpoints-container',
    canvasEndpoints: 'canvas-endpoints',
    chartStatusContainer: 'chart-status-container',
    canvasStatus: 'canvas-status'
  };

  /**
   * Format seconds into human-readable duration
   */
  function formatUptime(seconds) {
    if (typeof seconds !== 'number' || seconds < 0) return '0s';
    const totalSecs = Math.floor(seconds);
    const days = Math.floor(totalSecs / 86400);
    const hours = Math.floor((totalSecs % 86400) / 3600);
    const minutes = Math.floor((totalSecs % 3600) / 60);
    const secs = totalSecs % 60;

    const parts = [];
    if (days > 0) parts.push(`${days}d`);
    if (hours > 0 || days > 0) parts.push(`${hours}h`);
    if (minutes > 0 || hours > 0 || days > 0) parts.push(`${minutes}m`);
    parts.push(`${secs}s`);

    return parts.join(' ');
  }

  /**
   * Set text content safely (Zero unsafe innerHTML)
   */
  function setText(el, text) {
    if (el) el.textContent = String(text ?? '');
  }

  /**
   * Update UI to Connected / Operational state
   */
  function renderOperationalState(telemetry) {
    const { live, ready, status, metrics } = telemetry.data;

    // 1. Connection Header Badge
    elements.connectionBadge.className = 'connection-badge connected';
    setText(elements.connectionStatusText, telemetry.isReady ? 'OPERATIONAL' : 'DEGRADED');
    elements.alertBanner.classList.remove('visible');

    // 2. Liveness Card
    const isAlive = live && live.status === 'alive';
    setText(elements.valLiveness, isAlive ? 'ALIVE' : 'OFFLINE');
    elements.valLiveness.className = `card-value ${isAlive ? 'alive' : 'disconnected'}`;
    setText(elements.metaLiveness, isAlive ? 'Process loop healthy' : 'Process unresponsive');

    // 3. Readiness Card
    const isReady = ready && ready.status === 'ready';
    setText(elements.valReadiness, isReady ? 'READY' : 'NOT READY');
    elements.valReadiness.className = `card-value ${isReady ? 'ready' : 'degraded'}`;
    setText(elements.metaReadiness, isReady ? 'Accepting production traffic' : 'Readiness check degraded');

    // 4. Version & Environment Card
    const appName = status?.app_name || metrics?.appInfo?.app_name || 'deployx-backend';
    const version = status?.version || metrics?.appInfo?.version || '1.0.0';
    const environment = status?.environment || metrics?.appInfo?.environment || 'development';
    setText(elements.valAppVersion, `v${version}`);
    setText(elements.metaAppVersion, `${appName} [${environment}]`);

    // 5. Uptime Card
    const uptimeSecs = typeof status?.uptime_seconds === 'number' ? status.uptime_seconds : (metrics?.uptimeSeconds || 0);
    setText(elements.valUptime, formatUptime(uptimeSecs));
    setText(elements.metaUptime, `Process status: ${status?.process_status || 'running'}`);

    // 6. Performance Telemetry Cards
    const totalRequests = metrics?.totalRequests || 0;
    setText(elements.valTotalRequests, totalRequests.toLocaleString());

    const avgLatency = metrics?.latencyMs || 0;
    setText(elements.valAvgLatency, avgLatency > 0 ? `${avgLatency} ms` : '< 1 ms');

    const statusDist = metrics?.statusDistribution || { '2xx': 0, '4xx': 0, '5xx': 0 };
    const successCount = statusDist['2xx'] || 0;
    const errorCount = (statusDist['4xx'] || 0) + (statusDist['5xx'] || 0);
    const successRate = totalRequests > 0 ? Math.round((successCount / totalRequests) * 100) : 100;
    setText(elements.valSuccessRate, `${successRate}%`);
    setText(elements.valErrorCount, `${errorCount} errors`);

    // 7. Render Charts
    DeployXCharts.renderEndpointChart(
      elements.chartEndpointsContainer,
      elements.canvasEndpoints,
      metrics?.requestsByEndpoint || []
    );

    DeployXCharts.renderStatusChart(
      elements.chartStatusContainer,
      elements.canvasStatus,
      statusDist
    );

    // 8. Render Endpoints Table safely
    renderEndpointsTable(metrics?.requestsByEndpoint || []);

    // 9. Last Updated Timestamp
    const now = new Date();
    setText(elements.lastUpdatedText, now.toLocaleTimeString());
  }

  /**
   * Render safe table rows for tracked endpoints
   */
  function renderEndpointsTable(endpoints) {
    const tbody = elements.tableEndpointsBody;
    if (!tbody) return;

    tbody.replaceChildren(); // Safe clear

    if (!endpoints || endpoints.length === 0) {
      const emptyRow = document.createElement('tr');
      const emptyCell = document.createElement('td');
      emptyCell.colSpan = 4;
      emptyCell.style.textAlign = 'center';
      emptyCell.style.color = '#64748b';
      emptyCell.style.padding = '24px';
      emptyCell.textContent = 'No endpoint traffic recorded yet. Issue HTTP requests to the backend to populate.';
      emptyRow.appendChild(emptyCell);
      tbody.appendChild(emptyRow);
      return;
    }

    // Sort descending by count
    const sorted = [...endpoints].sort((a, b) => b.count - a.count);

    for (const item of sorted) {
      const tr = document.createElement('tr');

      // Method Cell
      const tdMethod = document.createElement('td');
      const badgeMethod = document.createElement('span');
      badgeMethod.className = `method-badge ${item.method}`;
      badgeMethod.textContent = item.method;
      tdMethod.appendChild(badgeMethod);

      // Endpoint Cell
      const tdEndpoint = document.createElement('td');
      tdEndpoint.className = 'endpoint-cell';
      tdEndpoint.textContent = item.handler;

      // Status Code Cell
      const tdStatus = document.createElement('td');
      const pillStatus = document.createElement('span');
      const sc = parseInt(item.status, 10);
      let statusClass = 'status-2xx';
      if (sc >= 500) statusClass = 'status-5xx';
      else if (sc >= 400) statusClass = 'status-4xx';

      pillStatus.className = `status-pill ${statusClass}`;
      pillStatus.textContent = `${item.status} OK`;
      if (sc >= 400) pillStatus.textContent = item.status;
      tdStatus.appendChild(pillStatus);

      // Count Cell
      const tdCount = document.createElement('td');
      tdCount.style.fontFamily = 'var(--font-mono)';
      tdCount.textContent = item.count.toLocaleString();

      tr.appendChild(tdMethod);
      tr.appendChild(tdEndpoint);
      tr.appendChild(tdStatus);
      tr.appendChild(tdCount);

      tbody.appendChild(tr);
    }
  }

  /**
   * Update UI to Disconnected / Error state
   */
  function renderDisconnectedState(errorMsg) {
    elements.connectionBadge.className = 'connection-badge disconnected';
    setText(elements.connectionStatusText, 'DISCONNECTED');

    // Show alert banner
    elements.alertBanner.classList.add('visible');
    setText(
      elements.alertMessage,
      `Backend unreachable at ${DeployXAPI.getBaseUrl()}. Error: ${errorMsg || 'Connection refused / network timeout'}`
    );

    // Update system cards to disconnected values
    setText(elements.valLiveness, 'OFFLINE');
    elements.valLiveness.className = 'card-value disconnected';
    setText(elements.metaLiveness, 'Connection to server failed');

    setText(elements.valReadiness, 'UNAVAILABLE');
    elements.valReadiness.className = 'card-value disconnected';
    setText(elements.metaReadiness, 'Readiness check offline');

    setText(elements.metaAppVersion, 'Backend offline');
    setText(elements.metaUptime, 'Telemetry suspended');
  }

  /**
   * Main poll / refresh routine
   */
  async function refreshTelemetry() {
    if (isFetching) return;
    isFetching = true;

    // Animate refresh button
    if (elements.btnRefresh) {
      elements.btnRefresh.classList.add('spinning');
    }

    try {
      const telemetry = await DeployXAPI.fetchAllTelemetry();
      if (telemetry.success) {
        renderOperationalState(telemetry);
      } else {
        const errorDetail = telemetry.data?.errors?.join(', ') || 'Failed to reach backend';
        renderDisconnectedState(errorDetail);
      }
    } catch (err) {
      renderDisconnectedState(err.message);
    } finally {
      isFetching = false;
      if (elements.btnRefresh) {
        elements.btnRefresh.classList.remove('spinning');
      }
    }
  }

  /**
   * Setup polling timer
   */
  function startPolling() {
    stopPolling();
    if (isAutoRefreshActive) {
      pollTimer = setInterval(refreshTelemetry, POLL_INTERVAL_MS);
    }
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  /**
   * Attach UI Event Listeners
   */
  function setupEventListeners() {
    // Manual Refresh button
    if (elements.btnRefresh) {
      elements.btnRefresh.addEventListener('click', () => {
        refreshTelemetry();
      });
    }

    // Toggle Auto Refresh
    if (elements.btnToggleAuto) {
      elements.btnToggleAuto.addEventListener('click', () => {
        isAutoRefreshActive = !isAutoRefreshActive;
        if (isAutoRefreshActive) {
          setText(elements.btnToggleAuto, 'Auto-refresh: 10s');
          elements.btnToggleAuto.classList.remove('btn-secondary');
          elements.btnToggleAuto.classList.add('btn-primary');
          startPolling();
        } else {
          setText(elements.btnToggleAuto, 'Auto-refresh: Paused');
          elements.btnToggleAuto.classList.remove('btn-primary');
          elements.btnToggleAuto.classList.add('btn-secondary');
          stopPolling();
        }
      });
    }

    // API URL Input change
    if (elements.apiUrlInput) {
      elements.apiUrlInput.value = DeployXAPI.getBaseUrl() || (typeof window !== 'undefined' && window.location.origin ? window.location.origin : '');
      elements.apiUrlInput.addEventListener('change', (e) => {
        const newUrl = e.target.value.trim();
        if (newUrl) {
          DeployXAPI.setBaseUrl(newUrl);
          refreshTelemetry();
        }
      });
      elements.apiUrlInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
          e.target.blur();
        }
      });
    }

    // Mobile sidebar toggle
    if (elements.menuToggle && elements.sidebar) {
      elements.menuToggle.addEventListener('click', () => {
        elements.sidebar.classList.toggle('open');
      });
    }
  }

  /**
   * Setup active sidebar navigation tracking via IntersectionObserver,
   * URL hash routing, and smooth click scrolling.
   */
  function setupSidebarNavigation() {
    const navLinks = Array.from(document.querySelectorAll('.sidebar-nav a[href^="#"]'));
    if (navLinks.length === 0) return;

    const sectionIds = ['overview', 'metrics-section', 'deployment-section', 'kubernetes-section', 'dr-section'];
    const sections = sectionIds
      .map(id => document.getElementById(id))
      .filter(Boolean);

    let isManualScrolling = false;
    let manualScrollTimer = null;

    function setActiveNavItem(targetId) {
      if (!targetId) return;
      const cleanId = targetId.replace(/^#/, '');

      navLinks.forEach(link => {
        const href = link.getAttribute('href');
        if (href === `#${cleanId}`) {
          link.classList.add('active');
        } else {
          link.classList.remove('active');
        }
      });
    }

    // Release manual scroll lock immediately on manual user gestures (wheel, touch)
    function releaseManualScroll() {
      if (isManualScrolling) {
        isManualScrolling = false;
        if (manualScrollTimer) clearTimeout(manualScrollTimer);
      }
    }

    window.addEventListener('wheel', releaseManualScroll, { passive: true });
    window.addEventListener('touchmove', releaseManualScroll, { passive: true });

    // 1. Handle Click on Nav Items
    navLinks.forEach(link => {
      link.addEventListener('click', (e) => {
        const href = link.getAttribute('href');
        if (!href || !href.startsWith('#')) return;

        e.preventDefault();
        const targetId = href.substring(1);
        const targetSection = document.getElementById(targetId);

        if (targetSection) {
          isManualScrolling = true;
          if (manualScrollTimer) clearTimeout(manualScrollTimer);

          // Immediately update active sidebar item
          setActiveNavItem(targetId);

          // Smooth scroll to section
          targetSection.scrollIntoView({ behavior: 'smooth' });

          // Update URL hash without causing full page jump
          if (window.history && window.history.pushState) {
            window.history.pushState(null, '', `#${targetId}`);
          } else {
            window.location.hash = targetId;
          }

          // Close mobile sidebar drawer if open
          if (elements.sidebar && elements.sidebar.classList.contains('open')) {
            elements.sidebar.classList.remove('open');
          }

          // Release manual scroll lock after scroll animation finishes
          manualScrollTimer = setTimeout(() => {
            isManualScrolling = false;
          }, 800);
        }
      });
    });

    // 2. Setup IntersectionObserver for visible section tracking
    if ('IntersectionObserver' in window && sections.length > 0) {
      const observerOptions = {
        root: null, // viewport
        rootMargin: '-80px 0px -40% 0px', // offset for 70px sticky header + top half trigger
        threshold: [0, 0.1, 0.25, 0.5, 0.75]
      };

      const visibleSections = new Map();

      const observer = new IntersectionObserver((entries) => {
        if (isManualScrolling) return;

        // Check if user has scrolled to the bottom of the page
        const isAtBottom = (window.innerHeight + window.scrollY) >= (document.documentElement.scrollHeight - 60);
        if (isAtBottom && sections.length > 0) {
          setActiveNavItem(sections[sections.length - 1].id);
          return;
        }

        entries.forEach(entry => {
          if (entry.isIntersecting) {
            visibleSections.set(entry.target.id, entry);
          } else {
            visibleSections.delete(entry.target.id);
          }
        });

        if (visibleSections.size > 0) {
          let bestId = null;
          let bestTop = Infinity;

          visibleSections.forEach((entry, id) => {
            const rect = entry.boundingClientRect;
            if (rect.bottom > 80) {
              if (rect.top <= 120) {
                bestId = id;
              } else if (rect.top < bestTop && !bestId) {
                bestTop = rect.top;
                bestId = id;
              }
            }
          });

          if (bestId) {
            setActiveNavItem(bestId);
          }
        }
      }, observerOptions);

      sections.forEach(sec => observer.observe(sec));
    }

    // 3. Support Browser Back/Forward & Direct Hash Navigation
    function handleHashNav() {
      const hash = window.location.hash;
      if (hash) {
        const targetId = hash.substring(1);
        const targetSection = document.getElementById(targetId);
        if (targetSection) {
          setActiveNavItem(targetId);
          targetSection.scrollIntoView({ behavior: 'smooth' });
          return;
        }
      }
      setActiveNavItem('overview');
    }

    window.addEventListener('popstate', handleHashNav);
    window.addEventListener('hashchange', handleHashNav);

    // Initial check on load
    if (window.location.hash) {
      const initialId = window.location.hash.substring(1);
      const initialSec = document.getElementById(initialId);
      if (initialSec) {
        setActiveNavItem(initialId);
        setTimeout(() => {
          initialSec.scrollIntoView({ behavior: 'auto' });
        }, 50);
      } else {
        setActiveNavItem('overview');
      }
    } else {
      setActiveNavItem('overview');
    }
  }

  /**
   * Application Initialization
   */
  function init() {
    setupEventListeners();
    setupSidebarNavigation();
    refreshTelemetry();
    startPolling();
  }

  // Bootstrap when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
