# DeployX Frontend - Production Container Image
# Ultra-lightweight Nginx Alpine web server and reverse proxy

FROM nginx:alpine

# Remove default boilerplate configuration
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy production reverse proxy configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy strictly the static UI assets into standard Nginx document root
COPY index.html /usr/share/nginx/html/
COPY css/ /usr/share/nginx/html/css/
COPY js/ /usr/share/nginx/html/js/
COPY assets/ /usr/share/nginx/html/assets/

# Expose standard HTTP web port
EXPOSE 80

# Health check using Alpine's native wget
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:80/ || exit 1

# Launch Nginx in foreground mode
CMD ["nginx", "-g", "daemon off;"]
