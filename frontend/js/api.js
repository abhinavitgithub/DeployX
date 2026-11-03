/**
 * DeployX API Client & Prometheus Exposition Parser
 * Centralizes all communication with the FastAPI backend.
 */

const DeployXAPI = (function () {
  'use strict';

  // Configurable base URL with persistence
  const STORAGE_KEY = 'deployx_api_base_url';
  const DEFAULT_TIMEOUT_MS = 6000;

  function getDefaultBaseUrl() {
    // If the dashboard is hosted on port 8000 alongside the backend, use origin
    if (window.location.port === '8000') {
      return window.location.origin;
    }
    // Default to standard local FastAPI backend port
    return 'http://localhost:8000';
  }

  let baseUrl = localStorage.getItem(STORAGE_KEY) || getDefaultBaseUrl();

  function getBaseUrl() {
    return baseUrl;
  }

  function setBaseUrl(url) {
    if (!url || typeof url !== 'string') return;
    baseUrl = url.replace(/\/+$/, ''); // Strip trailing slash
    localStorage.setItem(STORAGE_KEY, baseUrl);
  }

  /**
   * Safe fetch with timeout and error handling
   */
  async function fetchWithTimeout(endpoint, options = {}) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), options.timeoutMs || DEFAULT_TIMEOUT_MS);

    const fullUrl = `${baseUrl}${endpoint}`;

    try {
      const response = await fetch(fullUrl, {
        ...options,
        signal: controller.signal,
        headers: {
          'Accept': endpoint === '/metrics' ? 'text/plain' : 'application/json',
          ...(options.headers || {})
        }
      });
      clearTimeout(timeoutId);

      if (!response.ok && endpoint !== '/health/ready') {
        // Special case: /health/ready returns 503 when degraded, which is still valid health data
        throw new Error(`HTTP ${response.status} from ${endpoint}`);
      }

      return response;
    } catch (err) {
      clearTimeout(timeoutId);
      if (err.name === 'AbortError') {
        throw new Error(`Request timed out after ${options.timeoutMs || DEFAULT_TIMEOUT_MS}ms for ${endpoint}`);
      }
      throw err;
    }
  }

  /**
   * Parse Prometheus exposition text format safely
   */
  function parsePrometheusText(text) {
    if (!text || typeof text !== 'string') {
      return {
        totalRequests: 0,
        requestsByEndpoint: [],
        statusDistribution: { '2xx': 0, '4xx': 0, '5xx': 0, 'other': 0 },
        latencyMs: 0,
        uptimeSeconds: 0,
        appInfo: {}
      };
    }

    const lines = text.split('\n');
    const endpointMap = new Map();
    let totalRequests = 0;
    const statusCounts = { '2xx': 0, '4xx': 0, '5xx': 0, 'other': 0 };
    let durationSum = 0;
    let durationCount = 0;
    let uptimeSeconds = 0;
    let appInfo = {};

    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (!line || line.startsWith('#')) continue;

      // Match metric name, optional labels {...}, and numeric value
      const match = line.match(/^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]+)\})?\s+([^\s]+)/);
      if (!match) continue;

      const [, metricName, rawLabels, rawValue] = match;
      const numValue = parseFloat(rawValue);
      if (isNaN(numValue)) continue;

      // Parse labels into key-value map
      const labels = {};
      if (rawLabels) {
        const labelRegex = /([a-zA-Z_][a-zA-Z0-9_]*)=["']([^"']*)["']/g;
        let lMatch;
        while ((lMatch = labelRegex.exec(rawLabels)) !== null) {
          labels[lMatch[1]] = lMatch[2];
        }
      }

      // Process DeployX metrics
      if (metricName === 'deployx_http_requests_total') {
        totalRequests += numValue;
        const handler = labels.handler || 'unknown';
        const method = labels.method || 'GET';
        const status = labels.status || '200';
        const key = `${method}:${handler}:${status}`;

        endpointMap.set(key, {
          method,
          handler,
          status,
          count: numValue
        });

        // Tally status code distribution
        const statusCode = parseInt(status, 10);
        if (statusCode >= 200 && statusCode < 300) {
          statusCounts['2xx'] += numValue;
        } else if (statusCode >= 400 && statusCode < 500) {
          statusCounts['4xx'] += numValue;
        } else if (statusCode >= 500 && statusCode < 600) {
          statusCounts['5xx'] += numValue;
        } else {
          statusCounts['other'] += numValue;
        }
      } else if (metricName === 'deployx_http_request_duration_seconds_sum') {
        durationSum += numValue;
      } else if (metricName === 'deployx_http_request_duration_seconds_count') {
        durationCount += numValue;
      } else if (metricName === 'deployx_application_uptime_seconds') {
        uptimeSeconds = numValue;
      } else if (metricName === 'deployx_application_info') {
        appInfo = { ...labels };
      }
    }

    // Calculate actual average latency across requests
    const avgLatencyMs = durationCount > 0 ? (durationSum / durationCount) * 1000 : 0;

    return {
      totalRequests,
      requestsByEndpoint: Array.from(endpointMap.values()),
      statusDistribution: statusCounts,
      latencyMs: Math.round(avgLatencyMs * 100) / 100,
      uptimeSeconds,
      appInfo
    };
  }

  /**
   * Fetch all system telemetry concurrently
   */
  async function fetchAllTelemetry() {
    const results = await Promise.allSettled([
      fetchWithTimeout('/health/live'),
      fetchWithTimeout('/health/ready'),
      fetchWithTimeout('/api/v1/status'),
      fetchWithTimeout('/metrics')
    ]);

    const [liveRes, readyRes, statusRes, metricsRes] = results;

    const data = {
      live: null,
      ready: null,
      status: null,
      metrics: null,
      errors: []
    };

    if (liveRes.status === 'fulfilled') {
      data.live = await liveRes.value.json();
    } else {
      data.errors.push(`Liveness probe: ${liveRes.reason.message}`);
    }

    if (readyRes.status === 'fulfilled') {
      data.ready = await readyRes.value.json();
    } else {
      data.errors.push(`Readiness probe: ${readyRes.reason.message}`);
    }

    if (statusRes.status === 'fulfilled') {
      data.status = await statusRes.value.json();
    } else {
      data.errors.push(`System status: ${statusRes.reason.message}`);
    }

    if (metricsRes.status === 'fulfilled') {
      const rawText = await metricsRes.value.text();
      data.metrics = parsePrometheusText(rawText);
    } else {
      data.errors.push(`Prometheus metrics: ${metricsRes.reason.message}`);
    }

    // Determine overall connection state
    const isOnline = Boolean(data.live && data.status);
    const isReady = data.ready ? data.ready.status === 'ready' : false;

    return {
      success: isOnline,
      isOnline,
      isReady,
      data,
      timestamp: new Date()
    };
  }

  return {
    getBaseUrl,
    setBaseUrl,
    fetchAllTelemetry,
    parsePrometheusText
  };
})();

// Support browser global and module exports
if (typeof window !== 'undefined') {
  window.DeployXAPI = DeployXAPI;
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = DeployXAPI;
}
