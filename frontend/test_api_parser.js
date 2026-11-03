/**
 * Unit Test for DeployX Prometheus Parser (api.js)
 * Executes via Node.js to verify mathematical parsing of Prometheus metrics.
 */

const assert = require('assert');

// Mock browser globals needed by api.js
global.window = {
  location: { port: '3000', origin: 'http://localhost:3000' }
};
global.localStorage = {
  getItem: () => null,
  setItem: () => {}
};

// Load api.js module directly
const DeployXAPI = require('./js/api.js');

console.log('[TEST] DeployXAPI loaded successfully via require');

// Sample real Prometheus payload from DeployX backend
const samplePrometheusText = `
# HELP deployx_http_requests_total Total number of HTTP requests handled by the DeployX backend
# TYPE deployx_http_requests_total counter
deployx_http_requests_total{handler="/health/live",method="GET",status="200"} 4.0
deployx_http_requests_total{handler="/",method="GET",status="200"} 2.0
deployx_http_requests_total{handler="/api/v1/status",method="GET",status="200"} 3.0
deployx_http_requests_total{handler="/test/error",method="GET",status="500"} 1.0

# HELP deployx_http_request_duration_seconds HTTP request latency in seconds
# TYPE deployx_http_request_duration_seconds histogram
deployx_http_request_duration_seconds_bucket{handler="/health/live",le="0.005",method="GET",status="200"} 4.0
deployx_http_request_duration_seconds_bucket{handler="/health/live",le="0.01",method="GET",status="200"} 4.0
deployx_http_request_duration_seconds_bucket{handler="/health/live",le="+Inf",method="GET",status="200"} 4.0
deployx_http_request_duration_seconds_count{handler="/health/live",method="GET",status="200"} 4.0
deployx_http_request_duration_seconds_sum{handler="/health/live",method="GET",status="200"} 0.008

deployx_http_request_duration_seconds_count{handler="/",method="GET",status="200"} 2.0
deployx_http_request_duration_seconds_sum{handler="/",method="GET",status="200"} 0.004

deployx_http_request_duration_seconds_count{handler="/api/v1/status",method="GET",status="200"} 3.0
deployx_http_request_duration_seconds_sum{handler="/api/v1/status",method="GET",status="200"} 0.006

# HELP deployx_application_uptime_seconds Application uptime in seconds since process initialization
# TYPE deployx_application_uptime_seconds gauge
deployx_application_uptime_seconds 45.67

# HELP deployx_application_info DeployX application version and metadata
# TYPE deployx_application_info gauge
deployx_application_info{app_name="deployx-backend",environment="development",version="1.0.0"} 1.0
`;

const parsed = DeployXAPI.parsePrometheusText(samplePrometheusText);

console.log('Parsed Metrics Result:', JSON.stringify(parsed, null, 2));

// 1. Validate Total Requests
assert.strictEqual(parsed.totalRequests, 10, 'Total requests must equal 4 + 2 + 3 + 1 = 10');

// 2. Validate Status Distribution
assert.strictEqual(parsed.statusDistribution['2xx'], 9, '2xx requests must equal 4 + 2 + 3 = 9');
assert.strictEqual(parsed.statusDistribution['5xx'], 1, '5xx requests must equal 1');
assert.strictEqual(parsed.statusDistribution['4xx'], 0, '4xx requests must equal 0');

// 3. Validate Latency Calculation (durationSum / durationCount * 1000)
// durationSum = 0.008 + 0.004 + 0.006 = 0.018
// durationCount = 4 + 2 + 3 = 9
// avgLatency = (0.018 / 9) * 1000 = 2.0 ms
assert.strictEqual(parsed.latencyMs, 2.0, 'Average latency must be exactly 2.0 ms');

// 4. Validate Uptime
assert.strictEqual(parsed.uptimeSeconds, 45.67, 'Uptime must equal 45.67');

// 5. Validate Application Metadata
assert.strictEqual(parsed.appInfo.app_name, 'deployx-backend');
assert.strictEqual(parsed.appInfo.version, '1.0.0');
assert.strictEqual(parsed.appInfo.environment, 'development');

// 6. Validate Endpoint Breakdown Array
assert.strictEqual(parsed.requestsByEndpoint.length, 4, 'Should contain 4 distinct endpoints');

console.log('[SUCCESS] All Prometheus parser assertions passed!');
