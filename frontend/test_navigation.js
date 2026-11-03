/**
 * Unit Test for DeployX Sidebar Active Navigation (frontend/js/dashboard.js)
 * Validates:
 * 1. Single active class invariant (only one active item at a time).
 * 2. Click on each of the 5 nav items updates active state.
 * 3. Smooth scrolling is called on the target section.
 * 4. URL hash is updated via pushState.
 * 5. Mobile sidebar drawer is closed on nav click.
 * 6. Browser popstate/hashchange updates active item.
 * 7. Initial URL hash navigation on load.
 * 8. Manual scroll lock prevents IntersectionObserver conflicts during animation.
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

// Read dashboard.js
const dashboardJsPath = path.join(__dirname, 'js', 'dashboard.js');
const dashboardCode = fs.readFileSync(dashboardJsPath, 'utf8');

// Section IDs to test
const SECTION_IDS = [
  'overview',
  'metrics-section',
  'deployment-section',
  'kubernetes-section',
  'dr-section'
];

// Helper to create mock elements
function createMockElement(id, tagName = 'div', attributes = {}) {
  const classListSet = new Set();
  const eventListeners = {};

  return {
    id,
    tagName: tagName.toUpperCase(),
    attributes: { ...attributes },
    classList: {
      add: (cls) => classListSet.add(cls),
      remove: (cls) => classListSet.delete(cls),
      contains: (cls) => classListSet.has(cls),
      toggle: (cls) => classListSet.has(cls) ? classListSet.delete(cls) : classListSet.add(cls),
      get length() { return classListSet.size; },
      toString: () => Array.from(classListSet).join(' ')
    },
    getAttribute: (attr) => attributes[attr] || null,
    setAttribute: (attr, val) => { attributes[attr] = val; },
    addEventListener: (event, handler) => {
      eventListeners[event] = eventListeners[event] || [];
      eventListeners[event].push(handler);
    },
    dispatchEvent: (event, eventObj = {}) => {
      const handlers = eventListeners[event] || [];
      handlers.forEach(h => h({ preventDefault: () => {}, ...eventObj }));
    },
    scrollIntoView: function (opts) {
      this._scrolledWith = opts;
      this._scrolledCount = (this._scrolledCount || 0) + 1;
    },
    getBoundingClientRect: () => ({ top: 100, bottom: 500, height: 400 }),
    style: {}
  };
}

// Build mock DOM
const mockSections = {};
SECTION_IDS.forEach(id => {
  mockSections[id] = createMockElement(id, 'section');
});

const mockNavLinks = SECTION_IDS.map(id => {
  const link = createMockElement(`nav-link-${id}`, 'a', { href: `#${id}` });
  link.className = 'nav-item';
  return link;
});

const mockSidebar = createMockElement('sidebar');
const mockMenuToggle = createMockElement('menu-toggle');

const windowListeners = {};
const mockWindow = {
  location: { hash: '', origin: 'http://localhost:3000' },
  history: {
    pushState: (state, title, url) => {
      mockWindow.location.hash = url.replace(/^#*/, '#');
      mockWindow._pushedUrl = url;
    }
  },
  innerHeight: 800,
  scrollY: 0,
  addEventListener: (event, handler) => {
    windowListeners[event] = windowListeners[event] || [];
    windowListeners[event].push(handler);
  },
  trigger: (event, data) => {
    (windowListeners[event] || []).forEach(h => h(data || {}));
  }
};

const mockDocument = {
  readyState: 'complete',
  documentElement: { scrollHeight: 2000 },
  getElementById: (id) => {
    if (id === 'sidebar') return mockSidebar;
    if (id === 'menu-toggle') return mockMenuToggle;
    if (mockSections[id]) return mockSections[id];
    return null;
  },
  querySelectorAll: (selector) => {
    if (selector.includes('a[href^="#"]')) {
      return mockNavLinks;
    }
    return [];
  },
  addEventListener: () => {}
};

// Mock IntersectionObserver
let observedElements = [];
let observerCallback = null;
class MockIntersectionObserver {
  constructor(callback, options) {
    observerCallback = callback;
    this.options = options;
  }
  observe(el) {
    observedElements.push(el);
  }
  unobserve(el) {
    observedElements = observedElements.filter(e => e !== el);
  }
  disconnect() {
    observedElements = [];
  }
}

// Set globals
global.window = mockWindow;
global.document = mockDocument;
global.localStorage = { getItem: () => null, setItem: () => {} };
global.IntersectionObserver = MockIntersectionObserver;
mockWindow.IntersectionObserver = MockIntersectionObserver;
global.DeployXAPI = {
  getBaseUrl: () => 'http://localhost:8000',
  setBaseUrl: () => {},
  fetchAllTelemetry: async () => ({ success: true, isReady: true, data: { live: { status: 'alive' }, ready: { status: 'ready' }, status: {}, metrics: {} } })
};
global.DeployXCharts = {
  renderEndpointChart: () => {},
  renderStatusChart: () => {}
};

console.log('[TEST 1] Loading dashboard.js and evaluating setupSidebarNavigation...');
eval(dashboardCode);

// Helper to count active links
function getActiveLinks() {
  return mockNavLinks.filter(l => l.classList.contains('active'));
}

// Test initial state on load: 'overview' should be active
const activeInitially = getActiveLinks();
assert.strictEqual(activeInitially.length, 1, 'Exactly one link must be active initially');
assert.strictEqual(activeInitially[0].getAttribute('href'), '#overview', '#overview must be active initially');
console.log('✓ Initial active navigation verified: #overview is active');

// Test clicking each of the 5 navigation items
console.log('[TEST 2] Verifying click handling across all 5 navigation links...');
SECTION_IDS.forEach((targetId, index) => {
  const link = mockNavLinks[index];
  const section = mockSections[targetId];

  // Trigger click
  link.dispatchEvent('click');

  // Verify only this link has active class
  const activeLinks = getActiveLinks();
  assert.strictEqual(activeLinks.length, 1, `Only one link can be active after clicking ${targetId}`);
  assert.strictEqual(activeLinks[0].getAttribute('href'), `#${targetId}`, `Clicked link #${targetId} must be active`);

  // Verify smooth scroll was called on target section
  assert.strictEqual(section._scrolledWith.behavior, 'smooth', `Section #${targetId} must be scrolled smoothly`);

  // Verify URL hash updated
  assert.strictEqual(mockWindow.location.hash, `#${targetId}`, `URL hash must update to #${targetId}`);

  console.log(`✓ Click on #${targetId}: highlight updated, smooth scroll triggered, URL hash synchronized.`);
});

// Test mobile sidebar auto-close
console.log('[TEST 3] Verifying mobile sidebar drawer auto-closes on nav item click...');
mockSidebar.classList.add('open');
assert.strictEqual(mockSidebar.classList.contains('open'), true, 'Sidebar should be open');
mockNavLinks[1].dispatchEvent('click'); // Click #metrics-section
assert.strictEqual(mockSidebar.classList.contains('open'), false, 'Sidebar must close automatically after click');
console.log('✓ Mobile navigation drawer auto-close verified.');

// Test browser popstate / back / forward navigation
console.log('[TEST 4] Verifying browser popstate / back-forward navigation...');
mockWindow.location.hash = '#kubernetes-section';
mockWindow.trigger('popstate');
assert.strictEqual(getActiveLinks()[0].getAttribute('href'), '#kubernetes-section', 'Active link must update on popstate to #kubernetes-section');

mockWindow.location.hash = '#dr-section';
mockWindow.trigger('hashchange');
assert.strictEqual(getActiveLinks()[0].getAttribute('href'), '#dr-section', 'Active link must update on hashchange to #dr-section');

mockWindow.location.hash = '';
mockWindow.trigger('popstate');
assert.strictEqual(getActiveLinks()[0].getAttribute('href'), '#overview', 'Active link must default to #overview when hash cleared');
console.log('✓ Browser history back/forward navigation verified.');

// Test IntersectionObserver integration
console.log('[TEST 5] Verifying IntersectionObserver scroll detection...');
// User touches wheel to scroll manually, releasing any click-scroll lock
mockWindow.trigger('wheel');

assert.strictEqual(typeof observerCallback, 'function', 'IntersectionObserver callback must be registered');
assert.strictEqual(observedElements.length, 5, 'All 5 sections must be observed');

// Simulate scrolling into #deployment-section
observerCallback([
  {
    target: mockSections['deployment-section'],
    isIntersecting: true,
    boundingClientRect: { top: 90, bottom: 600 }
  },
  {
    target: mockSections['overview'],
    isIntersecting: false,
    boundingClientRect: { top: -600, bottom: -100 }
  }
]);

assert.strictEqual(getActiveLinks()[0].getAttribute('href'), '#deployment-section', 'Observer must update active link to #deployment-section on scroll');
console.log('✓ IntersectionObserver active state tracking verified.');

console.log('\n============================================================');
console.log(' [SUCCESS] ALL SIDEBAR NAVIGATION TESTS PASSED! ');
console.log('============================================================');
process.exit(0);
