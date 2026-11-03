/**
 * DeployX Telemetry Visualizer (charts.js)
 * Supports Chart.js canvas rendering with automatic graceful fallback
 * to pure semantic CSS bar elements for offline / air-gapped environments.
 */

const DeployXCharts = (function () {
  'use strict';

  let endpointChartInstance = null;
  let statusChartInstance = null;

  /**
   * Render or update Endpoint Request Distribution
   */
  function renderEndpointChart(containerId, canvasId, endpointData) {
    const container = document.getElementById(containerId);
    const canvas = document.getElementById(canvasId);
    if (!container) return;

    if (!endpointData || endpointData.length === 0) {
      renderEmptyState(container, 'No HTTP traffic recorded yet');
      return;
    }

    // Sort by count descending, top 8
    const sorted = [...endpointData].sort((a, b) => b.count - a.count).slice(0, 8);
    const labels = sorted.map(e => `${e.method} ${e.handler}`);
    const dataValues = sorted.map(e => e.count);

    // If Chart.js is loaded, use canvas
    if (typeof window.Chart === 'function' && canvas) {
      canvas.style.display = 'block';
      const existingFallback = container.querySelector('.fallback-bars-container');
      if (existingFallback) existingFallback.remove();

      if (endpointChartInstance) {
        endpointChartInstance.data.labels = labels;
        endpointChartInstance.data.datasets[0].data = dataValues;
        endpointChartInstance.update('none');
      } else {
        const ctx = canvas.getContext('2d');
        endpointChartInstance = new window.Chart(ctx, {
          type: 'bar',
          data: {
            labels: labels,
            datasets: [{
              label: 'Request Count',
              data: dataValues,
              backgroundColor: '#38bdf8',
              borderRadius: 4
            }]
          },
          options: {
            indexAxis: 'y',
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
              legend: { display: false }
            },
            scales: {
              x: {
                grid: { color: 'rgba(255, 255, 255, 0.05)' },
                ticks: { color: '#94a3b8', font: { family: 'inherit', size: 11 } }
              },
              y: {
                grid: { display: false },
                ticks: { color: '#f8fafc', font: { family: 'inherit', size: 11 } }
              }
            }
          }
        });
      }
      return;
    }

    // Pure CSS/DOM fallback when Chart.js is not loaded
    if (canvas) canvas.style.display = 'none';
    renderFallbackBarChart(container, sorted);
  }

  /**
   * Render or update HTTP Status Distribution
   */
  function renderStatusChart(containerId, canvasId, statusDistribution) {
    const container = document.getElementById(containerId);
    const canvas = document.getElementById(canvasId);
    if (!container) return;

    const counts = [
      statusDistribution['2xx'] || 0,
      statusDistribution['4xx'] || 0,
      statusDistribution['5xx'] || 0
    ];
    const total = counts.reduce((a, b) => a + b, 0);

    if (total === 0) {
      renderEmptyState(container, 'No status telemetry available');
      return;
    }

    const labels = ['2xx Success', '4xx Client Err', '5xx Server Err'];
    const colors = ['#10b981', '#f59e0b', '#ef4444'];

    if (typeof window.Chart === 'function' && canvas) {
      canvas.style.display = 'block';
      const existingFallback = container.querySelector('.fallback-bars-container');
      if (existingFallback) existingFallback.remove();

      if (statusChartInstance) {
        statusChartInstance.data.datasets[0].data = counts;
        statusChartInstance.update('none');
      } else {
        const ctx = canvas.getContext('2d');
        statusChartInstance = new window.Chart(ctx, {
          type: 'doughnut',
          data: {
            labels: labels,
            datasets: [{
              data: counts,
              backgroundColor: colors,
              borderColor: '#151f32',
              borderWidth: 2
            }]
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
              legend: {
                position: 'bottom',
                labels: { color: '#94a3b8', font: { family: 'inherit', size: 11 } }
              }
            },
            cutout: '65%'
          }
        });
      }
      return;
    }

    // Pure DOM Fallback
    if (canvas) canvas.style.display = 'none';
    renderFallbackStatusBars(container, statusDistribution, total);
  }

  /**
   * Safe DOM rendering of pure CSS horizontal bars (Fallback mode)
   */
  function renderFallbackBarChart(container, sortedData) {
    let barContainer = container.querySelector('.fallback-bars-container');
    if (!barContainer) {
      barContainer = document.createElement('div');
      barContainer.className = 'fallback-bars-container';
      container.appendChild(barContainer);
    }
    barContainer.replaceChildren(); // Safe clear

    const maxVal = Math.max(...sortedData.map(d => d.count), 1);

    for (const item of sortedData) {
      const row = document.createElement('div');
      row.className = 'bar-row';

      const labelsDiv = document.createElement('div');
      labelsDiv.className = 'bar-labels';

      const nameSpan = document.createElement('span');
      nameSpan.textContent = `${item.method} ${item.handler}`;

      const countSpan = document.createElement('span');
      countSpan.textContent = `${item.count} req`;

      labelsDiv.appendChild(nameSpan);
      labelsDiv.appendChild(countSpan);

      const track = document.createElement('div');
      track.className = 'bar-track';

      const fill = document.createElement('div');
      fill.className = 'bar-fill blue';
      const pct = Math.round((item.count / maxVal) * 100);
      fill.style.width = `${pct}%`;

      track.appendChild(fill);
      row.appendChild(labelsDiv);
      row.appendChild(track);
      barContainer.appendChild(row);
    }
  }

  function renderFallbackStatusBars(container, statusDistribution, total) {
    let barContainer = container.querySelector('.fallback-bars-container');
    if (!barContainer) {
      barContainer = document.createElement('div');
      barContainer.className = 'fallback-bars-container';
      container.appendChild(barContainer);
    }
    barContainer.replaceChildren();

    const statuses = [
      { key: '2xx', label: '2xx Success', colorClass: 'green', count: statusDistribution['2xx'] || 0 },
      { key: '4xx', label: '4xx Client Err', colorClass: 'amber', count: statusDistribution['4xx'] || 0 },
      { key: '5xx', label: '5xx Server Err', colorClass: 'rose', count: statusDistribution['5xx'] || 0 }
    ];

    for (const stat of statuses) {
      const row = document.createElement('div');
      row.className = 'bar-row';

      const labelsDiv = document.createElement('div');
      labelsDiv.className = 'bar-labels';

      const nameSpan = document.createElement('span');
      nameSpan.textContent = stat.label;

      const pct = total > 0 ? Math.round((stat.count / total) * 100) : 0;
      const countSpan = document.createElement('span');
      countSpan.textContent = `${stat.count} (${pct}%)`;

      labelsDiv.appendChild(nameSpan);
      labelsDiv.appendChild(countSpan);

      const track = document.createElement('div');
      track.className = 'bar-track';

      const fill = document.createElement('div');
      fill.className = `bar-fill ${stat.colorClass}`;
      fill.style.width = `${pct}%`;

      track.appendChild(fill);
      row.appendChild(labelsDiv);
      row.appendChild(track);
      barContainer.appendChild(row);
    }
  }

  function renderEmptyState(container, message) {
    let emptyDiv = container.querySelector('.chart-empty-state');
    if (!emptyDiv) {
      emptyDiv = document.createElement('div');
      emptyDiv.className = 'chart-empty-state';
      emptyDiv.style.color = '#64748b';
      emptyDiv.style.fontSize = '0.85rem';
      emptyDiv.style.fontStyle = 'italic';
      container.appendChild(emptyDiv);
    }
    emptyDiv.textContent = message;
  }

  return {
    renderEndpointChart,
    renderStatusChart
  };
})();

// Support browser global and module exports
if (typeof window !== 'undefined') {
  window.DeployXCharts = DeployXCharts;
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = DeployXCharts;
}
